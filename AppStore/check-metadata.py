"""Checks metadata.md fields against App Store Connect limits.

Usage: python3 AppStore/check-metadata.py
"""
import os
import re
import sys

LIMITS = {
    "Name": 30,
    "Subtitle": 30,
    "Promotional text": 170,
    "Description": 4000,
    "Keywords": 100,
    "What's New": 4000,
    "Copyright": 200,
}

path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "metadata.md")
text = open(path, encoding="utf-8").read()

failed = False
for field, limit in LIMITS.items():
    match = re.search(r"^### " + re.escape(field) + r"\b.*?\n```\n(.*?)\n```", text, re.S | re.M)
    if not match:
        print(f"MISSING  {field}")
        failed = True
        continue
    value = match.group(1)
    count = len(value)
    ok = count <= limit
    extra = ""
    if field == "Keywords":
        if " " in value:
            ok, extra = False, "  (contains spaces)"
        words = value.split(",")
        if len(set(words)) != len(words):
            ok, extra = False, "  (repeated keyword)"
    print(f"{'OK  ' if ok else 'OVER'}  {field:<17} {count:>5} / {limit}{extra}")
    failed |= not ok

sys.exit(1 if failed else 0)
