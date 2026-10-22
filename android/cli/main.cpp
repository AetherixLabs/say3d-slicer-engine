// orca-slicer-cli — OrcaSlicer's engine as a program of its own.
//
//   orca-slicer-cli <request.json | ->
//
// The request is the Say3D pack protocol's (pack/PROTOCOL.md, version 2) with
// local paths instead of URLs:
//
//   { "pack": "/data/…/pack",                 // catalog.json + profiles/
//     "printer": "a1", "material": "pla", "plate": "Textured PEI Plate",
//     "layerHeight": 0.2, "supports": "tree", …, "creator": {…},
//     "objectSettings": {…}, "ranges": [{ "bottom", "top", "settings" }],
//     "input": "/…/model.stl", "output": "/…/model.gcode",
//     "workDir": "/…/scratch",                // optional; default: output's folder
//     "stats": "/…/answer.json" }             // optional; the answer is printed too
//
// Instead of "pack" + "printer" + "material", a host may name the profiles
// itself: "machine", "process", "filament" (paths to OrcaSlicer profile JSON)
// and "bedCentre": [x, y].
//
// It does what pack/src/bridge.js does in the web view, through the same C API
// (bridge/oneslicer_api.h): the printer, process and filament profiles, the
// creator's process settings, then the request's choices; the model stood in
// the middle of the bed; a slice; the G-code to "output". stdout gets the
// protocol's answer as one JSON line; stderr gets one JSON line per progress
// step ({"progress": 0…1, "stage": "…"}) and the engine's error on failure.
// Exit status: 0 on success, 2 for a bad request, 3 for an engine failure.
//
// AGPL-3.0, as the rest of this repository.

#include "oneslicer_api.h"

#include <nlohmann/json.hpp>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <limits>
#include <mutex>
#include <regex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

#include <sys/resource.h>
#include <sys/stat.h>
#include <unistd.h>

using json = nlohmann::ordered_json;

namespace {

struct RequestError : std::runtime_error { using std::runtime_error::runtime_error; };
struct EngineError : std::runtime_error { using std::runtime_error::runtime_error; };

std::string read_file(const std::string& path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) throw RequestError("cannot read " + path + ": " + std::strerror(errno));
    std::ostringstream s;
    s << in.rdbuf();
    return s.str();
}

json read_json(const std::string& path) {
    try {
        return json::parse(read_file(path));
    } catch (const json::exception& e) {
        throw RequestError(path + ": " + e.what());
    }
}

std::string absolute(const std::string& path) {
    if (path.empty() || path[0] == '/') return path;
    char cwd[4096];
    if (!getcwd(cwd, sizeof cwd)) throw RequestError("no working directory");
    return std::string(cwd) + "/" + path;
}

std::string dirname_of(const std::string& path) {
    const auto slash = path.find_last_of('/');
    if (slash == std::string::npos) return ".";
    return slash == 0 ? "/" : path.substr(0, slash);
}

void make_dirs(const std::string& path) {
    std::string at;
    std::stringstream parts(path);
    std::string part;
    if (!path.empty() && path[0] == '/') at = "/";
    while (std::getline(parts, part, '/')) {
        if (part.empty()) continue;
        at += part + "/";
        mkdir(at.c_str(), 0700);
    }
}

// ── The pack's bridge.js, in C++ ────────────────────────────────────────────

// Profile keys that name or place a profile rather than set anything.
const std::vector<std::string> META = {"compatible_printers", "compatible_printers_condition",
    "filament_settings_id", "id", "inherits", "name", "setting_id", "from", "instantiation",
    "type", "version", "filament_id"};
bool is_meta(const std::string& k) { return std::find(META.begin(), META.end(), k) != META.end(); }

json profile(const json& p) {
    json out = json::object();
    for (auto it = p.begin(); it != p.end(); ++it)
        if (it.key() != "from" && it.key() != "instantiation" && it.key() != "inherits")
            out[it.key()] = it.value();
    return out;
}

// A filament as the engine takes it: one value for the one extruder.
json filament_slot(const json& p) {
    json out = json::object();
    for (auto it = p.begin(); it != p.end(); ++it) {
        const json& v = it.value();
        if (is_meta(it.key()) || v.is_null() || (v.is_string() && v.get<std::string>().empty())) continue;
        out[it.key()] = json::array({v.is_array() ? (v.empty() ? json() : v[0]) : v});
    }
    return out;
}

// A creator's settings the host may not hand over: where the printer,
// filament and bed come from, and what names a profile.
const std::regex NOT_PROCESS(
    "^(print_settings_id|printer_|machine_|filament_|nozzle_|curr_bed_type|default_|compatible_|inherits|from|name|"
    "version|setting_id|instantiation|print_compatible_printers|different_settings_to_system|post_process|"
    "filename_format|.*_gcode$)");

json creator_process(const json& settings, const json& proc) {
    json out = json::object();
    if (!settings.is_object()) return out;
    for (auto it = settings.begin(); it != settings.end(); ++it) {
        const json& v = it.value();
        if (!proc.contains(it.key()) || is_meta(it.key()) || std::regex_search(it.key(), NOT_PROCESS)) continue;
        if (v.is_string() || v.is_number() || v.is_boolean()) out[it.key()] = v;
    }
    return out;
}

bool is_integer(const json& v) {
    return v.is_number_integer() || (v.is_number_float() && std::floor(v.get<double>()) == v.get<double>());
}

// The request's choices over the profiles, as OrcaSlicer names its settings.
json overrides(const json& r) {
    json o = json::object();
    o["curr_bed_type"] = r.value("plate", std::string("Textured PEI Plate"));
    // Bambu's start G-code turns on M83; absolute E would over-extrude.
    o["use_relative_e_distances"] = 1;
    o["layer_height"] = r.at("layerHeight");
    if (r.contains("firstLayerHeight") && r["firstLayerHeight"].is_number() && r["firstLayerHeight"].get<double>() != 0)
        o["initial_layer_print_height"] = std::max(r["firstLayerHeight"].get<double>(), r["layerHeight"].get<double>());
    const std::string supports = r.value("supports", std::string("off"));
    if (supports == "tree") { o["enable_support"] = 1; o["support_type"] = "tree(auto)"; }
    else if (supports == "normal") { o["enable_support"] = 1; o["support_type"] = "normal(auto)"; }
    else o["enable_support"] = 0;
    if (r.contains("brim") && r["brim"].is_boolean()) {
        if (r["brim"].get<bool>()) { o["brim_type"] = "outer_only"; o["brim_width"] = 5; }
        else o["brim_type"] = "no_brim";
    }
    if (r.contains("walls") && is_integer(r["walls"]) && r["walls"].get<double>() > 0) o["wall_loops"] = r["walls"].get<int>();
    if (r.contains("infill") && r["infill"].is_number())
        o["sparse_infill_density"] = std::to_string((long)std::lround(r["infill"].get<double>() * 100)) + "%";
    if (r.contains("topLayers") && is_integer(r["topLayers"])) o["top_shell_layers"] = r["topLayers"].get<int>();
    if (r.contains("bottomLayers") && is_integer(r["bottomLayers"])) o["bottom_shell_layers"] = r["bottomLayers"].get<int>();
    const std::string wall_order = r.value("wallOrder", std::string());
    if (wall_order == "out-in") o["wall_sequence"] = "outer wall/inner wall";
    else if (wall_order == "in-out") o["wall_sequence"] = "inner wall/outer wall";
    if (r.contains("ironing") && r["ironing"].is_boolean())
        o["ironing_type"] = r["ironing"].get<bool>() ? "top" : "no ironing";
    return o;
}

// Settings of the object's own, and over heights of it, for setObjects.
json object_entry(const json& r, const json& proc) {
    json object = {{"id", "object-0"}, {"meshId", "mesh-0"}, {"extruderId", 0}};
    json own = creator_process(r.contains("objectSettings") ? r["objectSettings"] : json(), proc);
    if (!own.empty()) object["settings"] = own;
    json ranges = json::array();
    if (r.contains("ranges") && r["ranges"].is_array())
        for (const json& range : r["ranges"]) {
            if (!range.is_object() || !range.contains("top") || !range.contains("bottom")) continue;
            const double top = range["top"].get<double>(), bottom = range["bottom"].get<double>();
            if (!(top > bottom && bottom >= 0)) continue;
            ranges.push_back({{"minZ", bottom}, {"maxZ", top},
                {"settings", creator_process(range.contains("settings") ? range["settings"] : json(), proc)}});
        }
    if (!ranges.empty()) object["layerRanges"] = ranges;
    return object;
}

struct Bounds { double low[3], high[3]; };

// A binary STL's bounds, to stand it in the middle of the bed.
Bounds stl_bounds(const std::string& stl) {
    if (stl.size() < 84) throw RequestError("not a binary STL");
    uint32_t count;
    std::memcpy(&count, stl.data() + 80, 4);
    if (count == 0 || stl.size() < 84 + uint64_t(count) * 50) throw RequestError("not a binary STL");
    Bounds b;
    for (int a = 0; a < 3; ++a) { b.low[a] = std::numeric_limits<double>::infinity(); b.high[a] = -b.low[a]; }
    for (uint32_t t = 0; t < count; ++t)
        for (int v = 0; v < 3; ++v)
            for (int a = 0; a < 3; ++a) {
                float x;
                std::memcpy(&x, stl.data() + 84 + size_t(t) * 50 + 12 + v * 12 + a * 4, 4);
                b.low[a] = std::min(b.low[a], double(x));
                b.high[a] = std::max(b.high[a], double(x));
            }
    return b;
}

// The process profile nearest the layer height asked for.
std::string nearest_process(const json& processes, double height) {
    if (!processes.is_object() || processes.empty()) throw RequestError("no process profile");
    auto best = processes.begin();
    for (auto it = processes.begin(); it != processes.end(); ++it)
        if (std::fabs(std::stod(it.key()) - height) < std::fabs(std::stod(best.key()) - height)) best = it;
    return best.value().get<std::string>();
}

// ── The engine ──────────────────────────────────────────────────────────────

struct Session {
    oneslicer_session_t handle = oneslicer_session_create();
    ~Session() { if (handle) oneslicer_session_destroy(handle); }
    void check(oneslicer_status_t status, const char* what) const {
        if (status == ONESLICER_OK) return;
        const char* message = oneslicer_last_error(handle);
        throw EngineError(std::string(what) + " (" + std::to_string(status) + "): " + (message ? message : ""));
    }
    void apply(const char* format, const json& data) {
        const std::string bytes = data.dump();
        check(oneslicer_apply_profile(handle, format, uint32_t(std::strlen(format)),
                  reinterpret_cast<const uint8_t*>(bytes.data()), uint32_t(bytes.size())), "applyProfile");
    }
};

double now_seconds() {
    return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

std::mutex progress_mutex;
double progress_last = -1;

void on_progress(int32_t percent, const char* stage, void*) {
    std::lock_guard<std::mutex> lock(progress_mutex);
    const double now = now_seconds();
    if (percent < 100 && now - progress_last < 0.25) return;
    progress_last = now;
    json line = {{"progress", std::max(0, std::min(100, int(percent))) / 100.0}, {"stage", stage ? stage : ""}};
    std::fprintf(stderr, "%s\n", line.dump().c_str());
    std::fflush(stderr);
}

json json_or_null(const json& j, std::initializer_list<const char*> path) {
    const json* at = &j;
    for (const char* key : path) {
        if (!at->is_object() || !at->contains(key)) return nullptr;
        at = &(*at)[key];
    }
    return *at;
}

int run(const std::string& request_path) {
    const double started = now_seconds();
    json r;
    try {
        r = json::parse(request_path == "-" ? std::string(std::istreambuf_iterator<char>(std::cin), {}) : read_file(request_path));
    } catch (const json::exception& e) {
        throw RequestError(std::string("request: ") + e.what());
    }
    if (!r.contains("layerHeight") || !r["layerHeight"].is_number()) throw RequestError("layerHeight is required");
    const std::string input = absolute(r.value("input", std::string()));
    const std::string output = absolute(r.value("output", std::string()));
    if (input.empty() || output.empty()) throw RequestError("input and output are required");
    const std::string stats_path = absolute(r.value("stats", std::string()));

    // Profiles: from the pack's catalogue, or named by the host.
    json machine, proc, filament, bed_centre, engine_name = "OrcaSlicer 2.4.2 (orca-slicer-cli)";
    if (r.contains("pack")) {
        const std::string pack = absolute(r["pack"].get<std::string>());
        const json catalogue = read_json(pack + "/catalog.json");
        const std::string printer_id = r.value("printer", std::string());
        if (!catalogue["printers"].contains(printer_id)) throw RequestError("no profile for printer " + printer_id);
        const json& printer = catalogue["printers"][printer_id];
        const std::string material = r.value("material", std::string());
        if (!printer["filaments"].contains(material))
            throw RequestError("no profile for " + material + " on " + printer_id);
        machine = read_json(pack + "/" + printer["machine"].get<std::string>());
        proc = read_json(pack + "/" + nearest_process(printer["processes"], r["layerHeight"].get<double>()));
        filament = read_json(pack + "/" + printer["filaments"][material].get<std::string>());
        bed_centre = printer["bedCentre"];
    } else {
        machine = read_json(absolute(r.value("machine", std::string())));
        proc = read_json(absolute(r.value("process", std::string())));
        filament = read_json(absolute(r.value("filament", std::string())));
        bed_centre = r.value("bedCentre", json::array({128.0, 128.0}));
    }

    const std::string stl = read_file(input);
    const Bounds b = stl_bounds(stl);

    // The engine keeps its scratch files in the working directory.
    const std::string work = absolute(r.value("workDir", dirname_of(output)));
    make_dirs(work);
    if (chdir(work.c_str()) != 0) throw RequestError("cannot use " + work + " as the working directory");
    setenv("TMPDIR", work.c_str(), 1);

    const double bed_x = bed_centre[0].get<double>(), bed_y = bed_centre[1].get<double>();
    const json matrix = {1, 0, 0, bed_x - (b.low[0] + b.high[0]) / 2, 0, 1, 0, bed_y - (b.low[1] + b.high[1]) / 2,
                         0, 0, 1, -b.low[2], 0, 0, 0, 1};

    Session session;
    if (!session.handle) throw EngineError("the engine could not make a session");
    session.apply("orca.profile-json", profile(machine));
    session.apply("orca.profile-json", profile(proc));
    session.apply("orca.profile-json", filament_slot(filament));
    const json creator = creator_process(r.contains("creator") ? r["creator"] : json(), proc);
    if (!creator.empty()) session.apply("orca.native-json", creator);
    session.apply("orca.native-json", overrides(r));

    const json manifest = {
        {"schemaVersion", "0.7.0"},
        {"plates", json::array({{{"id", "plate-0"}, {"label", "Plate 1"}, {"index", 0}}})},
        {"meshes", json::array({{{"id", "mesh-0"}, {"format", "stl"},
                                 {"dataRange", {{"offset", 0}, {"length", stl.size()}}}}})},
        {"objects", json::array({object_entry(r, proc)})},
        {"instances", json::array({{{"id", "instance-0"}, {"objectId", "object-0"}, {"plateId", "plate-0"},
                                    {"transform", {{"matrix", matrix}}}}})},
        {"modifierVolumes", json::array()},
    };
    const std::string manifest_bytes = manifest.dump();
    session.check(oneslicer_project_set_objects(session.handle, reinterpret_cast<const uint8_t*>(stl.data()),
                      uint32_t(stl.size()), reinterpret_cast<const uint8_t*>(manifest_bytes.data()),
                      uint32_t(manifest_bytes.size())), "setObjects");
    session.check(oneslicer_set_progress_callback(session.handle, on_progress, nullptr), "progress");

    const std::string slice_request = json({{"schemaVersion", "0.7.0"}, {"plateSelection", "all"},
                                            {"includeGcode", true}, {"includeStatistics", true}}).dump();
    uint8_t* out = nullptr;
    uint32_t out_len = 0;
    const double slice_started = now_seconds();
    session.check(oneslicer_project_slice(session.handle, reinterpret_cast<const uint8_t*>(slice_request.data()),
                      uint32_t(slice_request.size()), &out, &out_len), "slice");
    const double slice_seconds = now_seconds() - slice_started;
    const json result = json::parse(std::string(reinterpret_cast<char*>(out), out_len));
    oneslicer_free(out);

    const json& plate = result.at("plateResults").at(0);
    std::string asset_id;
    for (const json& asset : plate.value("assets", json::array()))
        if (asset.value("kind", std::string()) == "gcode") asset_id = asset.value("id", std::string());
    if (asset_id.empty()) throw EngineError("no G-code came back");
    session.check(oneslicer_project_get_asset(session.handle, asset_id.c_str(), uint32_t(asset_id.size()), &out, &out_len),
                  "getAsset");
    {
        std::ofstream gcode(output, std::ios::binary | std::ios::trunc);
        gcode.write(reinterpret_cast<const char*>(out), out_len);
        if (!gcode) { oneslicer_free(out); throw EngineError("cannot write " + output); }
    }
    oneslicer_free(out);

    const json s = plate.value("statistics", json::object());
    struct rusage usage {};
    getrusage(RUSAGE_SELF, &usage);
    json answer = {
        {"bytes", out_len},
        {"seconds", json_or_null(s, {"timeSeconds", "normal"})},
        {"firstLayerSeconds", json_or_null(s, {"timeSeconds", "firstLayer"})},
        {"grams", json_or_null(s, {"filament", "totalMassG"})},
        {"millimetres", json_or_null(s, {"filament", "totalLengthMm"})},
        {"size", {b.high[0] - b.low[0], b.high[1] - b.low[1], b.high[2] - b.low[2]}},
        {"bedCentre", bed_centre},
        {"engine", engine_name},
        {"sliceSeconds", slice_seconds},
        {"totalSeconds", now_seconds() - started},
        {"peakRssKB", usage.ru_maxrss},
    };
    const std::string line = answer.dump();
    std::printf("%s\n", line.c_str());
    if (!stats_path.empty()) {
        std::ofstream stats(stats_path, std::ios::trunc);
        stats << line << "\n";
    }
    return 0;
}

} // namespace

int main(int argc, char** argv) {
    if (argc != 2) {
        std::fprintf(stderr, "usage: %s <request.json | ->\n", argv[0]);
        return 2;
    }
    try {
        return run(argv[1]);
    } catch (const RequestError& e) {
        std::fprintf(stderr, "%s\n", json({{"error", e.what()}, {"kind", "request"}}).dump().c_str());
        return 2;
    } catch (const std::exception& e) {
        std::fprintf(stderr, "%s\n", json({{"error", e.what()}, {"kind", "engine"}}).dump().c_str());
        return 3;
    }
}
