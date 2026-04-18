"""Unit tests for scripts/pick_goal.py.

Tests cover:
  * Metrika API response parsing (happy path + malformed)
  * Goal filtering (is_retargeting, engagement types)
  * tfvars rewriter (in-place replace, append when missing, preserves comments)
  * counter_id / goal_id readers

No HTTP calls — we feed raw response bytes to parse_goals_response.
"""

from __future__ import annotations

import importlib.util
import json
import pathlib
import sys
import textwrap

import pytest

# Load scripts/pick_goal.py as a module (it lives outside the test package).
_PICKER_PATH = pathlib.Path(__file__).parent.parent / "scripts" / "pick_goal.py"
_spec = importlib.util.spec_from_file_location("pick_goal", _PICKER_PATH)
assert _spec and _spec.loader
pick_goal = importlib.util.module_from_spec(_spec)
sys.modules["pick_goal"] = pick_goal
_spec.loader.exec_module(pick_goal)


# ── Sample responses ────────────────────────────────────────────────────

SAMPLE_RESPONSE = {
    "goals": [
        {"id": 1001, "name": "Purchase", "type": "url", "is_retargeting": 0,
         "flag": "basket", "conditions": [{"type": "exact", "url": "/thank-you"}]},
        {"id": 1002, "name": "Form submit", "type": "action", "is_retargeting": 0},
        {"id": 1003, "name": "Signup funnel", "type": "step", "is_retargeting": 0,
         "steps": [{"id": 1004, "name": "Step 1", "type": "url"}]},
        {"id": 1005, "name": "Deep visit", "type": "depth", "is_retargeting": 0},
        {"id": 1006, "name": "Long visit", "type": "number", "is_retargeting": 0},
        {"id": 1007, "name": "Retargeting audience", "type": "url", "is_retargeting": 1},
        {"id": 1008, "name": "Phone click", "type": "phone", "is_retargeting": 0},
    ]
}


# ── parse_goals_response ────────────────────────────────────────────────

def test_parse_goals_response_happy_path():
    body = json.dumps(SAMPLE_RESPONSE).encode("utf-8")
    goals = pick_goal.parse_goals_response(body)
    assert len(goals) == 7
    assert goals[0]["id"] == 1001


def test_parse_goals_response_accepts_str():
    goals = pick_goal.parse_goals_response(json.dumps(SAMPLE_RESPONSE))
    assert len(goals) == 7


def test_parse_goals_response_rejects_malformed_json():
    with pytest.raises(pick_goal.MetrikaError, match="malformed JSON"):
        pick_goal.parse_goals_response(b"not json at all {")


def test_parse_goals_response_rejects_missing_goals_key():
    with pytest.raises(pick_goal.MetrikaError, match="no 'goals' array"):
        pick_goal.parse_goals_response(b'{"error": "no goals here"}')


def test_parse_goals_response_rejects_non_list_goals():
    with pytest.raises(pick_goal.MetrikaError, match="no 'goals' array"):
        pick_goal.parse_goals_response(b'{"goals": "not a list"}')


# ── filter_useful_goals ─────────────────────────────────────────────────

def test_filter_removes_retargeting():
    filtered = pick_goal.filter_useful_goals(SAMPLE_RESPONSE["goals"])
    assert all(g.get("is_retargeting", 0) == 0 for g in filtered)
    assert 1007 not in {g["id"] for g in filtered}  # retargeting url goal dropped


def test_filter_removes_engagement_types():
    filtered = pick_goal.filter_useful_goals(SAMPLE_RESPONSE["goals"])
    types = {g["type"] for g in filtered}
    assert "depth" not in types  # 1005
    assert "number" not in types  # 1006


def test_filter_keeps_url_action_step_and_auto_goals():
    filtered = pick_goal.filter_useful_goals(SAMPLE_RESPONSE["goals"])
    ids = {g["id"] for g in filtered}
    assert ids == {1001, 1002, 1003, 1008}  # url, action, step, phone


def test_filter_show_all_skips_filtering():
    filtered = pick_goal.filter_useful_goals(SAMPLE_RESPONSE["goals"], show_all=True)
    assert len(filtered) == len(SAMPLE_RESPONSE["goals"])


def test_filter_empty_input():
    assert pick_goal.filter_useful_goals([]) == []


# ── format_goal_line ────────────────────────────────────────────────────

def test_format_goal_line_includes_id_name_type():
    line = pick_goal.format_goal_line(3, {"id": 42, "name": "Checkout", "type": "url"})
    assert "42" in line
    assert "Checkout" in line
    assert "url" in line
    assert line.lstrip().startswith("3)")


def test_format_goal_line_surfaces_flag():
    line = pick_goal.format_goal_line(1, {"id": 7, "name": "Buy", "type": "url", "flag": "basket"})
    assert "basket" in line


def test_format_goal_line_handles_missing_fields():
    line = pick_goal.format_goal_line(1, {})
    assert "(unnamed)" in line


# ── tfvars rewriter ─────────────────────────────────────────────────────

TFVARS_WITH_GOAL = textwrap.dedent("""\
    folder_id  = "b1g123"
    counter_id = 12345
    goal_id    = 42
    clickhouse_password = "secret"
""")

TFVARS_WITHOUT_GOAL = textwrap.dedent("""\
    folder_id  = "b1g123"
    counter_id = 12345
    clickhouse_password = "secret"
""")

TFVARS_WITH_COMMENT = textwrap.dedent("""\
    counter_id = 12345
    goal_id    = 42  # placeholder, replace me
    clickhouse_password = "secret"
""")

TFVARS_QUOTED_GOAL = textwrap.dedent("""\
    counter_id = 12345
    goal_id    = "42"
""")


def test_update_tfvars_replaces_existing():
    updated = pick_goal.update_tfvars_goal_id(TFVARS_WITH_GOAL, 9999)
    assert "goal_id    = 9999" in updated
    assert "goal_id    = 42" not in updated
    assert 'clickhouse_password = "secret"' in updated


def test_update_tfvars_appends_when_missing():
    updated = pick_goal.update_tfvars_goal_id(TFVARS_WITHOUT_GOAL, 9999)
    assert "goal_id = 9999" in updated
    assert updated.count("goal_id") == 1


def test_update_tfvars_preserves_trailing_comment():
    updated = pick_goal.update_tfvars_goal_id(TFVARS_WITH_COMMENT, 9999)
    assert "goal_id    = 9999  # placeholder, replace me" in updated


def test_update_tfvars_handles_quoted_value():
    updated = pick_goal.update_tfvars_goal_id(TFVARS_QUOTED_GOAL, 9999)
    assert "goal_id    = 9999" in updated
    assert '"42"' not in updated


def test_update_tfvars_preserves_other_lines():
    updated = pick_goal.update_tfvars_goal_id(TFVARS_WITH_GOAL, 9999)
    assert 'folder_id  = "b1g123"' in updated
    assert "counter_id = 12345" in updated


def test_update_tfvars_appends_newline_if_file_has_no_trailing_newline():
    no_trailing = 'counter_id = 12345\nclickhouse_password = "s"'
    updated = pick_goal.update_tfvars_goal_id(no_trailing, 42)
    assert updated.endswith("\n")
    assert "goal_id = 42" in updated


# ── counter_id / goal_id readers ────────────────────────────────────────

def test_read_counter_id(tmp_path):
    p = tmp_path / "terraform.tfvars"
    p.write_text(TFVARS_WITH_GOAL, encoding="utf-8")
    assert pick_goal.read_counter_id(p) == 12345


def test_read_counter_id_missing(tmp_path):
    p = tmp_path / "terraform.tfvars"
    p.write_text('folder_id = "b1g"\n', encoding="utf-8")
    with pytest.raises(ValueError, match="counter_id not found"):
        pick_goal.read_counter_id(p)


def test_read_counter_id_no_file(tmp_path):
    p = tmp_path / "missing.tfvars"
    with pytest.raises(FileNotFoundError):
        pick_goal.read_counter_id(p)


def test_read_goal_id_present(tmp_path):
    p = tmp_path / "terraform.tfvars"
    p.write_text(TFVARS_WITH_GOAL, encoding="utf-8")
    assert pick_goal.read_goal_id(p) == 42


def test_read_goal_id_absent(tmp_path):
    p = tmp_path / "terraform.tfvars"
    p.write_text(TFVARS_WITHOUT_GOAL, encoding="utf-8")
    assert pick_goal.read_goal_id(p) is None


def test_read_goal_id_quoted(tmp_path):
    p = tmp_path / "terraform.tfvars"
    p.write_text(TFVARS_QUOTED_GOAL, encoding="utf-8")
    assert pick_goal.read_goal_id(p) == 42


# ── _find_goal_by_name ──────────────────────────────────────────────────

def test_find_goal_by_name_exact():
    goals = SAMPLE_RESPONSE["goals"]
    g = pick_goal._find_goal_by_name(goals, "Purchase")
    assert g["id"] == 1001


def test_find_goal_by_name_case_insensitive():
    goals = SAMPLE_RESPONSE["goals"]
    g = pick_goal._find_goal_by_name(goals, "purchase")
    assert g["id"] == 1001


def test_find_goal_by_name_not_found():
    with pytest.raises(SystemExit, match="no goal named"):
        pick_goal._find_goal_by_name(SAMPLE_RESPONSE["goals"], "Nonexistent")


def test_find_goal_by_name_ambiguous():
    goals = [
        {"id": 1, "name": "Duplicate"},
        {"id": 2, "name": "Duplicate"},
    ]
    with pytest.raises(SystemExit, match="multiple goals"):
        pick_goal._find_goal_by_name(goals, "Duplicate")
