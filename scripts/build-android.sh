#!/usr/bin/env bash
# Native Android build of the OrcaSlicer engine: orca-slicer-cli, one static
# arm64-v8a executable the app runs in its own process (AGPL engine, separate
# program). Mirrors .github/workflows/build-wasm.yml: same OrcaSlicer tag,
# same dependency versions, same stubs for desktop-only libraries (GUI,
# OpenGL, OpenCV, OpenVDB, curl, OpenSSL, FreeType, draco) and the same
# patches/apply.py. OCCT is kept, as the wasm build keeps it.
#
#   ANDROID_NDK=~/Library/Android/sdk/ndk/28.2.13676358 ./scripts/build-android.sh [deps|engine|all]
#
# Everything lands in build-android/: dl/ (sources), deps-install/ (static
# deps), engine/ (the CMake tree) and out/orca-slicer-cli (stripped).
# Each dependency has a stamp file, so a re-run only builds what is missing.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STEP="${1:-all}"
ORCA_VERSION="${ORCA_VERSION:-v2.4.2}"
ANDROID_NDK="${ANDROID_NDK:-$HOME/Library/Android/sdk/ndk/28.2.13676358}"
API="${ANDROID_API:-26}"
ABI="arm64-v8a"
TRIPLE="aarch64-linux-android"
JOBS="${JOBS:-$( (nproc 2>/dev/null || sysctl -n hw.ncpu) )}"

BUILD="${ROOT}/build-android"
DL="${BUILD}/dl"
SRC="${BUILD}/src"
PREFIX="${BUILD}/deps-install"
OUT="${BUILD}/out"
mkdir -p "${DL}" "${SRC}" "${PREFIX}" "${OUT}"

# CMake and Ninja: the host's, else the Android SDK's (3.22.1 is enough).
if ! command -v cmake >/dev/null || ! command -v ninja >/dev/null; then
  SDK_CMAKE="$(ls -d "${ANDROID_NDK}"/../../cmake/*/bin 2>/dev/null | sort -V | tail -1)"
  [[ -n "${SDK_CMAKE}" ]] || { echo "need cmake + ninja" >&2; exit 1; }
  export PATH="${SDK_CMAKE}:${PATH}"
fi

case "$(uname -s)" in
  Darwin) HOST_TAG=darwin-x86_64 ;;
  Linux)  HOST_TAG=linux-x86_64 ;;
  *) echo "unsupported host" >&2; exit 1 ;;
esac
TC="${ANDROID_NDK}/toolchains/llvm/prebuilt/${HOST_TAG}"
SYSROOT="${TC}/sysroot"
TOOLCHAIN_FILE="${ANDROID_NDK}/build/cmake/android.toolchain.cmake"
export CC="${TC}/bin/${TRIPLE}${API}-clang"
export CXX="${TC}/bin/${TRIPLE}${API}-clang++"
export AR="${TC}/bin/llvm-ar"
export RANLIB="${TC}/bin/llvm-ranlib"
export STRIP="${TC}/bin/llvm-strip"
export NM="${TC}/bin/llvm-nm"

COMMON_FLAGS="-O2 -fPIC -ffunction-sections -fdata-sections"

ndk_cmake() { # ndk_cmake <src> <build> [args…]
  local src="$1" bld="$2"; shift 2
  cmake -S "${src}" -B "${bld}" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="${TOOLCHAIN_FILE}" \
    -DANDROID_ABI="${ABI}" -DANDROID_PLATFORM="android-${API}" -DANDROID_STL=c++_static \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
    -DCMAKE_PREFIX_PATH="${PREFIX}" \
    -DCMAKE_FIND_ROOT_PATH="${PREFIX}" \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    "-DCMAKE_C_FLAGS=-ffunction-sections -fdata-sections" \
    "-DCMAKE_CXX_FLAGS=-ffunction-sections -fdata-sections" \
    "$@"
}

# Header-only installs: the host's compiler, not the NDK's.
host_cmake() { env -u CC -u CXX -u AR -u RANLIB cmake "$@"; }

fetch() { # fetch <url> <dir-name-after-extract>
  local url="$1" name="$2" file="${DL}/$(basename "$1")"
  [[ -d "${SRC}/${name}" ]] && return 0
  if [[ ! -f "${file}" ]]; then
    curl -fsSL --retry 3 -o "${file}.part" "${url}" && mv "${file}.part" "${file}"
  fi
  case "${file}" in
    *.tar.xz) tar xJf "${file}" -C "${SRC}" ;;
    *) tar xzf "${file}" -C "${SRC}" ;;
  esac
}

stamp() { [[ -f "${PREFIX}/.$1" ]]; }
mark() { touch "${PREFIX}/.$1"; echo "[android] $1 done"; }

build_iconv() {
  # Boost.Locale needs iconv or ICU; bionic has iconv only from API 28.
  stamp libiconv_1.17_v1 && return 0
  fetch "https://ftp.gnu.org/gnu/libiconv/libiconv-1.17.tar.gz" libiconv-1.17
  cd "${SRC}/libiconv-1.17"
  CFLAGS="${COMMON_FLAGS}" ./configure --host="${TRIPLE}" --prefix="${PREFIX}" \
    --disable-shared --enable-static --disable-nls
  make -j"${JOBS}" && make install
  mark libiconv_1.17_v1
}

build_boost() {
  build_iconv
  stamp boost_1.83.0_v2 && return 0
  # GitHub's release tarball: the same sources, a third of the size.
  fetch "https://github.com/boostorg/boost/releases/download/boost-1.83.0/boost-1.83.0.tar.xz" boost-1.83.0
  cd "${SRC}/boost-1.83.0"
  [[ -x ./b2 ]] || ./bootstrap.sh
  cat > "${BUILD}/boost-user-config.jam" <<EOF
using clang : android : ${CXX} :
  <archiver>${AR}
  <ranlib>${RANLIB}
  <compileflags>"${COMMON_FLAGS}"
  ;
EOF
  # Boost.Log: BOOST_LOG_NO_THREADS matches libslic3r's own flags (the same
  # ABI the wasm build uses). Boost.Locale: GNU libiconv (above), no ICU.
  ./b2 --user-config="${BUILD}/boost-user-config.jam" \
    toolset=clang-android target-os=android architecture=arm address-model=64 \
    binary-format=elf abi=aapcs \
    variant=release link=static threading=multi runtime-link=static \
    --layout=system --prefix="${PREFIX}" \
    --with-atomic --with-chrono --with-date_time --with-filesystem \
    --with-iostreams --with-locale --with-log --with-nowide \
    --with-program_options --with-regex --with-system --with-thread \
    boost.locale.icu=off boost.locale.iconv=on boost.locale.posix=off -sICONV_PATH="${PREFIX}" \
    -sNO_BZIP2=1 -sNO_LZMA=1 -sNO_ZSTD=1 \
    define=BOOST_LOG_WITHOUT_SYSLOG=1 define=BOOST_LOG_NO_THREADS=1 \
    -j"${JOBS}" install
  mark boost_1.83.0_v2
}

build_math() {
  stamp math_gmp6.3.0_mpfr4.2.1_cgal5.6.2_v1 && return 0
  fetch "https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz" gmp-6.3.0
  cd "${SRC}/gmp-6.3.0"
  CFLAGS="${COMMON_FLAGS}" CXXFLAGS="${COMMON_FLAGS}" ./configure \
    --host="${TRIPLE}" --prefix="${PREFIX}" \
    --disable-shared --enable-static --enable-cxx --disable-assembly
  make -j"${JOBS}" && make install
  fetch "https://ftp.gnu.org/gnu/mpfr/mpfr-4.2.1.tar.xz" mpfr-4.2.1
  cd "${SRC}/mpfr-4.2.1"
  CFLAGS="${COMMON_FLAGS}" ./configure \
    --host="${TRIPLE}" --prefix="${PREFIX}" --with-gmp="${PREFIX}" \
    --disable-shared --enable-static
  make -j"${JOBS}" && make install
  fetch "https://github.com/CGAL/cgal/releases/download/v5.6.2/CGAL-5.6.2.tar.xz" CGAL-5.6.2
  host_cmake -S "${SRC}/CGAL-5.6.2" -B "${BUILD}/b/cgal" -G Ninja \
    -DCMAKE_INSTALL_PREFIX="${PREFIX}" -DCMAKE_BUILD_TYPE=Release
  cmake --build "${BUILD}/b/cgal" --target install
  mark math_gmp6.3.0_mpfr4.2.1_cgal5.6.2_v1
}

build_headers() {
  stamp headers_eigen5.0.1_nlohmann3.11.3_expat2.5.0_nlopt2.7.1_cereal1.3.2_v1 && return 0
  fetch "https://gitlab.com/libeigen/eigen/-/archive/5.0.1/eigen-5.0.1.tar.gz" eigen-5.0.1
  host_cmake -S "${SRC}/eigen-5.0.1" -B "${BUILD}/b/eigen" -G Ninja \
    -DCMAKE_INSTALL_PREFIX="${PREFIX}" -DBUILD_TESTING=OFF -DEIGEN_BUILD_DOC=OFF
  cmake --build "${BUILD}/b/eigen" --target install
  [[ -d "${SRC}/nlohmann" ]] || git clone --depth 1 --branch v3.11.3 https://github.com/nlohmann/json.git "${SRC}/nlohmann"
  host_cmake -S "${SRC}/nlohmann" -B "${BUILD}/b/nlohmann" -G Ninja \
    -DCMAKE_INSTALL_PREFIX="${PREFIX}" -DJSON_BuildTests=OFF -DJSON_Install=ON
  cmake --build "${BUILD}/b/nlohmann" --target install
  [[ -d "${SRC}/cereal" ]] || git clone --depth 1 --branch v1.3.2 https://github.com/USCiLab/cereal.git "${SRC}/cereal"
  host_cmake -S "${SRC}/cereal" -B "${BUILD}/b/cereal" -G Ninja \
    -DCMAKE_INSTALL_PREFIX="${PREFIX}" -DJUST_INSTALL_CEREAL=ON \
    -DSKIP_PERFORMANCE_COMPARISON=ON -DBUILD_SANDBOX=OFF -DBUILD_DOC=OFF
  cmake --build "${BUILD}/b/cereal" --target install
  fetch "https://github.com/libexpat/libexpat/releases/download/R_2_5_0/expat-2.5.0.tar.xz" expat-2.5.0
  ndk_cmake "${SRC}/expat-2.5.0" "${BUILD}/b/expat" \
    -DEXPAT_BUILD_TOOLS=OFF -DEXPAT_BUILD_EXAMPLES=OFF -DEXPAT_BUILD_TESTS=OFF -DEXPAT_SHARED_LIBS=OFF
  cmake --build "${BUILD}/b/expat" --target install
  fetch "https://github.com/stevengj/nlopt/archive/v2.7.1.tar.gz" nlopt-2.7.1
  ndk_cmake "${SRC}/nlopt-2.7.1" "${BUILD}/b/nlopt" \
    -DNLOPT_CXX=ON -DNLOPT_PYTHON=OFF -DNLOPT_GUILE=OFF -DNLOPT_MATLAB=OFF \
    -DNLOPT_OCTAVE=OFF -DNLOPT_SWIG=OFF -DNLOPT_TESTS=OFF
  cmake --build "${BUILD}/b/nlopt" --target install
  mark headers_eigen5.0.1_nlohmann3.11.3_expat2.5.0_nlopt2.7.1_cereal1.3.2_v1
}

build_images() {
  stamp images_png1.6.43_jpegturbo3.0.4_v1 && return 0
  # zlib comes from the NDK sysroot (libz.a).
  fetch "https://download.sourceforge.net/libpng/libpng-1.6.43.tar.xz" libpng-1.6.43
  ndk_cmake "${SRC}/libpng-1.6.43" "${BUILD}/b/png" \
    -DPNG_SHARED=OFF -DPNG_STATIC=ON -DPNG_TESTS=OFF -DPNG_TOOLS=OFF -DPNG_EXECUTABLES=OFF \
    -DPNG_ARM_NEON=on
  cmake --build "${BUILD}/b/png" --target install
  fetch "https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/3.0.4/libjpeg-turbo-3.0.4.tar.gz" libjpeg-turbo-3.0.4
  ndk_cmake "${SRC}/libjpeg-turbo-3.0.4" "${BUILD}/b/jpeg" \
    -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DWITH_TURBOJPEG=OFF -DWITH_JAVA=OFF
  cmake --build "${BUILD}/b/jpeg" --target install
  mark images_png1.6.43_jpegturbo3.0.4_v1
}

build_libnoise() {
  stamp libnoise_1.0_v1 && return 0
  fetch "https://github.com/SoftFever/Orca-deps-libnoise/archive/refs/tags/1.0.tar.gz" Orca-deps-libnoise-1.0
  ndk_cmake "${SRC}/Orca-deps-libnoise-1.0" "${BUILD}/b/libnoise"
  cmake --build "${BUILD}/b/libnoise" --target install
  mark libnoise_1.0_v1
}

build_tbb() {
  stamp onetbb_v2021.13.2_v1 && return 0
  [[ -d "${SRC}/onetbb" ]] || git clone --depth 1 --branch v2021.13.2 https://github.com/uxlfoundation/oneTBB.git "${SRC}/onetbb"
  ndk_cmake "${SRC}/onetbb" "${BUILD}/b/onetbb" \
    -DTBB_TEST=OFF -DTBB_EXAMPLES=OFF -DTBB_STRICT=OFF -DTBB_DISABLE_HWLOC_AUTOMATIC_SEARCH=ON
  cmake --build "${BUILD}/b/onetbb" --target install
  mark onetbb_v2021.13.2_v1
}

build_occt() {
  stamp occt_7.8.1_v1 && return 0
  fetch "https://github.com/Open-Cascade-SAS/OCCT/archive/refs/tags/V7_8_1.tar.gz" OCCT-7_8_1
  local s="${SRC}/OCCT-7_8_1"
  # The same module subset as the wasm build. (OCCT's native flags define
  # OCC_CONVERT_SIGNALS; it only acts if OSD::SetSignal is called, which the
  # engine never does.)
  python3 - "$s" <<'PYEOF'
import pathlib, sys
p = pathlib.Path(sys.argv[1]) / 'CMakeLists.txt'
t = p.read_text()
anchor = 'set (BUILD_TOOLKITS ${RAW_BUILD_TOOLKITS})'
if 'REMOVE_ITEM BUILD_TOOLKITS ExpToCasExe' not in t:
    assert anchor in t
    p.write_text(t.replace(anchor, anchor + '\nlist (REMOVE_ITEM BUILD_TOOLKITS ExpToCasExe)', 1))
PYEOF
  ndk_cmake "$s" "${BUILD}/b/occt" \
    -DBUILD_LIBRARY_TYPE=Static \
    -DBUILD_MODULE_Draw=OFF -DBUILD_MODULE_Visualization=OFF \
    -DBUILD_MODULE_FoundationClasses=ON -DBUILD_MODULE_ModelingData=ON \
    -DBUILD_MODULE_ModelingAlgorithms=ON -DBUILD_MODULE_DataExchange=ON \
    -DBUILD_MODULE_ApplicationFramework=ON \
    -DUSE_FREETYPE=OFF -DUSE_OPENGL=OFF -DUSE_GLES2=OFF -DUSE_OPENGL2=OFF \
    -DUSE_TCL=OFF -DUSE_TK=OFF -DUSE_FFMPEG=OFF -DUSE_FREEIMAGE=OFF \
    -DUSE_RAPIDJSON=OFF -DUSE_DRACO=OFF -DUSE_VTK=OFF -DUSE_TBB=OFF \
    -DUSE_XLIB=OFF -DBUILD_DOC_Overview=OFF -DBUILD_SAMPLES_QT=OFF \
    -DINSTALL_DIR_LAYOUT=Unix
  cmake --build "${BUILD}/b/occt" -j"${JOBS}"
  cmake --install "${BUILD}/b/occt"
  mark occt_7.8.1_v1
}

build_deps() {
  build_boost
  build_math
  build_headers
  build_images
  build_libnoise
  build_tbb
  build_occt
}

build_engine() {
  if [[ ! -d "${ROOT}/orca/src/libslic3r" ]]; then
    git clone --depth 1 --branch "${ORCA_VERSION}" https://github.com/SoftFever/OrcaSlicer.git "${ROOT}/orca"
  fi
  python3 "${ROOT}/patches/apply.py"
  python3 "${ROOT}/android/patch-orca.py"
  ndk_cmake "${ROOT}/orca" "${BUILD}/engine" \
    -DCMAKE_MODULE_PATH="${ROOT}/android/cmake;${ROOT}/cmake" \
    -DCMAKE_PROJECT_INCLUDE_BEFORE="${ROOT}/android/cmake/android_find_paths.cmake" \
    -DSLIC3R_WASM=ON -DSLIC3R_GUI=OFF -DSLIC3R_STATIC=ON -DSLIC3R_PCH=OFF \
    -DSLIC3R_OPENCASCADE=ON -DOCCT_WASM_DIR="${PREFIX}" -DSLIC3R_OPENGL_IMGUI=OFF \
    -DBUILD_TESTS=OFF -DORCA_TOOLS=OFF \
    -DORCA_WEB_OVERRIDES_DIR="${ROOT}/overrides" \
    -DORCA_ANDROID_DIR="${ROOT}/android" -DORCA_ANDROID_PREFIX="${PREFIX}" \
    -DORCA_ENGINE_BRIDGE_DIR="${ROOT}/bridge" \
    -DBoost_NO_SYSTEM_PATHS=ON -DBoost_NO_BOOST_CMAKE=ON \
    -DBOOST_ROOT="${PREFIX}" -DBoost_ROOT="${PREFIX}" \
    -DCGAL_DIR="${PREFIX}/lib/cmake/CGAL" \
    -DNLOPT_LIBRARY="${PREFIX}/lib/libnlopt.a" -DNLOPT_INCLUDE_DIR="${PREFIX}/include" \
    -DGMP_INCLUDE_DIR="${PREFIX}/include" -DGMP_LIBRARIES="${PREFIX}/lib/libgmp.a" \
    -DMPFR_INCLUDE_DIR="${PREFIX}/include" -DMPFR_LIBRARIES="${PREFIX}/lib/libmpfr.a" \
    "-DCMAKE_CXX_FLAGS=-include ${ROOT}/android/shims/android_prelude.hpp -I${ROOT}/wasm/shims-common -ffunction-sections -fdata-sections -DSLIC3R_NO_OPENVDB=1 -DSLIC3R_NO_OPENCV=1" \
    "-DCMAKE_C_FLAGS=-I${ROOT}/wasm/shims-common -ffunction-sections -fdata-sections"
  cmake --build "${BUILD}/engine" --target orca-slicer-cli -j"${JOBS}"
  local bin="${BUILD}/engine/android/orca-slicer-cli"
  "${STRIP}" --strip-all -o "${OUT}/orca-slicer-cli" "${bin}"
  ls -l "${OUT}/orca-slicer-cli"
}

case "${STEP}" in
  deps) build_deps ;;
  engine) build_engine ;;
  all) build_deps; build_engine ;;
  only) shift; for d in "$@"; do "build_${d}"; done ;;  # e.g. only occt tbb
  *) echo "usage: $0 [deps|engine|all|only <dep>…]" >&2; exit 2 ;;
esac
