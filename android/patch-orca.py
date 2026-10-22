#!/usr/bin/env python3
"""Hook the Android CLI target into OrcaSlicer's root CMakeLists.txt.

Runs after patches/apply.py (which makes the tree build headless). Idempotent.
"""
from pathlib import Path

ORCA = Path(__file__).resolve().parent.parent / "orca"
MARK = "# ── Android CLI (injected by android/patch-orca.py)"
BLOCK = f"""
{MARK}
if(DEFINED ORCA_ANDROID_DIR)
  set(ORCA_SRC "${{CMAKE_CURRENT_SOURCE_DIR}}/src")
  add_subdirectory("${{ORCA_ANDROID_DIR}}" android)
endif()
"""

root = ORCA / "CMakeLists.txt"
text = root.read_text(encoding="utf-8")
if MARK not in text:
    root.write_text(text + BLOCK, encoding="utf-8")
    print("  PATCHED: CMakeLists.txt (android CLI injection)")
else:
    print("  OK (no change): CMakeLists.txt (android CLI injection)")
