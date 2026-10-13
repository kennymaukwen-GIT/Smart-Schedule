#!/usr/bin/env python3
"""Validates Shared/AI/FunctionDeclarations.json and the example calls in Tests/fixtures.

1. Lints the declarations against the OpenAPI subset Gemini accepts in `parameters`.
2. Validates each fixture's expected args against its declaration (JSON Schema).
3. Re-implements the Swift mapper's date/RRULE rules as a reference and prints the Google Calendar
   payload a fixture produces, including DST-correct UNTIL values.
4. Re-implements the draft-plan preview (Shared/Calendar/RecurrenceExpander.swift + PlanDraftBuilder.swift):
   weekly occurrences at a fixed wall-clock time, capped at the plan or 26 weeks, whichever is shorter.

Usage: python3 -I scripts/validate_schema.py [--print-payloads]
"""
from __future__ import annotations

import hashlib
import json
import re
import sys
from datetime import date, datetime, time, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

import jsonschema

ROOT = Path(__file__).resolve().parent.parent
DECLARATIONS = ROOT / "Shared/AI/FunctionDeclarations.json"
FIXTURES = ROOT / "Tests/fixtures"

ALLOWED_KEYS = {
    "type", "description", "enum", "properties", "required", "items", "format", "nullable",
    "minItems", "maxItems", "minimum", "maximum", "propertyOrdering", "title",
}
TYPES = {"object", "array", "string", "integer", "number", "boolean"}
NAME_RE = re.compile(r"^[a-zA-Z_][a-zA-Z0-9_]{0,63}$")
WEEKDAYS = ["MO", "TU", "WE", "TH", "FR", "SA", "SU"]

errors: list[str] = []


def lint(node: dict, path: str, depth: int = 0) -> int:
    unknown = set(node) - ALLOWED_KEYS
    if unknown:
        errors.append(f"{path}: keys not in Gemini schema subset: {sorted(unknown)}")
    kind = node.get("type")
    if kind not in TYPES:
        errors.append(f"{path}: invalid type {kind!r}")
    if "enum" in node and kind != "string":
        errors.append(f"{path}: enum only allowed on string")
    deepest = depth
    if kind == "object":
        props = node.get("properties", {})
        for req in node.get("required", []):
            if req not in props:
                errors.append(f"{path}: required '{req}' not in properties")
        for name, child in props.items():
            deepest = max(deepest, lint(child, f"{path}.{name}", depth + 1))
    if kind == "array":
        if "items" not in node:
            errors.append(f"{path}: array without items")
        else:
            deepest = max(deepest, lint(node["items"], f"{path}[]", depth + 1))
    return deepest


# ---------- reference mapper (mirrors Shared/Calendar/*.swift) ----------

def parse_day(value: str) -> date:
    return date.fromisoformat(value[:10])


def first_matching_day(start: date, weekdays: list[str]) -> date:
    wanted = {WEEKDAYS.index(d) for d in weekdays}
    for offset in range(7):
        candidate = start + timedelta(days=offset)
        if candidate.weekday() in wanted:
            return candidate
    raise ValueError("no weekday")


def until_utc(day: date, tz: ZoneInfo) -> str:
    end_local = datetime.combine(day, time(23, 59, 59), tzinfo=tz)
    return end_local.astimezone(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def event_id(seed: str) -> str:
    alphabet = "0123456789abcdefghijklmnopqrstuv"
    digest = hashlib.sha256(seed.encode()).digest()[:16]
    bits = "".join(f"{b:08b}" for b in digest)
    bits += "0" * (-len(bits) % 5)
    return "ss" + "".join(alphabet[int(bits[i:i + 5], 2)] for i in range(0, len(bits), 5))


def plan_payloads(args: dict, tz_name: str, plan_id: str = "demoplan") -> list[dict]:
    tz = ZoneInfo(tz_name)
    out = []
    for index, session in enumerate(args["sessions"]):
        phase = args["phases"][session["phase_index"]]
        phase_start, phase_end = parse_day(phase["start_date"]), parse_day(phase["end_date"])
        first = first_matching_day(phase_start, session["weekdays"])
        hh, mm = map(int, session["start_time"].split(":"))
        start = datetime.combine(first, time(hh, mm))
        end = start + timedelta(minutes=session["duration_minutes"])
        days = ",".join(sorted(session["weekdays"], key=WEEKDAYS.index))
        out.append({
            "id": event_id(f"{plan_id}|session|{index}"),
            "summary": f"{args['plan_title']} · {session['title']}",
            "start": {"dateTime": start.strftime("%Y-%m-%dT%H:%M:%S"), "timeZone": tz_name},
            "end": {"dateTime": end.strftime("%Y-%m-%dT%H:%M:%S"), "timeZone": tz_name},
            "recurrence": [f"RRULE:FREQ=WEEKLY;BYDAY={days};UNTIL={until_utc(phase_end, tz)}"],
            "colorId": "10",
            "reminders": {"useDefault": False, "overrides": [{"method": "popup", "minutes": 30}]},
            "extendedProperties": {"private": {"ssSource": "smart-schedule", "ssKind": "routine",
                                               "ssPlanId": plan_id, "ssSchema": "1"}},
        })
    return out


PREVIEW_WEEKS = 26


def weekly_occurrences(first: datetime, weekdays: list[str], last_day: date, horizon: date) -> list[datetime]:
    """Wall-clock starts on BYDAY days from `first` through `last_day` (UNTIL, inclusive), before `horizon`."""
    wanted = {WEEKDAYS.index(d) for d in weekdays}
    out, day = [], first.date()
    while day <= last_day and day < horizon:
        if day.weekday() in wanted:
            out.append(datetime.combine(day, first.time()))
        day += timedelta(days=1)
    return out


def preview_occurrences(args: dict) -> list[datetime]:
    """Local wall-clock starts of every session occurrence the draft preview shows."""
    start, end = parse_day(args["start_date"]), parse_day(args["end_date"])
    horizon = min(end + timedelta(days=1), start + timedelta(weeks=PREVIEW_WEEKS))
    out = []
    for session in args["sessions"]:
        phase = args["phases"][session["phase_index"]]
        phase_start, phase_end = parse_day(phase["start_date"]), parse_day(phase["end_date"])
        first_day = first_matching_day(phase_start, session["weekdays"])
        hh, mm = map(int, session["start_time"].split(":"))
        out += weekly_occurrences(datetime.combine(first_day, time(hh, mm)), session["weekdays"], phase_end, horizon)
    return sorted(out)


def semantic_checks(name: str, args: dict, fixture: str) -> None:
    if name == "create_events":
        for ev in args["events"]:
            datetime.fromisoformat(ev["start"]) if "T" in ev["start"] else parse_day(ev["start"])
    if name == "create_long_term_plan":
        phases = args["phases"]
        previous_end = None
        for i, phase in enumerate(phases):
            s, e = parse_day(phase["start_date"]), parse_day(phase["end_date"])
            if e < s:
                errors.append(f"{fixture}: phase {i} ends before it starts")
            if previous_end and s <= previous_end:
                errors.append(f"{fixture}: phase {i} overlaps previous phase")
            previous_end = e
        for s in args["sessions"]:
            if not 0 <= s["phase_index"] < len(phases):
                errors.append(f"{fixture}: phase_index {s['phase_index']} out of range")
            if not re.fullmatch(r"([01]\d|2[0-3]):[0-5]\d", s["start_time"]):
                errors.append(f"{fixture}: bad start_time {s['start_time']}")


def context_checks(root: dict, fixture: str) -> None:
    """Draft-review fixtures: confirm_plan needs a draft on screen; a revision is a complete plan that keeps its title."""
    call = root["expected_call"]
    if call["name"] == "confirm_plan" and not root.get("draft_plan"):
        errors.append(f"{fixture}: confirm_plan is only valid while a DRAFT PLAN is shown (add 'draft_plan')")
    if "revises" in root:
        original = json.loads((FIXTURES / root["revises"]).read_text())["expected_call"]
        if original["name"] != call["name"] or call["name"] != "create_long_term_plan":
            errors.append(f"{fixture}: a revision must be create_long_term_plan, like {root['revises']}")
        elif original["args"]["plan_title"] != call["args"]["plan_title"]:
            errors.append(f"{fixture}: a revision keeps plan_title unless the user renames it")


def main() -> int:
    declarations = json.loads(DECLARATIONS.read_text())
    by_name = {}
    for decl in declarations:
        name = decl.get("name", "")
        if not NAME_RE.match(name):
            errors.append(f"bad function name {name!r}")
        if len(decl.get("description", "")) < 20:
            errors.append(f"{name}: description too short to route reliably")
        depth = lint(decl["parameters"], name)
        jsonschema.Draft202012Validator.check_schema(decl["parameters"])
        by_name[name] = decl
        print(f"✓ {name:<24} nesting depth {depth}")

    for path in sorted(FIXTURES.glob("*.json")):
        fixture = json.loads(path.read_text())
        call = fixture["expected_call"]
        schema = by_name.get(call["name"])
        if not schema:
            errors.append(f"{path.name}: unknown function {call['name']}")
            continue
        for err in jsonschema.Draft202012Validator(schema["parameters"]).iter_errors(call["args"]):
            errors.append(f"{path.name}: {'/'.join(map(str, err.path))}: {err.message}")
        semantic_checks(call["name"], call["args"], path.name)
        context_checks(fixture, path.name)
        print(f"✓ fixture {path.name}")

        if "--print-payloads" in sys.argv and call["name"] == "create_long_term_plan":
            for payload in plan_payloads(call["args"], fixture["time_zone"]):
                print(json.dumps(payload, ensure_ascii=False))
            preview = preview_occurrences(call["args"])
            print(f"  draft preview: {len(preview)} sessions, {preview[0]:%Y-%m-%d %H:%M} → {preview[-1]:%Y-%m-%d %H:%M}")

    # DST regression: Europe/London UNTIL must shift by an hour between GMT and BST days.
    london = ZoneInfo("Europe/London")
    assert until_utc(date(2026, 11, 30), london) == "20261130T235959Z", "GMT day"
    assert until_utc(date(2027, 4, 13), london) == "20270413T225959Z", "BST day"
    assert first_matching_day(date(2026, 10, 13), ["MO", "WE", "FR"]) == date(2026, 10, 14)
    # Preview occurrences keep 18:30 wall time, so their UTC instant moves by an hour across both changes.
    weekly = weekly_occurrences(datetime(2026, 10, 15, 18, 30), ["MO", "TH"], date(2027, 4, 13), date(2027, 4, 14))
    utc = [w.replace(tzinfo=london).astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%MZ") for w in weekly]
    assert "2026-10-22T17:30Z" in utc and "2026-10-26T18:30Z" in utc, "autumn change"
    assert "2027-03-25T18:30Z" in utc and "2027-03-29T17:30Z" in utc, "spring change"
    assert weekly[0] == datetime(2026, 10, 15, 18, 30) and weekly[-1] == datetime(2027, 4, 12, 18, 30)
    print("✓ DST / RRULE / preview reference checks")

    if errors:
        print("\n".join(f"✗ {e}" for e in errors), file=sys.stderr)
        return 1
    print("All checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
