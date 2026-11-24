"""Checks App Store Connect field lengths in docs/appstore/metadata.md.

Usage: python3 -I docs/appstore/check_metadata.py
"""
import pathlib
import re
import sys

LIMITS = {
    "Name": 30, "Название": 30,
    "Subtitle": 30, "Подзаголовок": 30,
    "Promotional text": 170, "Рекламный текст": 170,
    "Keywords": 100, "Ключевые слова": 100,
    "Description": 4000, "Описание": 4000,
}

text = pathlib.Path(__file__).with_name("metadata.md").read_text(encoding="utf-8")
failed = False
for match in re.finditer(r"\*\*(.+?)\*\* \(\d+[^)]*\)\n```\n(.*?)\n```", text, re.S):
    field, value = match.group(1), match.group(2)
    limit = LIMITS.get(field)
    if limit is None:
        continue
    ok = len(value) <= limit
    failed |= not ok
    print(f"{'OK ' if ok else 'TOO LONG'} {field}: {len(value)}/{limit}")
sys.exit(1 if failed else 0)
