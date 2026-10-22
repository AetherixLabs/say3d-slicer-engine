#!/usr/bin/env bash
# Runs build-android/out/orca-slicer-cli on a connected arm64 device or
# emulator: a 20 mm cube (A1, PLA, 0.2 mm) and an overhanging T with tree
# supports. Prints wall time, peak RSS and the answer; checks the G-code.
#   PACK=/path/to/pack ./scripts/android-smoke.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ADB="${ADB:-adb}"
PACK="${PACK:?set PACK to an engine pack folder (catalog.json + profiles/)}"
D=/data/local/tmp/orca
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
(cd "$TMP" && python3 "$ROOT/android/test/make-models.py")
"$ADB" shell mkdir -p "$D/pack/profiles" "$D/out"
"$ADB" push -q "$PACK/catalog.json" "$D/pack/"
"$ADB" push -q "$PACK/profiles/a1" "$D/pack/profiles/"
"$ADB" push -q "$ROOT/build-android/out/orca-slicer-cli" "$TMP/cube20.stl" "$TMP/tshape.stl" "$D/"
"$ADB" shell chmod 755 "$D/orca-slicer-cli"
for job in "cube20 off" "tshape tree"; do
  set -- $job
  printf '{"pack":"%s/pack","printer":"a1","material":"pla","layerHeight":0.2,"supports":"%s","input":"%s/%s.stl","output":"%s/out/%s.gcode"}' \
    "$D" "$2" "$D" "$1" "$D" "$1" > "$TMP/req.json"
  "$ADB" push -q "$TMP/req.json" "$D/req-$1.json"
  "$ADB" shell "cd $D && /system/bin/time -v ./orca-slicer-cli req-$1.json 2>t.txt >a.json; cat a.json; grep -E 'Real time|Max RSS' t.txt"
  "$ADB" shell "grep -q '^; HEADER_BLOCK_START' $D/out/$1.gcode && grep -q '^; total layer number: [1-9]' $D/out/$1.gcode" \
    && echo "$1: G-code OK" || { echo "$1: G-code check failed"; exit 1; }
done
