# Say3D engine pack protocol (version 1)

The engine pack is a folder of static files. A host app serves it, loads its page, sends a slice request and receives G-code. The host knows nothing of the engine's insides; the pack knows nothing of the host but this protocol.

## Serving

- Serve the pack folder on a **loopback origin**, such as `http://127.0.0.1:<port>/`. iOS doesn't make a custom-scheme page cross-origin isolated.
- Send with every response:
  - `Cross-Origin-Opener-Policy: same-origin`
  - `Cross-Origin-Embedder-Policy: require-corp`
  - `Cross-Origin-Resource-Policy: same-origin`

  The multithreaded engine needs `SharedArrayBuffer`.
- Serve the model to slice at a path of the host's choosing, such as `GET /input.stl`.
- Accept the G-code as the body of a `POST` to a path of the host's choosing, such as `POST /output.gcode`.
- Keep the web view **in a window**, even if it is invisible. iOS suspends the web content process of a web view that is in no window.

## Messages to the host

The page posts plain objects:
- on iOS, to `window.webkit.messageHandlers.say3d`;
- on Android, as JSON to `window.Say3DAndroid.postMessage`.

| Message | When |
|---|---|
| `{ ready: true, version, engine }` | The engine has loaded; slices can start. |
| `{ ready: false, error }` | The engine failed to load. |
| `{ progress, stage }` | During a slice: 0…1 and the engine's stage, at most every 250 ms. |
| `{ log }` | A line from the engine, for a failure report. |

## The request

`await say3dSlice(request)` — one slice at a time.

| Field | Type | |
|---|---|---|
| `input` | string | Path to `GET` the binary STL from (mm, Z up) |
| `output` | string | Path to `POST` the G-code to |
| `printer` | string | `a1`, `a1mini`, `p1s`, `p1p`, `x1`, `x1c`, `x1e` (`catalog.json`) |
| `material` | string | `pla`, `petg`, `petg-hf`, `pla-silk`, `abs`, `asa`, `tpu` |
| `plate` | string | `Cool Plate`, `Engineering Plate`, `High Temp Plate`, `Textured PEI Plate` |
| `layerHeight` | number | mm; the process nearest it is used, set to it |
| `firstLayerHeight` | number? | mm; never below `layerHeight` |
| `supports` | string | `off`, `tree` or `normal` |
| `brim` | bool? | An outer brim of 5 mm; omitted, the profile's |
| `walls` | int? | Wall loops |
| `infill` | number? | Sparse infill, 0–1 |
| `topLayers`, `bottomLayers` | int? | Shell layers |
| `wallOrder` | string? | `in-out` or `out-in` |
| `ironing` | bool? | Iron top surfaces |

The model is stood in the middle of the bed, on it. The G-code always uses relative extrusion (`M83`), as Bambu's start G-code does.

## The answer

```json
{ "bytes": 1925210, "seconds": 2019.4, "firstLayerSeconds": 405.3, "grams": 6.65,
  "millimetres": 2198.7, "size": [30, 30, 50], "bedCentre": [128, 128], "engine": "OrcaSlicer 2.4.2 (OrcaWasm)" }
```

A failure rejects the promise with the engine's message.

## pack.json

Lists every file with its `size` and `sha256`. The host takes the SHA-256 of `pack.json` from a trusted source (the Say3D dashboard), checks `pack.json` against it, then checks each file against `pack.json` before using it.
