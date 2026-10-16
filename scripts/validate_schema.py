#!/usr/bin/env python3
"""Validates Shared/AI/FunctionDeclarations.json and the example calls in Tests/fixtures.

1. Lints the declarations against the OpenAPI subset Gemini accepts in `parameters`.
2. Validates each fixture's expected args against its declaration (JSON Schema).
3. Re-implements the Swift mapper's date/RRULE rules as a reference and prints the Google Calendar
   payload a fixture produces, including DST-correct UNTIL values.
4. Re-implements the draft-plan preview (Shared/Calendar/RecurrenceExpander.swift + PlanDraftBuilder.swift):
   weekly occurrences at a fixed wall-clock time, capped at the plan or 26 weeks, whichever is shorter.
5. Checks that fixture texts follow the prompt's "# Writing style" (short summaries, no "Tue/Thu", no times),
   and update_preferences values against the per-key encoding the app's normaliser accepts
   (docs/SETTINGS.md §6.2); a default_calendar value must be a line of the fixture's CALENDARS.
   No Google account email reaches Gemini (docs/GEMINI_FUNCTION_CALLING.md §10.6): a fixture's CALENDARS and
   PREFERENCES hold no "@" (accounts are "Account N"), and the prompt builders never read an account's address.
   Note suggestions (suggest_event_notes items, create_events suggested_notes) are short checklist items in the
   language of the event title, without bullets, repeats, prices or doses, and say nothing the event's notes or the
   request's ALREADY SUGGESTED line already say (docs/GEMINI_FUNCTION_CALLING.md §12).
6. Checks Shared/Localization/Localizable.xcstrings: every key has a zh-Hant translation whose format
   specifiers match the key's (positional %1$@ allowed), and every String(localized:) literal in the
   Swift sources is a key.
7. Version 1.0 sells nothing (docs/SETTINGS.md §16): AppConstants.subscriptionsEnabled is false, and every Swift file
   that reaches StoreKit or SubscriptionStore, or shows subscription copy, reads the flag in code.
8. Version 1.0 has no iOS 18 Live Activity push-to-start and no remote push: AppConstants.pushToStartEnabled is false,
   every Swift file that asks iOS for a push-to-start token or installs, syncs, uploads or erases the registration
   reads the flag in code, and project.yml has neither the aps-environment entitlement nor the remote-notification
   background mode while both push flags (pushToStartEnabled, liveActivityPushEnabled) are false (and aps-environment
   once one is on).
9. Version 1.0 has no microphone or speech recognition of its own: no Swift file records audio or calls Apple's speech
   recognizer, and neither project.yml nor a .strings file declares NSMicrophoneUsageDescription or
   NSSpeechRecognitionUsageDescription. People type, use the keyboard's own dictation, or talk to Siri.

Usage: python3 -I scripts/validate_schema.py [--print-payloads]
"""
from __future__ import annotations

import hashlib
import json
import re
import sys
import unicodedata
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


HHMM = r"([01]\d|2[0-3]):[0-5]\d"
PREFERENCE_VALUES = {
    # key → (regex the value must fully match, case-insensitive)
    "all_day_reminder": rf"none|{HHMM}",
    "quiet_hours": rf"off|on|{HHMM}-{HHMM}",
    "morning_briefing": rf"off|on|{HHMM}",
    "evening_preview": rf"off|on|{HHMM}",
    "daily_reminder_cap": r"off|[1-9]|[1-4]\d|50",
    "week_start": r"sunday|monday",
    "reply_language": r"match|zh-hant|zh_tw|zh-tw|en",
    "autonomy": r"add_directly|ask_first",
}
for kind in ("event", "deadline", "task", "routine"):
    PREFERENCE_VALUES[f"{kind}_reminders"] = r"none|\d{1,5}(\s*,\s*\d{1,5})*"
    PREFERENCE_VALUES[f"{kind}_urgency"] = r"automatic|time_sensitive|normal|quiet"


def calendar_lines(root: dict) -> list[str]:
    """The fixture's CALENDARS block as default_calendar values: "- <label> (default)" → "<label>"."""
    raw = root.get("calendars", "")
    lines = raw if isinstance(raw, list) else raw.splitlines()
    return [re.sub(r"\s*\(default\)$", "", line.strip().removeprefix("- ").strip()) for line in lines if line.strip()]


def preference_checks(args: dict, root: dict, fixture: str) -> None:
    """update_preferences: one change per key, each value in the encoding the app's normaliser accepts."""
    keys = [change["key"] for change in args["changes"]]
    if len(keys) != len(set(keys)):
        errors.append(f"{fixture}: update_preferences changes a key twice")
    for change in args["changes"]:
        key, value = change["key"], change["value"].strip()
        if key == "default_calendar":
            if value.lower() != "automatic" and value not in calendar_lines(root):
                errors.append(f"{fixture}: default_calendar {value!r} is not a line of the fixture's calendars")
        elif key == "default_duration":
            if not value.isdigit() or not 5 <= int(value) <= 480:
                errors.append(f"{fixture}: default_duration must be minutes 5-480, got {value!r}")
        elif not re.fullmatch(PREFERENCE_VALUES[key], value, re.IGNORECASE):
            errors.append(f"{fixture}: {key} value {value!r} is not in the documented encoding")
        elif key.endswith("_reminders") and value.lower() != "none":
            minutes = [int(part) for part in re.split(r"\s*,\s*", value)]
            if len(minutes) > 5 or any(not 0 <= m <= 40320 for m in minutes):
                errors.append(f"{fixture}: {key} allows at most 5 values, each 0-40320")
        elif key == "quiet_hours" and "-" in value and value[:5] == value[6:]:
            errors.append(f"{fixture}: quiet_hours must not start and end at the same time")


def style_checks(name: str, args: dict, fixture: str) -> None:
    """The prompt's "# Writing style": the card's table shows days and times, so the summary must not."""
    texts = []
    if name == "update_preferences":
        summary = args["summary_for_user"]
        texts.append(("summary_for_user", summary))
        if len([part for part in SENTENCE_END.split(summary) if part.strip()]) > 1:
            errors.append(f"{fixture}: update_preferences.summary_for_user must be one sentence")
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


NOTE_ITEM_MAX = 40
BULLET_START = re.compile(r"^\s*(?:[•·・\-–—*+✓✔]|\d{1,2}[.):、])")
PRICE = re.compile(r"[$€£¥]|\b(?:usd|eur|gbp|jpy|twd|ntd|nt)\b|\d\s*(?:元|円|塊|美元|日圓|日幣|台幣|歐元|英鎊)", re.IGNORECASE)
DOSE = re.compile(r"\b\d+\s*mg\b|\bdos(?:e|age)\b|劑量|服用|吃藥|退燒藥|止痛藥|antibiotic", re.IGNORECASE)
CJK = re.compile(r"[\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\uac00-\ud7af]")


def note_key(text: str) -> str:
    """Compared like NoteSuggester.normalized: case, width and punctuation ignored, no spaces."""
    folded = unicodedata.normalize("NFKC", text).casefold()
    return "".join(ch for ch in folded if ch.isalnum())


def note_item_checks(items: list[str], title: str, notes: str, already: list[str], where: str) -> None:
    """Suggested notes: chips in the language of the title, short, no bullets, repeats, prices or doses, nothing the
    notes or the app's own suggestions (ALREADY SUGGESTED) already say."""
    chinese = bool(CJK.search(title))
    seen: list[str] = []
    taken = [note_key(text) for text in already if note_key(text)]
    notes_key = note_key(notes)
    for item in items:
        key = note_key(item)
        if not key:
            errors.append(f"{where}: empty item")
            continue
        if len(item) > NOTE_ITEM_MAX:
            errors.append(f"{where}: {item!r} is longer than {NOTE_ITEM_MAX} characters")
        if BULLET_START.match(item) or item.rstrip().endswith((".", "。")):
            errors.append(f"{where}: {item!r} has a bullet, numbering or a final full stop (the app adds the bullet)")
        if chinese and not CJK.search(item):
            errors.append(f"{where}: {item!r} is not in the language of the title {title!r}")
        if not chinese and CJK.search(item):
            errors.append(f"{where}: {item!r} is not in the language of the title {title!r}")
        if PRICE.search(item):
            errors.append(f"{where}: {item!r} names a price")
        if DOSE.search(item):
            errors.append(f"{where}: {item!r} reads as medical advice")
        if any(key in other or other in key for other in seen):
            errors.append(f"{where}: {item!r} repeats another item")
        if any(key in other or other in key for other in taken):
            errors.append(f"{where}: {item!r} repeats what ALREADY SUGGESTED offers")
        if notes_key and key in notes_key:
            errors.append(f"{where}: {item!r} is already in the event's notes")
        seen.append(key)


def suggestion_checks(name: str, args: dict, root: dict, fixture: str) -> None:
    if name == "create_events":
        for index, event in enumerate(args["events"]):
            if "suggested_notes" in event:
                note_item_checks(event["suggested_notes"], event["title"], event.get("notes", ""), [],
                                 f"{fixture}: events[{index}].suggested_notes")
    if name == "suggest_event_notes":
        event = root.get("event")
        if not isinstance(event, dict) or not event.get("title"):
            errors.append(f"{fixture}: suggest_event_notes fixtures need the 'event' the request describes")
            return
        utterance = root.get("utterance", "")
        if not utterance.startswith(f"EVENT\ntitle: {event['title']}\n"):
            errors.append(f"{fixture}: the utterance is the request the app sends (EVENT, then 'title: …')")
        lines = {line.split(": ", 1)[0]: line.split(": ", 1)[1] for line in utterance.splitlines() if ": " in line}
        offered = lines.get("ALREADY SUGGESTED", "")
        already = [] if offered in ("", "(none)") else offered.split("; ")
        expected_language = "zh-Hant" if CJK.search(event["title"]) else "en"
        if lines.get("language") != expected_language:
            errors.append(f"{fixture}: language must be {expected_language}, the language of the title")
        if not 1 <= len(args["items"]) <= 4:
            errors.append(f"{fixture}: suggest_event_notes gives 1-4 items")
        note_item_checks(args["items"], event["title"], event.get("notes", ""), already, f"{fixture}: items")


def declaration_checks(by_name: dict) -> None:
    """suggest_event_notes exists (items only, at most 4) and create_events may carry suggested_notes (at most 4)."""
    suggest = by_name.get("suggest_event_notes")
    if not suggest:
        errors.append("suggest_event_notes is missing from the declarations")
    else:
        params = suggest["parameters"]
        if params.get("required") != ["items"] or params["properties"]["items"].get("maxItems") != 4:
            errors.append("suggest_event_notes: 'items' is required and holds at most 4")
    event_props = by_name["create_events"]["parameters"]["properties"]["events"]["items"]["properties"]
    suggested = event_props.get("suggested_notes")
    if not suggested or suggested.get("type") != "array" or suggested.get("maxItems") != 4:
        errors.append("create_events: events[].suggested_notes must be an optional array of at most 4")
    if "suggested_notes" in by_name["create_events"]["parameters"]["properties"]["events"]["items"].get("required", []):
        errors.append("create_events: suggested_notes must stay optional")


def context_checks(root: dict, fixture: str) -> None:
    """Review fixtures: confirm_plan needs a draft plan or pending events on screen; a revision is a complete plan
    that keeps its title; modify_event uses an id the prompt showed; update_preferences values are well-formed."""
    call = root["expected_call"]
    if call["name"] == "confirm_plan" and not (root.get("draft_plan") or root.get("pending_events")):
        errors.append(f"{fixture}: confirm_plan is only valid while a DRAFT PLAN or PENDING EVENTS block is shown "
                      "(add 'draft_plan' or 'pending_events')")
    if call["name"] == "update_preferences":
        preference_checks(call["args"], root, fixture)
    if call["name"] == "modify_event" and ("upcoming" in root or "focus_event" in root):
        rows = (root.get("upcoming", "") + "\n" + root.get("focus_event", "")).splitlines()
        shown = {row.split("|")[0].strip() for row in rows if row.strip()}
        if call["args"]["event_id"] not in shown:
            errors.append(f"{fixture}: modify_event uses an id that is not in UPCOMING or FOCUS")
    if "revises" in root:
        original = json.loads((FIXTURES / root["revises"]).read_text())["expected_call"]
        if original["name"] != call["name"] or call["name"] != "create_long_term_plan":
            errors.append(f"{fixture}: a revision must be create_long_term_plan, like {root['revises']}")
        elif original["args"]["plan_title"] != call["args"]["plan_title"]:
            errors.append(f"{fixture}: a revision keeps plan_title unless the user renames it")


# The prompt builders: calendars reach Gemini only through CalendarAliases, never as "<name> | <email>".
PROMPT_SOURCES = ["Shared/AI/AssistantPrompt.swift", "Shared/AI/NoteSuggestionPrompt.swift"]
ACCOUNT_ADDRESS = re.compile(r"\b(accountEmail|promptLabel)\b")


def privacy_checks(root: dict, fixture: str) -> None:
    """Fixtures mirror the prompt, which shows no Google account email: CALENDARS and PREFERENCES hold no address."""
    for field in ("calendars", "preferences"):
        if "@" in str(root.get(field, "")):
            errors.append(f"{fixture}: {field} holds an email address; the prompt names accounts 'Account N' "
                          "(docs/GEMINI_FUNCTION_CALLING.md §10.6)")


def prompt_source_checks() -> None:
    for relative in PROMPT_SOURCES:
        for number, line in enumerate((ROOT / relative).read_text(encoding="utf-8").splitlines(), 1):
            code = line.split("//", 1)[0]
            if ACCOUNT_ADDRESS.search(code):
                errors.append(f"{relative}:{number}: reads an account's address; name calendars through CalendarAliases")


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


# ---------- Version 1.0 sells nothing ----------

STOREKIT_USE = re.compile(r"\bimport StoreKit\b|\bSubscriptionStore\b|\bmanageSubscriptionsSheet\b|\bAppStore\.sync\b"
                          r"|\bTransaction\.(?:updates|currentEntitlements)\b|\bProduct\.products\b")
SUBSCRIPTION_COPY = re.compile(r'"[^"\n]*(?:[Ss]ubscription|Restore Purchases|Smart Schedules? Pro)[^"\n]*"')
SUBSCRIPTION_FLAG = "AppConstants.subscriptionsEnabled"


def subscription_checks() -> int:
    """Owner decision for 1.0: no subscription. The flag is false, and every file that calls StoreKit or shows
    subscription copy reads it, so a new Pro surface cannot ship ungated. Comments are ignored."""
    constants = (ROOT / "Shared/Core/AppConstants.swift").read_text(encoding="utf-8")
    if not re.search(r"^\s*static let subscriptionsEnabled = false\b", constants, re.M):
        errors.append("Shared/Core/AppConstants.swift: version 1.0 needs `static let subscriptionsEnabled = false`")
    gated = 0
    for directory in SWIFT_DIRS:
        for path in sorted((ROOT / directory).rglob("*.swift")):
            code = re.sub(r"//.*", "", path.read_text(encoding="utf-8"))
            if STOREKIT_USE.search(code) or SUBSCRIPTION_COPY.search(code):
                gated += 1
                if SUBSCRIPTION_FLAG not in code:
                    errors.append(f"{path.relative_to(ROOT)}: StoreKit or subscription copy without {SUBSCRIPTION_FLAG}")
    return gated


# ---------- Version 1.0 has no push-to-start and no remote push ----------

PUSH_TO_START_USE = re.compile(r'\bpushToStartToken(?:Updates)?\b|"devices/push-to-start"'
                               r'|\bPushToStartRegistrar\.(?:install|sync|uploadIfNeeded|eraseAll)\b')
PUSH_TO_START_FLAG = "AppConstants.pushToStartEnabled"
PUSH_FLAGS = ("pushToStartEnabled", "liveActivityPushEnabled")


def push_checks() -> int:
    """Owner decision for 1.0: no iOS 18 push-to-start, nothing about events on the server, no APNs. The flag is false,
    and every file that could ask for a token or send the registration reads it, so a new path cannot ship ungated.
    aps-environment follows the flags both ways; remote-notification must be gone while they are off. Comments are
    ignored."""
    constants = (ROOT / "Shared/Core/AppConstants.swift").read_text(encoding="utf-8")
    if not re.search(r"^\s*static let pushToStartEnabled = false\b", constants, re.M):
        errors.append("Shared/Core/AppConstants.swift: version 1.0 needs `static let pushToStartEnabled = false`")
    gated = 0
    for directory in SWIFT_DIRS:
        for path in sorted((ROOT / directory).rglob("*.swift")):
            code = re.sub(r"//.*", "", path.read_text(encoding="utf-8"))
            if PUSH_TO_START_USE.search(code):
                gated += 1
                if PUSH_TO_START_FLAG not in code:
                    errors.append(f"{path.relative_to(ROOT)}: push-to-start token or upload without {PUSH_TO_START_FLAG}")
    push_on = any(re.search(rf"^\s*static let {flag} = true\b", constants, re.M) for flag in PUSH_FLAGS)
    project = re.sub(r"(^|\s)#.*", r"\1", (ROOT / "project.yml").read_text(encoding="utf-8"))
    if push_on and "aps-environment" not in project:
        errors.append(f"project.yml: {' / '.join(PUSH_FLAGS)} is on, so the app needs aps-environment: $(APS_ENVIRONMENT)")
    for entry in ([] if push_on else ["aps-environment", "remote-notification"]):
        if entry in project:
            errors.append(f"project.yml: no {entry} while {' and '.join(PUSH_FLAGS)} are false (no remote push in 1.0)")
    return gated


# ---------- Version 1.0 has no microphone ----------

MICROPHONE_USE = re.compile(r"^\s*import Speech\b|\bSFSpeech\w*|\bSpeech(?:Analyzer|Transcriber)\b"
                            r"|\bAVAudio(?:Engine|Session|Recorder|Application)\b|\brequestRecordPermission\b", re.M)
MICROPHONE_PERMISSIONS = ("NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription")


def microphone_checks() -> None:
    """Owner decision for 1.0 (2026-10-16): no in-app microphone or speech recognition. Typing, the keyboard's own
    dictation and Siri (App Intents) cover speaking, and none of them needs the app to record. A Swift file that records
    audio or calls Apple's speech recognizer fails, and so does a microphone or speech-recognition usage description
    in project.yml or a .strings file (a permission the app never asks for is an App Review question). Comments are
    ignored."""
    for directory in SWIFT_DIRS:
        for path in sorted((ROOT / directory).rglob("*.swift")):
            code = re.sub(r"//.*", "", path.read_text(encoding="utf-8"))
            if MICROPHONE_USE.search(code):
                errors.append(f"{path.relative_to(ROOT)}: records audio or uses speech recognition (1.0 has no microphone)")
    texts = {ROOT / "project.yml": re.sub(r"(^|\s)#.*", r"\1", (ROOT / "project.yml").read_text(encoding="utf-8"))}
    texts.update({path: re.sub(r"/\*.*?\*/", "", path.read_text(encoding="utf-8"), flags=re.S) for path in STRINGS_FILES})
    for path, text in texts.items():
        for key in MICROPHONE_PERMISSIONS:
            if key in text:
                errors.append(f"{path.relative_to(ROOT)}: {key} is declared, but 1.0 has no microphone")


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
    declaration_checks(by_name)

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
        suggestion_checks(call["name"], call["args"], fixture, path.name)
        context_checks(fixture, path.name)
        privacy_checks(fixture, path.name)
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

    prompt_source_checks()
    print("✓ prompt builders name calendars without account emails")

    print(f"✓ String Catalog: {catalog_checks()} keys with zh-Hant")
    strings_file_checks()
    print(f"✓ Subscriptions off: {subscription_checks()} files gated by {SUBSCRIPTION_FLAG}")
    print(f"✓ Push-to-start off, no aps-environment: {push_checks()} files gated by {PUSH_TO_START_FLAG}")
    microphone_checks()
    print("✓ No microphone or speech recognition, no usage descriptions for them")

    if errors:
        print("\n".join(f"✗ {e}" for e in errors), file=sys.stderr)
        return 1
    print("All checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
