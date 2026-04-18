#!/usr/bin/env python3
"""
Interactive goal picker for Yandex Metrika.

Calls the Metrika Management API:
    GET https://api-metrika.yandex.net/management/v1/counter/{id}/goals

Shows a numbered menu of goals for the counter and writes the chosen
goal_id into terraform/terraform.tfvars.

Inputs:
    counter_id   — read from terraform.tfvars
    OAuth token  — METRIKA_OAUTH_TOKEN env var, or prompted interactively
                   (same token you used to create the Metrika source
                   endpoint in YC Console; needs metrika:write scope —
                   Data Transfer requires write to activate a source).

The token is NOT persisted anywhere.  It is used for one HTTPS call
and then discarded.

Usage:
    python3 scripts/pick_goal.py
    METRIKA_OAUTH_TOKEN=xxx python3 scripts/pick_goal.py --non-interactive --goal-name "Purchase"

Stdlib only.  No pip dependencies.
"""

from __future__ import annotations

import argparse
import getpass
import json
import os
import pathlib
import re
import ssl
import sys
import urllib.error
import urllib.request
from typing import Any

API_URL = "https://api-metrika.yandex.net/management/v1/counter/{counter_id}/goals"

# Goal types we surface by default.  number/depth are engagement
# metrics (visit duration / pages per session), not conversions —
# they're hidden unless --show-all is passed.
ATTRIBUTION_GOAL_TYPES = frozenset({
    "url", "action", "step",
    "phone", "email", "messenger", "social",
    "file", "search", "payment_system", "chat",
})


# ─── Metrika API client ──────────────────────────────────────────────────

class MetrikaError(Exception):
    """Raised on any non-2xx response from the Metrika API."""


def fetch_goals(counter_id: int, oauth_token: str, *, timeout: float = 15.0) -> list[dict[str, Any]]:
    """Call the Metrika Management API and return the raw goals list.

    Raises MetrikaError with a human-readable message on failure.
    """
    url = API_URL.format(counter_id=counter_id)
    req = urllib.request.Request(
        url,
        headers={
            "Authorization": f"OAuth {oauth_token}",
            "Accept": "application/json",
            "User-Agent": "metrika-attribution-goal-picker/1.0",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ssl.create_default_context()) as resp:
            body = resp.read()
    except urllib.error.HTTPError as e:
        raise MetrikaError(_format_http_error(e, counter_id)) from e
    except urllib.error.URLError as e:
        raise MetrikaError(f"network error calling Metrika API: {e.reason}") from e

    return parse_goals_response(body)


def parse_goals_response(body: bytes | str) -> list[dict[str, Any]]:
    """Extract the goals array from a successful Metrika API response."""
    if isinstance(body, bytes):
        body = body.decode("utf-8")
    try:
        payload = json.loads(body)
    except json.JSONDecodeError as e:
        raise MetrikaError(f"malformed JSON from Metrika API: {e}") from e

    goals = payload.get("goals")
    if not isinstance(goals, list):
        raise MetrikaError(f"unexpected response shape: no 'goals' array (keys: {list(payload)})")
    return goals


def _format_http_error(e: urllib.error.HTTPError, counter_id: int) -> str:
    """Build a user-friendly error string for an HTTPError from Metrika."""
    try:
        body_text = e.read().decode("utf-8", errors="replace")
        detail = json.loads(body_text)
        msg = detail.get("message") or detail.get("errors", [{}])[0].get("message") or body_text
    except Exception:
        msg = str(e)

    if e.code == 401:
        return (
            f"Metrika API rejected the OAuth token (401). "
            f"Check the token has metrika:write scope (Data Transfer needs write to activate a source). "
            f"Details: {msg}"
        )
    if e.code == 403:
        return (
            f"Token has no access to counter {counter_id} (403). "
            f"Verify counter_id and that the token owner has viewer+ rights. Details: {msg}"
        )
    if e.code == 404:
        return f"Counter {counter_id} not found (404). Check counter_id. Details: {msg}"
    if e.code == 429:
        return f"Metrika API rate limit hit (429). Retry in a few seconds. Details: {msg}"
    return f"Metrika API error {e.code}: {msg}"


# ─── Goal filtering & formatting ─────────────────────────────────────────

def filter_useful_goals(goals: list[dict[str, Any]], *, show_all: bool = False) -> list[dict[str, Any]]:
    """Drop goals that make no sense for attribution analysis.

    Removed by default:
      - is_retargeting == 1  (audience-targeting goals, not conversions)
      - type in {number, depth}  (engagement metrics — visit duration,
        pages per session)

    Pass show_all=True to skip filtering.
    """
    if show_all:
        return list(goals)
    out = []
    for g in goals:
        if int(g.get("is_retargeting", 0)) == 1:
            continue
        if g.get("type") not in ATTRIBUTION_GOAL_TYPES:
            continue
        out.append(g)
    return out


def format_goal_line(idx: int, goal: dict[str, Any]) -> str:
    """Render one goal as a single menu line: '  3) 12345  Purchase (url)'."""
    gid = goal.get("id", "?")
    name = goal.get("name") or "(unnamed)"
    gtype = goal.get("type") or "?"
    flag = goal.get("flag")
    suffix = f" ({gtype}" + (f", {flag}" if flag else "") + ")"
    return f"  {idx:>3}) {gid:<10}  {name}{suffix}"


# ─── tfvars read/write ───────────────────────────────────────────────────

_TFVAR_LINE_RE = re.compile(
    r'^(\s*goal_id\s*=\s*)(?:"([^"]*)"|(\d+))(\s*(?:#.*)?)$'
)
_COUNTER_ID_RE = re.compile(
    r'^\s*counter_id\s*=\s*(\d+)'
)


def read_counter_id(tfvars_path: pathlib.Path) -> int:
    """Read counter_id (integer) from terraform.tfvars."""
    if not tfvars_path.exists():
        raise FileNotFoundError(f"{tfvars_path} not found — copy terraform.tfvars.example first")
    for line in tfvars_path.read_text(encoding="utf-8").splitlines():
        m = _COUNTER_ID_RE.match(line)
        if m:
            return int(m.group(1))
    raise ValueError(f"counter_id not found in {tfvars_path}")


def read_goal_id(tfvars_path: pathlib.Path) -> int | None:
    """Return the current goal_id value from tfvars, or None if unset."""
    if not tfvars_path.exists():
        return None
    for line in tfvars_path.read_text(encoding="utf-8").splitlines():
        m = _TFVAR_LINE_RE.match(line)
        if m:
            raw = m.group(2) if m.group(2) is not None else m.group(3)
            try:
                return int(raw)
            except (TypeError, ValueError):
                return None
    return None


def update_tfvars_goal_id(tfvars_content: str, new_goal_id: int) -> str:
    """Rewrite tfvars text with a new goal_id.

    If an existing 'goal_id = ...' line is present, its value is
    replaced in place (preserving trailing comment).  Otherwise the
    line is appended at the end.
    """
    lines = tfvars_content.splitlines(keepends=True)
    replaced = False
    for i, line in enumerate(lines):
        m = _TFVAR_LINE_RE.match(line.rstrip("\n"))
        if m:
            newline = "\n" if line.endswith("\n") else ""
            lines[i] = f"{m.group(1)}{new_goal_id}{m.group(4)}{newline}"
            replaced = True
            break

    if not replaced:
        if lines and not lines[-1].endswith("\n"):
            lines[-1] += "\n"
        lines.append(f"goal_id = {new_goal_id}\n")

    return "".join(lines)


# ─── CLI ─────────────────────────────────────────────────────────────────

def _prompt_token() -> str:
    token = os.environ.get("METRIKA_OAUTH_TOKEN", "").strip()
    if token:
        return token
    if not sys.stdin.isatty():
        sys.exit("METRIKA_OAUTH_TOKEN not set and stdin is not a TTY — cannot prompt")
    print(
        "OAuth token for Yandex Metrika (scope: metrika:write — same one used for "
        "the Data Transfer source endpoint).\n"
        "Get one at https://oauth.yandex.com/ . Token is used once and not saved.",
        file=sys.stderr,
    )
    return getpass.getpass("Token: ").strip()


def _prompt_choice(n: int) -> int:
    if not sys.stdin.isatty():
        sys.exit("stdin is not a TTY — cannot prompt for a choice. Use --non-interactive --goal-name.")
    while True:
        raw = input(f"Pick goal (1–{n}), or q to quit: ").strip().lower()
        if raw in ("q", "quit", "exit", ""):
            sys.exit("cancelled")
        try:
            i = int(raw)
        except ValueError:
            print("  not a number, try again", file=sys.stderr)
            continue
        if 1 <= i <= n:
            return i
        print(f"  out of range, pick 1–{n}", file=sys.stderr)


def _find_goal_by_name(goals: list[dict[str, Any]], name: str) -> dict[str, Any]:
    matches = [g for g in goals if (g.get("name") or "").strip().lower() == name.strip().lower()]
    if len(matches) == 1:
        return matches[0]
    if not matches:
        sys.exit(f"no goal named {name!r} (case-insensitive exact match) on this counter")
    ids = ", ".join(str(g.get("id")) for g in matches)
    sys.exit(f"multiple goals named {name!r}: ids {ids} — disambiguate or run interactively")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tfvars", default=None, help="path to terraform.tfvars (default: <repo>/terraform/terraform.tfvars)")
    parser.add_argument("--counter-id", type=int, default=None, help="override counter_id from tfvars")
    parser.add_argument("--show-all", action="store_true", help="do not hide retargeting/engagement goals")
    parser.add_argument("--non-interactive", action="store_true", help="require --goal-name; no prompts")
    parser.add_argument("--goal-name", default=None, help="pick this goal by exact (case-insensitive) name")
    parser.add_argument("--print-only", action="store_true", help="print chosen id to stdout, do not touch tfvars")
    args = parser.parse_args(argv)

    repo_root = pathlib.Path(__file__).resolve().parent.parent
    tfvars_path = pathlib.Path(args.tfvars) if args.tfvars else repo_root / "terraform" / "terraform.tfvars"

    counter_id = args.counter_id if args.counter_id is not None else read_counter_id(tfvars_path)
    token = _prompt_token()

    try:
        goals_raw = fetch_goals(counter_id, token)
    except MetrikaError as e:
        sys.exit(str(e))

    goals = filter_useful_goals(goals_raw, show_all=args.show_all)
    hidden = len(goals_raw) - len(goals)
    if not goals:
        sys.exit(
            f"no usable goals on counter {counter_id} "
            f"({len(goals_raw)} total, {hidden} filtered — use --show-all to see them)"
        )

    if args.goal_name:
        chosen = _find_goal_by_name(goals, args.goal_name)
    elif args.non_interactive:
        sys.exit("--non-interactive requires --goal-name")
    else:
        print(f"\nCounter {counter_id}: {len(goals)} goal(s)" + (f" ({hidden} hidden)" if hidden else ""), file=sys.stderr)
        for idx, g in enumerate(goals, start=1):
            print(format_goal_line(idx, g), file=sys.stderr)
        print(file=sys.stderr)
        chosen = goals[_prompt_choice(len(goals)) - 1]

    goal_id = int(chosen["id"])
    print(f"\nChosen: {goal_id}  {chosen.get('name')}  ({chosen.get('type')})", file=sys.stderr)

    if args.print_only:
        print(goal_id)
        return 0

    existing = read_goal_id(tfvars_path)
    if existing is not None and existing != goal_id and existing != 42:
        print(
            f"terraform.tfvars currently has goal_id = {existing}. "
            f"Overwrite with {goal_id}? [y/N]: ",
            end="", file=sys.stderr, flush=True,
        )
        if not sys.stdin.isatty():
            sys.exit("not a TTY — refusing to overwrite goal_id non-interactively")
        reply = input().strip().lower()
        if reply not in ("y", "yes"):
            sys.exit("cancelled")

    content = tfvars_path.read_text(encoding="utf-8")
    tfvars_path.write_text(update_tfvars_goal_id(content, goal_id), encoding="utf-8")
    print(f"wrote goal_id = {goal_id} to {tfvars_path}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
