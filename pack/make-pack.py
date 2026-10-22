#!/usr/bin/env python3
"""Builds the Say3D engine pack: the folder a phone downloads and serves to
its web view.

    python3 pack/make-pack.py --engine <dir with slicer-mt.js/.wasm> \\
        --profiles <OrcaSlicer resources/profiles> --version 1.0.0 --out dist/pack

What goes in:

- `slicer-mt.js` / `slicer-mt.wasm`: the engine, with one line in front of the
  JS. WKWebView hides the `SharedArrayBuffer` global even on a cross-origin
  isolated page; shared wasm memory still works, and Emscripten checks only
  the name before it starts threads. The workers load the same file.
- `index.html`, `bridge.js`: the page and its protocol (PROTOCOL.md).
- `profiles/<printer>/`: OrcaSlicer's own Bambu Lab profiles, flattened
  (parent, then includes, then the profile's own keys) — one machine, a process
  per layer height, a filament per material.
- `catalog.json`: printer and material ids to those files.
- `LICENSE`, `NOTICE.md`, `SOURCE.md`: the licence and where the source is.
- `pack.json`: every file with its size and SHA-256. The host checks each file
  against it, and the dashboard gives the SHA-256 of `pack.json` itself.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# The app's printer ids to OrcaSlicer's machine profiles.
PRINTERS = {
    "a1": "Bambu Lab A1 0.4 nozzle",
    "a1mini": "Bambu Lab A1 mini 0.4 nozzle",
    "p1s": "Bambu Lab P1S 0.4 nozzle",
    "p1p": "Bambu Lab P1P 0.4 nozzle",
    "x1": "Bambu Lab X1 0.4 nozzle",
    "x1c": "Bambu Lab X1 Carbon 0.4 nozzle",
    "x1e": "Bambu Lab X1E 0.4 nozzle",
}

# The app's material ids: filament_type, then the profiles to prefer, best first.
MATERIALS = {
    "pla": ("PLA", ("Generic PLA", "Bambu PLA Basic")),
    "petg": ("PETG", ("Generic PETG", "Bambu PETG Basic")),
    "petg-hf": ("PETG", ("Generic PETG HF", "Bambu PETG HF")),
    "pla-silk": ("PLA", ("Generic PLA Silk", "Bambu PLA Silk")),
    "abs": ("ABS", ("Generic ABS", "Bambu ABS")),
    "asa": ("ASA", ("Generic ASA", "Bambu ASA")),
    "tpu": ("TPU", ("Generic TPU", "Bambu TPU 95A")),
}

# Layer heights the pack carries, and words to prefer in a process's name.
HEIGHTS = {
    "0.08": ("Extra Fine", "High Quality"),
    "0.12": ("Fine", "High Quality"),
    "0.16": ("Optimal", "High Quality"),
    "0.20": ("Standard",),
    "0.24": ("Draft",),
    "0.28": ("Extra Draft",),
}

POLYFILL = ("if (typeof SharedArrayBuffer === 'undefined') self.SharedArrayBuffer = "
            "new WebAssembly.Memory({ initial: 1, maximum: 1, shared: true }).buffer.constructor;\n")


def load(root: str) -> dict[str, dict]:
    """Every profile under OrcaSlicer's profiles folder by name; BBL's win."""
    out: dict[str, dict] = {}
    for folder, _, files in os.walk(root):
        for name in sorted(files):
            if not name.endswith(".json"):
                continue
            try:
                with open(os.path.join(folder, name), encoding="utf-8") as f:
                    p = json.load(f)
            except (json.JSONDecodeError, UnicodeDecodeError):
                continue
            if isinstance(p, dict) and "name" in p and (p["name"] not in out or f"{os.sep}BBL{os.sep}" in folder + os.sep):
                out[p["name"]] = p
    return out


def flatten(name: str, profiles: dict[str, dict]) -> dict:
    p = profiles[name]
    out = dict(flatten(p["inherits"], profiles)) if p.get("inherits") else {}
    for include in p.get("include", []):
        out.update({k: v for k, v in profiles[include].items() if k not in ("name", "instantiation", "from")})
    out.update(p)
    out.pop("inherits", None)
    out.pop("include", None)
    out["from"] = "system"
    return out


def first(value):
    return value[0] if isinstance(value, list) and value else value


def usable(flat: dict, machine: str) -> bool:
    return flat.get("instantiation") == "true" and machine in (flat.get("compatible_printers") or [])


def pick_process(machine: str, flats: dict[str, dict], height: str, words) -> str | None:
    found = [n for n, p in flats.items() if p.get("type") == "process" and usable(p, machine)
             and abs(float(first(p.get("layer_height", 0)) or 0) - float(height)) < 1e-6
             and "Strength" not in n]
    if not found:
        return None
    return min(found, key=lambda n: (next((i for i, w in enumerate(words) if w in n), len(words)), n))


def pick_filament(machine: str, flats: dict[str, dict], kind: str, preferred) -> str | None:
    found = [n for n, p in flats.items() if p.get("type") == "filament" and usable(p, machine)
             and str(first(p.get("filament_type", ""))).upper() == kind and "Support" not in n]

    def rank(n):
        order = next((i for i, w in enumerate(preferred) if re.match(re.escape(w) + r"(\s*@|$)", n)), None)
        return (order if order is not None else len(preferred), n)

    best = min(found, key=rank) if found else None
    return best if best and rank(best)[0] < len(preferred) else None


def bed_centre(machine: dict) -> list[float]:
    points = [tuple(float(v) for v in p.split("x")) for p in machine.get("printable_area", ["0x0", "256x256"])]
    xs, ys = [p[0] for p in points], [p[1] for p in points]
    return [(min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2]


def sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--engine", required=True, help="folder with slicer-mt.js and slicer-mt.wasm")
    parser.add_argument("--engine-name", default="OrcaSlicer 2.4.2 (OrcaWasm)")
    parser.add_argument("--engine-tag", default="wasm-v2.4.2-patch29-multithreaded",
                        help="the tag of this repository the engine files were built from")
    parser.add_argument("--profiles", required=True, help="OrcaSlicer's resources/profiles")
    parser.add_argument("--version", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    out = args.out
    if os.path.exists(out):
        shutil.rmtree(out)
    os.makedirs(os.path.join(out, "profiles"))

    with open(os.path.join(args.engine, "slicer-mt.js"), encoding="utf-8") as f:
        engine_js = f.read()
    with open(os.path.join(out, "slicer-mt.js"), "w", encoding="utf-8") as f:
        f.write(POLYFILL + engine_js)
    shutil.copyfile(os.path.join(args.engine, "slicer-mt.wasm"), os.path.join(out, "slicer-mt.wasm"))
    for name in ("index.html", "bridge.js"):
        shutil.copyfile(os.path.join(HERE, "src", name), os.path.join(out, name))
    for name in ("LICENSE", "NOTICE.md"):
        shutil.copyfile(os.path.join(ROOT, name), os.path.join(out, name))
    shutil.copyfile(os.path.join(HERE, "PROTOCOL.md"), os.path.join(out, "PROTOCOL.md"))

    profiles = load(args.profiles)
    flats = {}
    for name, p in profiles.items():
        if p.get("instantiation") == "true":
            try:
                flats[name] = flatten(name, profiles)
            except KeyError:
                continue

    catalogue = {"version": args.version, "engine": args.engine_name, "printers": {}}
    for pid, machine_name in PRINTERS.items():
        if machine_name not in profiles:
            print(f"skip {pid}: no {machine_name}")
            continue
        folder = os.path.join("profiles", pid)
        os.makedirs(os.path.join(out, folder))
        machine = flatten(machine_name, profiles)

        def write(name: str, data: dict) -> str:
            path = os.path.join(folder, name)
            with open(os.path.join(out, path), "w", encoding="utf-8") as f:
                json.dump(data, f, indent=1, sort_keys=True)
            return path.replace(os.sep, "/")

        entry = {"name": machine_name, "machine": write("machine.json", machine), "bedCentre": bed_centre(machine),
                 "processes": {}, "filaments": {}}
        for height, words in HEIGHTS.items():
            chosen = pick_process(machine_name, flats, height, words)
            if chosen:
                entry["processes"][height] = write(f"process-{height}.json", flats[chosen])
        for mid, (kind, preferred) in MATERIALS.items():
            chosen = pick_filament(machine_name, flats, kind, preferred)
            if chosen:
                entry["filaments"][mid] = write(f"filament-{mid}.json", flats[chosen])
        catalogue["printers"][pid] = entry
        print(f"{pid}: {len(entry['processes'])} processes, filaments {sorted(entry['filaments'])}")

    with open(os.path.join(out, "catalog.json"), "w", encoding="utf-8") as f:
        json.dump(catalogue, f, indent=1, sort_keys=True)

    commit = subprocess.run(["git", "-C", ROOT, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    with open(os.path.join(out, "SOURCE.md"), "w", encoding="utf-8") as f:
        f.write(
            "# Source\n\n"
            "This engine pack is free software under the GNU Affero General Public License v3.0 (LICENSE).\n\n"
            f"- Engine: {args.engine_name}, built from tag `{args.engine_tag}` of this repository\n"
            "- Complete corresponding source: https://github.com/AetherixLabs/say3d-slicer-engine"
            + (f" (commit {commit})" if commit else "") + "\n"
            "- Based on https://github.com/Hiosdra/OrcaWasm and https://github.com/SoftFever/OrcaSlicer\n")

    files = []
    for folder, _, names in os.walk(out):
        for name in sorted(names):
            path = os.path.join(folder, name)
            rel = os.path.relpath(path, out).replace(os.sep, "/")
            files.append({"path": rel, "size": os.path.getsize(path), "sha256": sha256(path)})
    files.sort(key=lambda f: f["path"])
    manifest = {"format": 1, "version": args.version, "engine": args.engine_name, "protocol": 1, "files": files}
    with open(os.path.join(out, "pack.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=1)
    print(f"pack {args.version}: {len(files)} files, {sum(f['size'] for f in files) / 1048576:.1f} MB")
    print(f"pack.json sha256 {sha256(os.path.join(out, 'pack.json'))}")


if __name__ == "__main__":
    main()
