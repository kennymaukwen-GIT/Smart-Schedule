#!/usr/bin/env python3
"""Validates Shared/AI/FunctionDeclarations.json and the example calls in Tests/fixtures.

1. Lints the declarations against the OpenAPI subset Gemini accepts in `parameters`.
2. Validates each fixture's expected args against its declaration (JSON Schema).
3. Re-implements the Swift mapper's date/RRULE rules as a reference and prints the Google Calendar
   payload a fixture produces, including DST-correct UNTIL values.
4. Re-implements the draft-plan preview (Shared/Calendar/RecurrenceExpander.swift + PlanDraftBuilder.swift):
   weekly occurrences at a fixed wall-clock time, capped at the plan or 26 weeks, whichever is shorter.
5. Checks that fixture texts follow the prompt's "# Writing style" (short summaries, no "Tue/Thu", no times).
6. Checks Shared/Localization/Localizable.xcstrings: every key has a zh-Hant translation whose format
   specifiers match the key's (positional %1$@ allowed), and every String(localized:) literal in the
   Swift sources is a key.

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
CATALOG = ROOT / "Shared/Localization/Localizable.xcstrings"
STRINGS_FILES = sorted((ROOT / "Shared/Localization").glob("*.lproj/*.strings"))
SWIFT_DIRS = ["App", "Shared", "NotificationContent", "Widgets"]

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


SENTENCE_END = re.compile(r"[.!?。！？]+")
CLOCK_TIME = re.compile(r"\b\d{1,2}:\d{2}\b")


def style_checks(name: str, args: dict, fixture: str) -> None:
    """The prompt's "# Writing style": the card's table shows days and times, so the summary must not."""
    texts = []
    if name == "create_long_term_plan":
        summary = args["summary_for_user"]
        texts.append(("summary_for_user", summary))
        sentences = [part for part in SENTENCE_END.split(summary) if part.strip()]
        if len(sentences) > 2:
            errors.append(f"{fixture}: summary_for_user has {len(sentences)} sentences (max 2)")
        if CLOCK_TIME.search(summary):
            errors.append(f"{fixture}: summary_for_user lists a time; the plan table shows times")
    if name == "reply_to_user":
        message = args["message"]
        texts.append(("message", message))
        if len([part for part in SENTENCE_END.split(message) if part.strip()]) > 2:
            errors.append(f"{fixture}: reply_to_user.message has more than 2 sentences")
    for field, text in texts:
        if "/" in text:
            errors.append(f"{fixture}: {field} uses a slash (write 'Tuesday and Thursday', not 'Tue/Thu')")


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


# ---------- String Catalog ----------

SPECIFIER = re.compile(r"%(?:(\d+)\$)?(@|lld|llu|ld|lu|d|u|lf|f|%)")


def specifiers(text: str) -> dict[int, str]:
    """Argument position → conversion, e.g. "%@ (%lld times)" → {1: "@", 2: "lld"}."""
    found, sequential = {}, 0
    for match in SPECIFIER.finditer(text):
        position, conversion = match.groups()
        if conversion == "%":
            continue
        sequential += 1
        found[int(position) if position else sequential] = conversion
    return found


def catalog_units(entry: dict, language: str) -> list[tuple[str, str]]:
    """(state, value) of every string unit for `language`, including plural/device variations."""
    units, stack = [], [entry.get("localizations", {}).get(language, {})]
    while stack:
        node = stack.pop()
        if "stringUnit" in node:
            unit = node["stringUnit"]
            units.append((unit.get("state", ""), unit.get("value", "")))
        for variants in node.get("variations", {}).values():
            stack.extend(variants.values())
    return units


FORMAT_ARGUMENT = r"%(?:@|lld|llu|ld|lu|d|u|lf|f)"


def localized_literals(source: str):
    """The parts of each String(localized: "…") literal: text runs, with None where an interpolation sits."""
    for match in re.finditer(r'String\(localized:\s*"(?!"")', source):
        parts, text, i = [], "", match.end()
        while i < len(source) and source[i] != '"':
            if source[i] != "\\":
                text += source[i]
                i += 1
            elif source[i + 1] == "(":
                depth, i = 1, i + 2
                while depth:
                    if source[i] == '"':
                        i = source.index('"', i + 1)  # a string literal inside the interpolation
                    depth += {"(": 1, ")": -1}.get(source[i], 0)
                    i += 1
                parts += [text, None]
                text = ""
            else:
                text += {"n": "\n", "t": "\t"}.get(source[i + 1], source[i + 1])
                i += 2
        yield parts + [text]


def catalog_checks() -> int:
    catalog = json.loads(CATALOG.read_text())
    if catalog.get("sourceLanguage") != "en" or catalog.get("version") != "1.0":
        errors.append("Localizable.xcstrings: sourceLanguage must be 'en' and version '1.0'")
    strings = catalog.get("strings", {})
    for key, entry in strings.items():
        expected = specifiers(key)
        translations = catalog_units(entry, "zh-Hant")
        if not translations:
            errors.append(f"Localizable.xcstrings: {key!r} has no zh-Hant translation")
        for language, units in (("zh-Hant", translations), ("en", catalog_units(entry, "en"))):
            for state, value in units:
                if state != "translated" or not value.strip():
                    errors.append(f"Localizable.xcstrings: {key!r} {language} is {state or 'empty'}")
                elif specifiers(value) != expected:
                    errors.append(f"Localizable.xcstrings: {key!r} {language} {value!r} has specifiers "
                                  f"{specifiers(value)}, the key has {expected}")
    # Interpolations become format arguments; their types are not visible here, so any specifier matches.
    for directory in SWIFT_DIRS:
        for path in sorted((ROOT / directory).rglob("*.swift")):
            for parts in localized_literals(path.read_text()):
                pattern = "".join(FORMAT_ARGUMENT if part is None else re.escape(part) for part in parts)
                if not any(re.fullmatch(pattern, key) for key in strings):
                    literal = "".join("\\(…)" if part is None else part for part in parts)
                    errors.append(f"{path.relative_to(ROOT)}: String(localized: {literal!r}) is not in Localizable.xcstrings")
    return len(strings)


STRINGS_ENTRY = re.compile(r'^"((?:[^"\\]|\\.)+)"\s*=\s*"((?:[^"\\]|\\.)*)";$')


def strings_file_checks() -> None:
    """Old-style .strings files (zh-Hant InfoPlist.strings): a malformed line fails the build's CopyStringsFile."""
    for path in STRINGS_FILES:
        body = re.sub(r"/\*.*?\*/", "", path.read_text(encoding="utf-8"), flags=re.S)
        for line in body.splitlines():
            if line.strip() and not STRINGS_ENTRY.match(line.strip()):
                errors.append(f"{path.relative_to(ROOT)}: not a '\"key\" = \"value\";' line: {line.strip()!r}")


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
        style_checks(call["name"], call["args"], path.name)
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

    print(f"✓ String Catalog: {catalog_checks()} keys with zh-Hant")
    strings_file_checks()

    if errors:
        print("\n".join(f"✗ {e}" for e in errors), file=sys.stderr)
        return 1
    print("All checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
