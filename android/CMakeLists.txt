# orca-slicer-cli: OrcaSlicer's engine as one Android executable. The app runs
# it in its own process (the engine is AGPL; the app is not linked to it).
# Added to OrcaSlicer's tree by android/patch-orca.py; built by
# scripts/build-android.sh.

if(NOT DEFINED ORCA_ENGINE_BRIDGE_DIR)
  message(FATAL_ERROR "ORCA_ENGINE_BRIDGE_DIR (the repository's bridge/) is not set")
endif()

# bridge/slicer.cpp writes its scratch files under /tmp/, which Android has
# not. Build a copy that uses the working directory instead; the CLI changes
# into a scratch directory of the caller's choosing before any engine call.
set(_bridge_in  "${ORCA_ENGINE_BRIDGE_DIR}/slicer.cpp")
set(_bridge_out "${CMAKE_CURRENT_BINARY_DIR}/bridge/slicer.cpp")
file(READ "${_bridge_in}" _bridge)
string(REPLACE "\"/tmp/" "\"./" _bridge "${_bridge}")
# g_defaults is a namespace-scope FullPrintConfig. On Android the bridge's
# static constructors run before libslic3r's (ELF .init_array follows link
# input order), so it would copy option defaults that do not exist yet and
# crash at load. Construct it on first use instead.
string(REPLACE
  "static Slic3r::FullPrintConfig g_defaults;"
  "static Slic3r::FullPrintConfig& orca_android_defaults() { static Slic3r::FullPrintConfig config; return config; }\n#define g_defaults orca_android_defaults()"
  _bridge "${_bridge}")
if(NOT _bridge MATCHES "orca_android_defaults")
  message(FATAL_ERROR "bridge/slicer.cpp: g_defaults declaration not found; update android/CMakeLists.txt")
endif()
file(GENERATE OUTPUT "${_bridge_out}" CONTENT "${_bridge}")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${_bridge_in}")

add_executable(orca-slicer-cli
  "${CMAKE_CURRENT_SOURCE_DIR}/cli/main.cpp"
  "${_bridge_out}"
)

target_include_directories(orca-slicer-cli BEFORE PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/shims"
  "${ORCA_ENGINE_BRIDGE_DIR}"
  "${ORCA_SRC}"
)
# The bridge includes Format/STEP.hpp, which needs OCCT's headers.
target_include_directories(orca-slicer-cli PRIVATE "${OCCT_WASM_DIR}/include/opencascade")

# Boost.Locale was built against GNU libiconv (scripts/build-android.sh).
target_link_libraries(orca-slicer-cli PRIVATE libslic3r "${ORCA_ANDROID_PREFIX}/lib/libiconv.a")
target_link_options(orca-slicer-cli PRIVATE
  -Wl,--gc-sections
  -Wl,--icf=safe
  -Wl,-z,max-page-size=16384
)
