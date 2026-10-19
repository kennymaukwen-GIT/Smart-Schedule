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
9. Voice input (the mic button, owner decision 2026-10-18) recognises speech on the iPhone only: microphone and speech
   code lives only in App/Voice (Shared/, the widget and the notification extension have none); every
   SFSpeech*RecognitionRequest a Swift file creates is a named constant that sets requiresOnDeviceRecognition = true,
   and nothing sets it to anything else; App/Voice writes no audio file, makes no network request, uses no other speech
   API (file requests, iOS 26's SpeechAnalyzer) and reads no subscription flag (voice input is free).
   NSMicrophoneUsageDescription and NSSpeechRecognitionUsageDescription are declared for the app target (English in
   project.yml, saying "on this iPhone"; zh-Hant in every InfoPlist.strings) and for neither extension.
10. A time counted from now (prompt rule 7: "1個小時後", "in an hour"): a fixture with "relative_minutes" says such a
    time and creates one event that starts at now_local plus that many minutes (the next day past midnight), with no
    time phrase in its title, no reminder_minutes (the app gives an item created for later the same day a reminder
    10 minutes before and one at the start, ReminderPolicy.sameDayMinutes) and no end.

11. Background refresh is registered with BGTaskScheduler once, as the first statement of AppDelegate's didFinishLaunching
    (AppRefresh.registerHandler), for the one identifier in BGTaskSchedulerPermittedIdentifiers, never with SwiftUI's
    .backgroundTask: Apple DTS confirms SwiftUI can register it after launch has finished (developer forums 775182), most
    likely why the app crashed when the Control Center button launched it (owner's iPhone, 2026-10-19).
12. AddPlanIntent (Siri, Shortcuts, the Action Button) can add, move and delete events, so it declares
    authenticationPolicy = .requiresAuthentication: a locked iPhone asks for Face ID or the passcode first (the default,
    .alwaysAllowed, runs it from the Lock Screen). App/ is not compiled into the unit tests, so this is checked here;
    NotificationActionsTests checks the notification reply action's .authenticationRequired.

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
    """suggest_event_notes exists (items only, at most 4) and create_events may carry suggested_notes (at most 4, said in
    its description). create_events has no minItems/maxItems anywhere: Gemini 3.8 Flash refuses the whole request
    (400 INVALID_ARGUMENT) when they are in it under mode ANY (2026-10-17, npm run check-request); the app enforces
    20 events, 5 reminders and 4 suggested notes itself."""
    suggest = by_name.get("suggest_event_notes")
    if not suggest:
        errors.append("suggest_event_notes is missing from the declarations")
    else:
        params = suggest["parameters"]
        if params.get("required") != ["items"] or params["properties"]["items"].get("maxItems") != 4:
            errors.append("suggest_event_notes: 'items' is required and holds at most 4")
    event_props = by_name["create_events"]["parameters"]["properties"]["events"]["items"]["properties"]
    suggested = event_props.get("suggested_notes")
    if not suggested or suggested.get("type") != "array" or "Up to 4" not in suggested.get("description", ""):
        errors.append("create_events: events[].suggested_notes must be an optional array of at most 4 (in its description)")
    if re.search(r'"(minItems|maxItems)"', json.dumps(by_name["create_events"])):
        errors.append("create_events: no minItems/maxItems (Gemini 3.8 Flash rejects them under mode ANY)")
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


# A time counted from now: "1個小時後", "半小時後", "一個半小時後", "10 分鐘後", "in an hour", "in half an hour",
# "2 hours from now". Not a clock time followed by 後 ("三點後", "3點10分後"), and not "延後 1 小時" or "提前 2 小時提醒"
# (no 後 right after the unit). English minutes need digits, so "in a minute" is not one.
FROM_NOW_ZH = re.compile(
    r"(?<![點点時时:：0-9零〇一二兩两三四五六七八九十])(?:(半)|([0-9]{1,3}|[零〇一二兩两三四五六七八九十]{1,4})\s*(?:個|个)?\s*(半)?)"
    r"\s*(?:個|个)?\s*(小時|小时|鐘頭|钟头|分鐘|分钟)\s*(?:以後|以后|之後|之后|後|后)")
FROM_NOW_EN = [re.compile(pattern, re.IGNORECASE) for pattern in (
    r"\bin\s+(?:an?|one)\s+hour\s+and\s+a\s+half\b",
    r"\bin\s+half\s+an\s+hour\b",
    r"\bin\s+(?:an?|one)\s+hour\b",
    r"\bin\s+(\d{1,3})\s*(?:h|hrs?|hours?)\b",
    r"\bin\s+(\d{1,4})\s*(?:mins?|minutes?)\b",
    r"\b(an?|one|\d{1,3})\s*(hours?|hrs?|minutes?|mins?)\s+from\s+now\b",
)]


def says_time_from_now(text: str) -> bool:
    return bool(FROM_NOW_ZH.search(text)) or any(pattern.search(text) for pattern in FROM_NOW_EN)


def relative_time_checks(root: dict, fixture: str) -> None:
    """Prompt rule 7: a time counted from now ("1個小時後", "in an hour") starts at now_local plus that much, on the next
    day past midnight; the title keeps no time phrase; reminder_minutes is left out (the app gives an item created for
    later the same day 10 minutes before and at the start, the kind's defaults on a later day)."""
    delta = root.get("relative_minutes")
    if delta is None:
        return
    call = root["expected_call"]
    if call["name"] != "create_events" or len(call["args"]["events"]) != 1:
        errors.append(f"{fixture}: relative_minutes fixtures create exactly one event")
        return
    event = call["args"]["events"][0]
    if not says_time_from_now(root["utterance"]):
        errors.append(f"{fixture}: the utterance says no time counted from now")
    expected = (datetime.fromisoformat(root["now_local"]) + timedelta(minutes=delta)).strftime("%Y-%m-%dT%H:%M")
    if event["start"] != expected:
        errors.append(f"{fixture}: start {event['start']} is not now_local + {delta} min ({expected})")
    # No \b around the time: in "買蛋23:50" there is no word boundary between the characters and the digits.
    if says_time_from_now(event["title"]) or re.search(r"\d{1,2}:\d{2}", event["title"]):
        errors.append(f"{fixture}: the title keeps the time phrase")
    if "reminder_minutes" in event:
        errors.append(f"{fixture}: a time counted from now leaves reminder_minutes out (the app gives an item created "
                      "for later the same day 10 minutes before and at the start)")
    if "end" in event:
        errors.append(f"{fixture}: no end unless the user gave one; the default length applies")


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


# ---------- Voice input: on the iPhone only ----------

VOICE_DIR = "App/Voice"
# Anything that reaches the microphone or Apple's speech recognition.
VOICE_API = re.compile(r"^\s*import Speech\b|\bSFSpeech\w*|\bAVAudio(?:Engine|Session|Application|InputNode|Recorder)\b"
                       r"|\bAVCaptureAudio\w*|\b(?:request)?[Rr]ecordPermission\b"
                       r"|\b(?:SpeechAnalyzer|SpeechTranscriber|DictationTranscriber|SpeechDetector)\b", re.M)
# In App/Voice: audio written to a file, a network request, another speech path, or a subscription gate.
VOICE_FORBIDDEN = [
    (re.compile(r"\bAVAudioRecorder\b|\bAVAudioFile\b|\bAVAssetWriter\b|\bwrite\(to:|\bFileManager\b"),
     "writes audio or files (no audio is stored)"),
    (re.compile(r"\bURLSession\b|\bURLRequest\b|\bServerClient\b|\bGeminiClient\b"),
     "makes a network request (no audio is sent anywhere)"),
    (re.compile(r"\bSFSpeechURLRecognitionRequest\b|\b(?:SpeechAnalyzer|SpeechTranscriber|DictationTranscriber)\b"),
     "uses a speech API other than SFSpeechRecognizer with SFSpeechAudioBufferRecognitionRequest"),
    (re.compile(r"\bsubscriptionsEnabled\b|\bSubscriptionStore\b|\bisPro\b"),
     "reads a subscription flag (voice input is free)"),
]
REQUEST_CREATION = re.compile(r"\bSFSpeech\w*RecognitionRequest\s*\(")
NAMED_REQUEST = re.compile(r"\b(?:let|var)\s+(\w+)\s*=\s*SFSpeech\w*RecognitionRequest\s*\(")
ON_DEVICE_ASSIGNMENT = re.compile(r"\brequiresOnDeviceRecognition\s*=\s*([^\n;]*)")
VOICE_PERMISSIONS = ("NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription")
APP_TARGET, EXTENSION_TARGETS = "SmartSchedule", ("SmartScheduleWidgets", "SmartScheduleNotificationContent")


def target_block(project: str, name: str) -> str | None:
    match = re.search(rf"^  {name}:\n(.*?)(?=^  \S|\Z)", project, re.M | re.S)
    return match.group(1) if match else None


def voice_checks() -> int:
    """Owner decision 2026-10-18: the app's own voice input is back, Traditional Chinese (Taiwan) and English, free, with
    speech recognised on the iPhone only, never by Apple's servers; no audio is stored or sent. Comments are ignored.
    Returns the number of recognition requests checked."""
    requests = 0
    for directory in SWIFT_DIRS:
        for path in sorted((ROOT / directory).rglob("*.swift")):
            relative = path.relative_to(ROOT)
            code = re.sub(r"//.*", "", path.read_text(encoding="utf-8"))
            in_voice = relative.parts[:2] == tuple(VOICE_DIR.split("/"))
            if VOICE_API.search(code) and not in_voice:
                errors.append(f"{relative}: microphone or speech recognition outside {VOICE_DIR} "
                              "(the extensions have no microphone)")
            if in_voice:
                for pattern, problem in VOICE_FORBIDDEN:
                    if pattern.search(code):
                        errors.append(f"{relative}: {problem}")
            created = REQUEST_CREATION.findall(code)
            named = NAMED_REQUEST.findall(code)
            requests += len(created)
            if len(named) != len(created):
                errors.append(f"{relative}: assign each SFSpeech*RecognitionRequest to a constant that sets "
                              "requiresOnDeviceRecognition = true")
            for name in named:
                if not re.search(rf"\b{name}\.requiresOnDeviceRecognition\s*=\s*true\b", code):
                    errors.append(f"{relative}: {name} must set requiresOnDeviceRecognition = true (speech is "
                                  "recognised on the iPhone only)")
            for value in ON_DEVICE_ASSIGNMENT.findall(code):
                if value.strip() != "true":
                    errors.append(f"{relative}: requiresOnDeviceRecognition = {value.strip()} (must be true)")
    if requests == 0:
        errors.append(f"{VOICE_DIR}: no SFSpeechAudioBufferRecognitionRequest found (the mic button's recognizer)")

    project = re.sub(r"(^|\s)#.*", r"\1", (ROOT / "project.yml").read_text(encoding="utf-8"))
    app = target_block(project, APP_TARGET) or ""
    for key in VOICE_PERMISSIONS:
        match = re.search(rf"^\s+{key}:\s*(.+)$", app, re.M)
        if not match:
            errors.append(f"project.yml: target {APP_TARGET} needs {key} (asked on the mic button's first tap)")
        elif "on this iPhone" not in match.group(1):
            errors.append(f"project.yml: {key} must say speech is turned into text on this iPhone")
    for name in EXTENSION_TARGETS:
        block = target_block(project, name)
        if block is None:
            errors.append(f"project.yml: target {name} not found")
            continue
        for key in VOICE_PERMISSIONS:
            if key in block:
                errors.append(f"project.yml: {name} declares {key}, but the extensions have no microphone")
    for path in STRINGS_FILES:
        if path.name != "InfoPlist.strings":
            continue
        text = re.sub(r"/\*.*?\*/", "", path.read_text(encoding="utf-8"), flags=re.S)
        for key in VOICE_PERMISSIONS:
            match = re.search(rf'^"{key}"\s*=\s*"(.+)";$', text, re.M)
            if not match:
                errors.append(f"{path.relative_to(ROOT)}: {key} is missing (project.yml declares it in English)")
            elif "iPhone" not in match.group(1):
                errors.append(f"{path.relative_to(ROOT)}: {key} must say speech is turned into text on this iPhone")
    return requests


def notification_extension_checks() -> None:
    """The long-press card (SmartScheduleNotificationContent) only loads when the extension binary links
    UserNotificationsUI: it uses no symbol of it, so `import UserNotificationsUI` alone is dropped by the linker and iOS
    shows a blank box (owner's iPhone, 2026-10-18). project.yml must link both frameworks explicitly, and the
    extension's categories must be the ones the app posts (NotificationIDs.Category)."""
    text = re.sub(r"(^|\s)#.*", r"\1", (ROOT / "project.yml").read_text(encoding="utf-8"))
    block = re.search(r"^  SmartScheduleNotificationContent:\n(.*?)(?=^  \S|\Z)", text, re.M | re.S)
    if not block:
        errors.append("project.yml: target SmartScheduleNotificationContent not found")
        return
    for framework in ("UserNotifications.framework", "UserNotificationsUI.framework"):
        if not re.search(rf"^\s*- sdk: {re.escape(framework)}\s*$", block.group(1), re.M):
            errors.append(f"project.yml: SmartScheduleNotificationContent must link {framework} (dependencies: - sdk:)")
    listed = re.search(r"UNNotificationExtensionCategory:\s*\[([^\]]*)\]", block.group(1))
    ids = (ROOT / "Shared/Notifications/NotificationIDs.swift").read_text(encoding="utf-8")
    category_enum = re.search(r"enum Category \{(.*?)\}", ids, re.S)
    posted = sorted(re.findall(r'static let \w+ = "([^"]+)"', category_enum.group(1))) if category_enum else []
    configured = sorted(c.strip() for c in listed.group(1).split(",")) if listed else []
    if not posted or configured != posted:
        errors.append(f"project.yml: UNNotificationExtensionCategory {configured} must equal NotificationIDs.Category {posted}")
    else:
        print(f"✓ Notification content extension links UserNotifications + UserNotificationsUI; categories {configured}")


def background_task_checks() -> None:
    """Check 11: BGTaskScheduler wants every launch handler registered before launch finishes, once, for an identifier
    in BGTaskSchedulerPermittedIdentifiers. SwiftUI's `.backgroundTask` can register it too late (Apple DTS, developer
    forums 775182), which most likely crashed the app when the Control Center button launched it."""
    before = len(errors)
    registrations = calls = 0
    for directory in SWIFT_DIRS:
        for path in sorted((ROOT / directory).rglob("*.swift")):
            relative = path.relative_to(ROOT)
            code = re.sub(r"//.*", "", path.read_text(encoding="utf-8"))
            if re.search(r"\.backgroundTask\s*\(", code):
                errors.append(f"{relative}: SwiftUI .backgroundTask can register its handler after launch and crash the "
                              "app; register with BGTaskScheduler in AppRefresh.registerHandler instead")
            registrations += len(re.findall(r"BGTaskScheduler\.shared\.register\s*\(", code))
            calls += len(re.findall(r"(?<!func )\bAppRefresh\.registerHandler\s*\(\)", code))
            calls += len(re.findall(r"(?<![\w.])registerHandler\s*\(\)", code)) - len(re.findall(r"func registerHandler\s*\(\)", code))
    if registrations != 1:
        errors.append(f"BGTaskScheduler.shared.register appears {registrations} times; register the refresh handler "
                      "exactly once (AppRefresh.registerHandler)")
    if calls != 1:
        errors.append(f"AppRefresh.registerHandler() is called {calls} times; call it exactly once, in didFinishLaunching "
                      "(a second registration stops the app)")
    app = re.sub(r"//.*", "", (ROOT / "App/SmartScheduleApp.swift").read_text(encoding="utf-8"))
    launch = re.search(r"didFinishLaunchingWithOptions[^{]*\{(.*?)\n\s*return true\s*\n\s*\}", app, re.S)
    if not launch or not re.match(r"\s*AppRefresh\.registerHandler\(\)", launch.group(1)):
        errors.append("App/SmartScheduleApp.swift: AppRefresh.registerHandler() must be the first statement of "
                      "AppDelegate's didFinishLaunching (not deferred into a Task or a queue)")
    constants = (ROOT / "Shared/Core/AppConstants.swift").read_text(encoding="utf-8")
    identifier = re.search(r'static let backgroundRefreshTaskID = "([^"]+)"', constants)
    project = re.sub(r"(^|\s)#.*", r"\1", (ROOT / "project.yml").read_text(encoding="utf-8"))
    permitted = re.search(r"BGTaskSchedulerPermittedIdentifiers:\s*\[([^\]]*)\]", target_block(project, APP_TARGET) or "")
    listed = [item.strip() for item in permitted.group(1).split(",")] if permitted else []
    if not identifier or listed != [identifier.group(1)]:
        errors.append(f"project.yml: BGTaskSchedulerPermittedIdentifiers {listed} must be exactly "
                      f"[{identifier.group(1) if identifier else '?'}] (AppConstants.backgroundRefreshTaskID)")
    if len(errors) == before:
        print(f"✓ Background refresh {listed[0]} registered once, first in didFinishLaunching (no SwiftUI .backgroundTask)")


ADD_PLAN_INTENT = "App/Intents/AddPlanIntent.swift"
AUTHENTICATION_POLICY = re.compile(r"\bstatic\s+(?:let|var)\s+authenticationPolicy\s*:\s*IntentAuthenticationPolicy\s*"
                                   r"=\s*\.(requiresAuthentication|requiresLocalDeviceAuthentication)\b")


def lock_screen_checks() -> None:
    """Check 12: AddPlanIntent writes to Google Calendar from Siri, Shortcuts and the Action Button, so a locked iPhone
    must ask for Face ID or the passcode first. `.requiresLocalDeviceAuthentication` (stricter: an unlocked Apple Watch
    does not count) passes too. Comments are ignored."""
    code = re.sub(r"//.*", "", (ROOT / ADD_PLAN_INTENT).read_text(encoding="utf-8"))
    match = AUTHENTICATION_POLICY.search(code)
    if not match:
        errors.append(f"{ADD_PLAN_INTENT}: AddPlanIntent needs `static let authenticationPolicy: "
                      "IntentAuthenticationPolicy = .requiresAuthentication` (it can add, move and delete events; the "
                      "default .alwaysAllowed runs it on a locked iPhone)")
    else:
        print(f"✓ AddPlanIntent asks a locked iPhone to unlock first (authenticationPolicy = .{match.group(1)})")



# ---------- Departure reminders: location When In Use, in the app only ----------

LOCATION_KEY = "NSLocationWhenInUseUsageDescription"
ALWAYS_LOCATION_KEYS = ("NSLocationAlwaysAndWhenInUseUsageDescription", "NSLocationAlwaysUsageDescription")
LOCATION_IMPORT = re.compile(r"^\s*(?:@preconcurrency\s+)?import\s+(?:CoreLocation|CoreLocationUI|MapKit)\b", re.M)
LOCATION_MANAGER = re.compile(r"\bCLLocationManager\s*\(")
LOCATION_DIR = "App/Departure"
BACKGROUND_LOCATION = re.compile(r"\b(?:requestAlwaysAuthorization|allowsBackgroundLocationUpdates|startUpdatingLocation"
                                 r"|startMonitoringSignificantLocationChanges|startMonitoringVisits"
                                 r"|CLBackgroundActivitySession|CLMonitor|liveUpdates)\b")


def location_checks() -> None:
    """Check 14: departure reminders 「該出發了」 (docs/SETTINGS.md §7.11) use the location only when the user asks, in
    the app in the foreground: When In Use permission, one fix at a time, nothing in the background. Core Location and
    MapKit stay in the app target (App/), so the extensions and the pure rules in Shared/Departure never get them, and
    only App/Departure creates a location manager. Comments are ignored."""
    before = len(errors)
    for directory in SWIFT_DIRS:
        for path in sorted((ROOT / directory).rglob("*.swift")):
            relative = path.relative_to(ROOT)
            code = re.sub(r"//.*", "", path.read_text(encoding="utf-8"))
            if LOCATION_IMPORT.search(code) and relative.parts[0] != "App":
                errors.append(f"{relative}: imports Core Location or MapKit outside App/ (the extensions have no "
                              "location; Shared/Departure keeps the rules pure behind protocols)")
            if LOCATION_MANAGER.search(code) and relative.parts[:2] != tuple(LOCATION_DIR.split("/")):
                errors.append(f"{relative}: creates a CLLocationManager outside {LOCATION_DIR} (DeviceLocation is the "
                              "only place that asks for the location)")
            for match in sorted(set(BACKGROUND_LOCATION.findall(code))):
                errors.append(f"{relative}: {match} (departure reminders take one fix while the app is open, never "
                              "continuous or background location)")

    project = re.sub(r"(^|\s)#.*", r"\1", (ROOT / "project.yml").read_text(encoding="utf-8"))
    app = target_block(project, APP_TARGET) or ""
    match = re.search(rf"^\s+{LOCATION_KEY}:\s*(.+)$", app, re.M)
    if not match:
        errors.append(f"project.yml: target {APP_TARGET} needs {LOCATION_KEY} (asked the first time the user asks "
                      "when to leave)")
    elif "Apple Maps" not in match.group(1) or "not saved" not in match.group(1):
        errors.append(f"project.yml: {LOCATION_KEY} must say the location goes only to Apple Maps and is not saved")
    for key in ALWAYS_LOCATION_KEYS:
        if key in project:
            errors.append(f"project.yml: {key} declared; departure reminders use When In Use only")
    modes = re.search(r"UIBackgroundModes:\s*\[([^\]]*)\]", app)
    if modes and "location" in modes.group(1):
        errors.append("project.yml: UIBackgroundModes has location; departure reminders never use it")
    for name in EXTENSION_TARGETS:
        block = target_block(project, name)
        if block is not None and "NSLocation" in block:
            errors.append(f"project.yml: {name} declares a location usage description, but the extensions have no "
                          "location")
    for path in STRINGS_FILES:
        if path.name != "InfoPlist.strings":
            continue
        text = re.sub(r"/\*.*?\*/", "", path.read_text(encoding="utf-8"), flags=re.S)
        found = re.search(rf'^"{LOCATION_KEY}"\s*=\s*"(.+)";$', text, re.M)
        if not found:
            errors.append(f"{path.relative_to(ROOT)}: {LOCATION_KEY} is missing (project.yml declares it in English)")
        elif "Apple 地圖" not in found.group(1) or "不會被保存" not in found.group(1):
            errors.append(f"{path.relative_to(ROOT)}: {LOCATION_KEY} must say the location goes only to Apple 地圖 "
                          "and 不會被保存")
    if len(errors) == before:
        print(f"✓ Location for departure reminders: {LOCATION_KEY} only (en + zh-Hant), app target only, no Always key "
              f"or background location; Core Location and MapKit only in App/, the location manager in {LOCATION_DIR}")


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
        relative_time_checks(fixture, path.name)
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
    print(f"✓ Voice input on the iPhone only: {voice_checks()} recognition request(s) with requiresOnDeviceRecognition "
          f"= true in {VOICE_DIR}; usage descriptions for the app target only (en + zh-Hant)")
    notification_extension_checks()
    background_task_checks()
    lock_screen_checks()
    location_checks()

    if errors:
        print("\n".join(f"✗ {e}" for e in errors), file=sys.stderr)
        return 1
    print("All checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
