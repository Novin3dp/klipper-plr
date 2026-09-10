#!/usr/bin/env python3
"""Append the PLR auto-clear snippet to an END_PRINT macro."""
import os
import re
import shutil
import sys
import time

SNIPPET = '''
    # --- Klipper PLR: clear data after a successful resume ---
    {% if '/gcodes/plr/' in printer.virtual_sdcard.file_path|default("")|string %}
        M118 PLR resume finished - clearing data
        UPDATE_DELAYED_GCODE ID=PLR_POSTCLEAR DURATION=2
    {% endif %}
'''


def candidates(config_dir):
    printer_cfg = os.path.join(config_dir, "printer.cfg")
    yield printer_cfg
    try:
        text = open(printer_cfg, encoding="utf-8").read()
    except OSError:
        return
    for m in re.finditer(r"^\[include\s+(.+?)\]", text, re.M):
        include = m.group(1).strip()
        if any(ch in include for ch in "*?["):
            continue
        yield os.path.join(config_dir, include)


def patch(path):
    text = open(path, encoding="utf-8").read()
    if "PLR_POSTCLEAR" in text:
        return "already"
    m = re.search(r"^\[gcode_macro END_PRINT\]", text, re.M)
    if not m:
        return None
    nxt = re.search(r"^\[", text[m.end():], re.M)
    end = m.end() + nxt.start() if nxt else len(text)
    body = text[m.start():end].rstrip("\n")
    new = text[:m.start()] + body + "\n" + SNIPPET.rstrip("\n") + "\n\n" + text[end:]
    stamp = time.strftime("%Y%m%d_%H%M%S")
    shutil.copy2(path, f"{path}.bak.{stamp}")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(new)
    return "patched"


def main():
    if len(sys.argv) != 2:
        print("usage: patch_end_print.py <config_dir>", file=sys.stderr)
        return 1
    for path in candidates(sys.argv[1]):
        if not os.path.isfile(path):
            continue
        result = patch(path)
        if result == "already":
            print(os.path.basename(path))
            return 2
        if result == "patched":
            print(os.path.basename(path))
            return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
