// Say3D slicer engine: the pack's side of PROTOCOL.md.
//
// Loads OrcaSlicer's engine (slicer-mt.js/.wasm), answers one function,
// `say3dSlice(request)`, and posts `ready`, `progress` and `log` messages to
// the host. Printer, filament and quality are chosen here from the pack's
// catalogue of OrcaSlicer's own Bambu Lab profiles; the host sends ids only.
//
// AGPL-3.0, as the rest of this repository.
(() => {
  'use strict'

  /** To the host: WKWebView's handler on iOS, the JavaScript interface on Android. */
  function post(message) {
    try {
      if (window.webkit?.messageHandlers?.say3d) window.webkit.messageHandlers.say3d.postMessage(message)
      else if (window.Say3DAndroid) window.Say3DAndroid.postMessage(JSON.stringify(message))
    } catch (_) { /* a host that stopped listening */ }
  }
  const log = (line) => post({ log: String(line).slice(0, 500) })

  const encoder = new TextEncoder()
  const json = (object) => encoder.encode(JSON.stringify(object))
  const fetchJSON = async (path) => {
    const response = await fetch(path)
    if (!response.ok) throw new Error(`${path}: ${response.status}`)
    return response.json()
  }

  // Profile keys that name or place a profile rather than set anything.
  const META = new Set(['compatible_printers', 'compatible_printers_condition', 'filament_settings_id', 'id',
    'inherits', 'name', 'setting_id', 'from', 'instantiation', 'type', 'version', 'filament_id'])
  const profile = (p) => Object.fromEntries(Object.entries(p).filter(([k]) => !['from', 'instantiation', 'inherits'].includes(k)))
  // A filament as the engine takes it: one value for the one extruder.
  const filamentSlot = (p) => Object.fromEntries(Object.entries(p)
    .filter(([k, v]) => !META.has(k) && v !== '' && v != null)
    .map(([k, v]) => [k, [Array.isArray(v) ? v[0] : v]]))

  /** The request's choices over the profiles, as OrcaSlicer names its settings. */
  function overrides(request) {
    const o = {
      curr_bed_type: request.plate || 'Textured PEI Plate',
      // Bambu's start G-code turns on M83, and the profiles leave this to a
      // default that is 0 in this build: absolute E would over-extrude ~20x.
      use_relative_e_distances: 1,
      layer_height: request.layerHeight,
    }
    if (request.firstLayerHeight) o.initial_layer_print_height = Math.max(request.firstLayerHeight, request.layerHeight)
    if (request.supports === 'tree') Object.assign(o, { enable_support: 1, support_type: 'tree(auto)' })
    else if (request.supports === 'normal') Object.assign(o, { enable_support: 1, support_type: 'normal(auto)' })
    else o.enable_support = 0
    if (request.brim === true) Object.assign(o, { brim_type: 'outer_only', brim_width: 5 })
    else if (request.brim === false) o.brim_type = 'no_brim'
    if (Number.isInteger(request.walls) && request.walls > 0) o.wall_loops = request.walls
    if (typeof request.infill === 'number') o.sparse_infill_density = `${Math.round(request.infill * 100)}%`
    if (Number.isInteger(request.topLayers)) o.top_shell_layers = request.topLayers
    if (Number.isInteger(request.bottomLayers)) o.bottom_shell_layers = request.bottomLayers
    if (request.wallOrder === 'out-in') o.wall_sequence = 'outer wall/inner wall'
    else if (request.wallOrder === 'in-out') o.wall_sequence = 'inner wall/outer wall'
    if (request.ironing === true) o.ironing_type = 'top'
    else if (request.ironing === false) o.ironing_type = 'no ironing'
    return o
  }

  /** A binary STL's bounds, to stand it in the middle of the bed. */
  function bounds(stl) {
    const view = new DataView(stl.buffer, stl.byteOffset, stl.byteLength)
    const count = view.getUint32(80, true)
    if (stl.byteLength < 84 + count * 50 || count === 0) throw new Error('not a binary STL')
    const low = [Infinity, Infinity, Infinity], high = [-Infinity, -Infinity, -Infinity]
    for (let t = 0; t < count; t++) {
      for (let v = 0; v < 3; v++) {
        const at = 84 + t * 50 + 12 + v * 12
        for (let a = 0; a < 3; a++) {
          const x = view.getFloat32(at + a * 4, true)
          if (x < low[a]) low[a] = x
          if (x > high[a]) high[a] = x
        }
      }
    }
    return { low, high }
  }

  /** The process profile nearest the layer height asked for. */
  function nearestProcess(processes, height) {
    const heights = Object.keys(processes)
    if (!heights.length) throw new Error('no process profile')
    return processes[heights.reduce((a, b) => Math.abs(b - height) < Math.abs(a - height) ? b : a)]
  }

  let engine, catalogue, busy = false

  /** Slices one STL; see PROTOCOL.md for the request and the answer. */
  async function say3dSlice(request) {
    if (!engine) throw new Error('the engine is not loaded')
    if (busy) throw new Error('another slice is under way')
    busy = true
    try {
      const printer = catalogue.printers[request.printer]
      if (!printer) throw new Error(`no profile for printer ${request.printer}`)
      const filamentPath = printer.filaments[request.material]
      if (!filamentPath) throw new Error(`no profile for ${request.material} on ${request.printer}`)
      const [machine, proc, filament, stlBytes] = await Promise.all([
        fetchJSON(printer.machine), fetchJSON(nearestProcess(printer.processes, request.layerHeight)),
        fetchJSON(filamentPath), fetch(request.input).then((r) => {
          if (!r.ok) throw new Error(`${request.input}: ${r.status}`)
          return r.arrayBuffer()
        }),
      ])
      const stl = new Uint8Array(stlBytes)
      const { low, high } = bounds(stl)
      // The middle of the bed, the model's middle over it, standing on it.
      const [bedX, bedY] = printer.bedCentre
      const matrix = [1, 0, 0, bedX - (low[0] + high[0]) / 2, 0, 1, 0, bedY - (low[1] + high[1]) / 2,
        0, 0, 1, -low[2], 0, 0, 0, 1]

      const session = await engine.createSession()
      try {
        await session.applyProfile('orca.profile-json', json(profile(machine)))
        await session.applyProfile('orca.profile-json', json(profile(proc)))
        await session.applyProfile('orca.profile-json', json(filamentSlot(filament)))
        await session.applyProfile('orca.native-json', json(overrides(request)))
        await session.setObjects(stl, {
          schemaVersion: '0.7.0',
          plates: [{ id: 'plate-0', label: 'Plate 1', index: 0 }],
          meshes: [{ id: 'mesh-0', format: 'stl', dataRange: { offset: 0, length: stl.length } }],
          objects: [{ id: 'object-0', meshId: 'mesh-0', extruderId: 0 }],
          instances: [{ id: 'instance-0', objectId: 'object-0', plateId: 'plate-0', transform: { matrix } }],
          modifierVolumes: [],
        })
        let last = 0
        const result = await session.slice(
          { schemaVersion: '0.7.0', plateSelection: 'all', includeGcode: true, includeStatistics: true },
          { onProgress: (event) => {
            const now = performance.now()
            if (now - last < 250) return
            last = now
            post({ progress: Math.max(0, Math.min(1, (event.percent ?? 0) / 100)), stage: event.stage || '' })
          } })
        const plate = result.plateResults[0]
        const asset = plate.assets.find((a) => a.kind === 'gcode')
        if (!asset) throw new Error('no G-code came back')
        const gcode = await session.getAsset(asset.id)
        // To the host as bytes, not as a string through the bridge.
        const sent = await fetch(request.output, { method: 'POST', body: gcode })
        if (!sent.ok) throw new Error(`${request.output}: ${sent.status}`)
        const s = plate.statistics || {}
        return {
          bytes: gcode.byteLength,
          seconds: s.timeSeconds?.normal ?? null,
          firstLayerSeconds: s.timeSeconds?.firstLayer ?? null,
          grams: s.filament?.totalMassG ?? null,
          millimetres: s.filament?.totalLengthMm ?? null,
          size: [high[0] - low[0], high[1] - low[1], high[2] - low[2]],
          bedCentre: printer.bedCentre,
          engine: catalogue.engine,
        }
      } finally {
        await session.dispose()
      }
    } finally {
      busy = false
    }
  }

  window.say3dSlice = say3dSlice

  ;(async () => {
    catalogue = await fetchJSON('catalog.json')
    engine = await OneSlicerEngine.createEngine({ runtime: { printErr: (line) => log(line) } })
    post({ ready: true, version: catalogue.version, engine: catalogue.engine })
  })().catch((error) => {
    log(error?.stack || error)
    post({ ready: false, error: String(error?.message || error) })
  })
})()
