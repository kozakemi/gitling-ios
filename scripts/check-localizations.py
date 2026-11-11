#!/usr/bin/env python3
"""Fail when a String Catalog entry is missing Chinese or Japanese."""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOGS = [
    ROOT / "Gitling/Localizable.xcstrings",
    ROOT / "Shared/Localizable.xcstrings",
]
LANGUAGES = ("zh-Hans", "ja")

failures = []
for path in CATALOGS:
    data = json.loads(path.read_text())
    for key, entry in data["strings"].items():
        # Xcode may extract empty UI literals and explicitly non-translatable entries.
        if not key or entry.get("shouldTranslate") is False:
            continue
        for language in LANGUAGES:
            value = entry.get("localizations", {}).get(language, {}).get("stringUnit", {}).get("value")
            if not value:
                failures.append(f"{path.relative_to(ROOT)}: {language}: {key!r}")

if failures:
    print("Missing localizations:")
    print("\n".join(failures))
    sys.exit(1)
print("All String Catalog entries have zh-Hans and ja translations.")
