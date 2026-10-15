#!/usr/bin/env python3
"""Fails when a tracked file holds something that must only live in local config or Worker secrets.

- Google API keys (AIza…, AQ.…): the Gemini key is the Worker secret GEMINI_API_KEY, never in the repo.
- Private keys (.p8 / .pem / .key files, PKCS#8 key material): the APNs key is the Worker secret APNS_PRIVATE_KEY.
- A concrete *.workers.dev host: the app reads GEMINI_BASE_URL from the git-ignored Config/Secrets.xcconfig, and
  docs use placeholders such as smart-schedule-worker.<account subdomain>.workers.dev.
- Personal email addresses (Gmail, Outlook, iCloud, Yahoo, university): placeholders contain "example"; the only
  real address is support@smart-schedules.com.

Usage: python3 -I scripts/check_repo_hygiene.py   (from the repository root; CI runs it)
"""
import re
import subprocess
import sys

SKIP = ("server/worker/package-lock.json",)
# Address-validation edge cases built from the example@gmail.com placeholder (a space or a second "@" inside it).
EMAIL_ALLOW = ("Tests/Unit/AccountEmailTests.swift",)
PERSONAL_DOMAINS = re.compile(
    r"@(gmail\.com|googlemail\.com|outlook\.com|hotmail\.com|live\.com|icloud\.com|me\.com|yahoo\.[a-z.]+|"
    r"[a-z0-9-]+\.ac\.uk|[a-z0-9-]+\.edu)$", re.I)
CHECKS = [
    ("Google API key", re.compile(r"AIza[0-9A-Za-z_-]{35}|AQ\.[A-Za-z0-9_-]{30,}")),
    ("private key material", re.compile(r"MIG[HT]AgEAMBMGByqGSM49AgEGCCqGSM49AwEHB[A-Za-z0-9+/]{20,}")),
    ("Worker host (use GEMINI_BASE_URL in Config/Secrets.xcconfig)", re.compile(r"(?<![\w<>.-])[a-z0-9-]+(\.[a-z0-9-]+)*\.workers\.dev")),
]
EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")


def tracked_files():
    out = subprocess.run(["git", "ls-files", "-z"], capture_output=True, check=True).stdout
    return [p for p in out.decode().split("\0") if p and not p.startswith(SKIP)]


def main():
    problems = []
    for path in tracked_files():
        if re.search(r"\.(p8|pem|key|p12|mobileprovision)$", path):
            problems.append(f"{path}: key or certificate file is tracked")
            continue
        try:
            text = open(path, encoding="utf-8").read()
        except (UnicodeDecodeError, IsADirectoryError, FileNotFoundError):
            continue
        for number, line in enumerate(text.splitlines(), 1):
            for label, pattern in CHECKS:
                if pattern.search(line):
                    problems.append(f"{path}:{number}: {label}")
            for address in [] if path in EMAIL_ALLOW else EMAIL.findall(line):
                local = address.split("@")[0].replace(".", "").lower()
                if PERSONAL_DOMAINS.search(address) and "example" not in local:
                    problems.append(f"{path}:{number}: personal email address (use an example.com placeholder)")
    if problems:
        print("\n".join(problems))
        print(f"\n{len(problems)} problem(s): move these to Config/Secrets.xcconfig, a Worker secret, or a placeholder.")
        return 1
    print("No keys, private keys, Worker hosts or personal email addresses in tracked files.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
