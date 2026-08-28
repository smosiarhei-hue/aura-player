from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CHROME = ROOT / "Aurora" / "playerchrome.swift"
text = CHROME.read_text(encoding="utf-8")
invalid = r"@Environment(\\.dismiss)"
valid = r"@Environment(\.dismiss)"
if invalid in text:
    text = text.replace(invalid, valid)
elif valid not in text:
    raise RuntimeError("queue dismiss environment key path was not found")
CHROME.write_text(text, encoding="utf-8")
print("Generated queue key path normalized for Swift compilation.")
