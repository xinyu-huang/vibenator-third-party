#!/usr/bin/env bash
# build_chromaprint_static.sh
#
# Builds libchromaprint as a SHARED library (dylib) for the host architecture
# using the bundled KissFFT — no FFTW or Homebrew dependency required at build
# time or runtime.
#
# Shared rather than static for the same licensing reason as FFmpeg: Chromaprint
# is LGPL 2.1, and only a replaceable library file satisfies §6b without our
# having to publish Vibenator's own object files. See build_ffmpeg_static.sh's
# header for the full reasoning.
#
# Output:
#   Vibenator/ChromaprintLibs/lib/libchromaprint.dylib
#   Vibenator/ChromaprintLibs/include/chromaprint.h
#
# Prerequisites: cmake (brew install cmake if missing)
#
# Usage (run from repo root):
#   bash scripts/build_chromaprint_static.sh
#
set -euo pipefail

CHROMAPRINT_VERSION="1.5.1"
CHROMAPRINT_URL="https://github.com/acoustid/chromaprint/releases/download/v${CHROMAPRINT_VERSION}/chromaprint-${CHROMAPRINT_VERSION}.tar.gz"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
LIBS_DIR="${ROOT_DIR}/Vibenator/ChromaprintLibs"
BUILD_BASE="${TMPDIR%/}/chromaprint_vibenator"

if ! command -v cmake &>/dev/null; then
    echo "ERROR: cmake not found. Install with: brew install cmake"
    exit 1
fi

# ── Download & extract ────────────────────────────────────────────────────────

mkdir -p "${BUILD_BASE}"
TARBALL="${BUILD_BASE}/chromaprint-${CHROMAPRINT_VERSION}.tar.gz"

if [[ ! -f "${TARBALL}" ]]; then
    echo "==> Downloading chromaprint ${CHROMAPRINT_VERSION}…"
    curl -L --progress-bar "${CHROMAPRINT_URL}" -o "${TARBALL}"
fi

SRC_DIR="${BUILD_BASE}/chromaprint-${CHROMAPRINT_VERSION}"
if [[ ! -d "${SRC_DIR}" ]]; then
    echo "==> Extracting…"
    tar -xzf "${TARBALL}" -C "${BUILD_BASE}"
fi

# ── Build ─────────────────────────────────────────────────────────────────────

HOST_ARCH="$(uname -m)"
INST="${BUILD_BASE}/install_${HOST_ARCH}"
BUILD="${BUILD_BASE}/build_${HOST_ARCH}"
rm -rf "${BUILD}"   # always reconfigure cleanly
mkdir -p "${BUILD}" "${INST}"

echo "==> Configuring chromaprint ${CHROMAPRINT_VERSION} (${HOST_ARCH}, KissFFT, shared)…"
cmake -S "${SRC_DIR}" -B "${BUILD}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="${HOST_ARCH}" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="13.0" \
    -DFFTLIB=kissfft \
    -DBUILD_SHARED_LIBS=ON \
    -DBUILD_TOOLS=OFF \
    -DBUILD_TESTS=OFF \
    -DCMAKE_INSTALL_PREFIX="${INST}" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5

echo "==> Building…"
cmake --build "${BUILD}" --parallel "$(sysctl -n hw.ncpu)"
cmake --install "${BUILD}"

# ── Copy to project ───────────────────────────────────────────────────────────

OUTLIB="${LIBS_DIR}/lib"
OUTINC="${LIBS_DIR}/include"
mkdir -p "${OUTLIB}" "${OUTINC}"

# A stale archive would otherwise be linked in preference to the new dylib.
rm -f "${OUTLIB}/libchromaprint.a"

# cmake installs a versioned real file plus symlinks; ship one ordinary file, as
# Xcode's copy phases do not carry symlink trees reliably into the bundle.
REAL="$(find "${INST}/lib" -name 'libchromaprint.*.dylib' -type f | sort | tail -1)"
if [[ -z "${REAL}" ]]; then
    echo "error: no dylib produced — did BUILD_SHARED_LIBS stay OFF?" >&2
    exit 1
fi
cp "${REAL}" "${OUTLIB}/libchromaprint.dylib"
install_name_tool -id "@rpath/libchromaprint.dylib" "${OUTLIB}/libchromaprint.dylib"
codesign --force --sign - --timestamp=none "${OUTLIB}/libchromaprint.dylib" 2>/dev/null
cp "${INST}/include/chromaprint.h" "${OUTINC}/"

# Same guard the FFmpeg script carries: anything pointing outside the bundle runs
# here and fails to launch on a machine without Homebrew.
while read -r REF _; do
    case "${REF}" in
        @rpath/*|/usr/lib/*|/System/*) ;;
        *) echo "error: libchromaprint.dylib references ${REF}" >&2; exit 1 ;;
    esac
done < <(otool -L "${OUTLIB}/libchromaprint.dylib" | tail -n +2)

echo ""
echo "==> Done."
echo "    Library : ${OUTLIB}/libchromaprint.dylib  ($(du -sh "${OUTLIB}/libchromaprint.dylib" | cut -f1))"
echo "    Header  : ${OUTINC}/chromaprint.h"
