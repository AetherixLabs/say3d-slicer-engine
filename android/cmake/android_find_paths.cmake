# Included via CMAKE_PROJECT_INCLUDE_BEFORE (after the NDK toolchain file).
# Let find_* look in deps-install as well as the NDK sysroot.
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE BOTH)

# The same headless engine as the wasm build: no OpenVDB, no OpenCV; Boost.Log
# with the single-thread ABI OrcaSlicer's own flags select.
add_compile_definitions(
    SLIC3R_WASM=1
    SLIC3R_NO_OPENVDB=1
    SLIC3R_NO_OPENCV=1
    BOOST_LOG_NO_THREADS=1
)
