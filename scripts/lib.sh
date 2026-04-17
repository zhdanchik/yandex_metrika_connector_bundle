#!/usr/bin/env bash
# Common helpers for deploy/cleanup/smoke scripts.
# Source from other scripts: . "$(dirname "$0")/lib.sh"

set -euo pipefail

# Repo root = parent of scripts/
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$REPO_ROOT/terraform"
TFVARS="$TF_DIR/terraform.tfvars"

# ── Colour-coded logging (no-op if not a TTY) ────────────────────────────
if [ -t 2 ]; then
  C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'; C_GREEN=$'\033[32m'
  C_BLUE=$'\033[34m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
else
  C_RED=""; C_YELLOW=""; C_GREEN=""; C_BLUE=""; C_DIM=""; C_RESET=""
fi

log()   { printf '%s[*]%s %s\n' "$C_BLUE"   "$C_RESET" "$*" >&2; }
ok()    { printf '%s[+]%s %s\n' "$C_GREEN"  "$C_RESET" "$*" >&2; }
warn()  { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()   { printf '%s[x]%s %s\n' "$C_RED"    "$C_RESET" "$*" >&2; exit 1; }
hdr()   { printf '\n%s══ %s ══%s\n' "$C_BLUE" "$*" "$C_RESET" >&2; }

require_bin() {
  for b in "$@"; do
    command -v "$b" >/dev/null 2>&1 || die "missing required binary: $b"
  done
}

# Parse a simple HCL key from terraform.tfvars: handles "key = value" lines
# with optional quotes.  Numbers come back unquoted; strings without quotes.
tfvar_get() {
  local key="$1"
  [ -f "$TFVARS" ] || die "$TFVARS not found — copy terraform.tfvars.example first"
  python3 - "$TFVARS" "$key" <<'PY'
import re, sys
path, key = sys.argv[1], sys.argv[2]
# Match a quoted string OR an unquoted value (number etc) up to comment/EOL.
pat = re.compile(
    r'^\s*' + re.escape(key) + r'\s*=\s*'
    r'(?:"((?:[^"\\]|\\.)*)"|\'((?:[^\'\\]|\\.)*)\'|([^\s#]+))'
)
with open(path, encoding='utf-8') as f:
    for line in f:
        m = pat.match(line)
        if m:
            v = m.group(1) if m.group(1) is not None \
                else m.group(2) if m.group(2) is not None \
                else m.group(3)
            print(v)
            sys.exit(0)
sys.exit(1)
PY
}

confirm() {
  local prompt="${1:-Continue?}"
  if [ "${ASSUME_YES:-0}" = "1" ]; then
    return 0
  fi
  local reply
  printf '%s [y/N]: ' "$prompt" >&2
  read -r reply
  [[ "$reply" =~ ^[Yy]$ ]] || return 1
}

# Run yc with --folder-id FOLDER injected; expects FOLDER_ID set.
yc_folder() {
  yc --folder-id "$FOLDER_ID" "$@"
}

# Pretty-print a list of resources (name + id).
print_list() {
  local title="$1"; shift
  local items="$1"
  if [ -z "$items" ]; then
    printf '  %s%s: (none)%s\n' "$C_DIM" "$title" "$C_RESET" >&2
  else
    printf '  %s:\n' "$title" >&2
    printf '%s\n' "$items" | sed 's/^/    /' >&2
  fi
}
