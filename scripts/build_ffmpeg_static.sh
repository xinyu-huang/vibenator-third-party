#!/usr/bin/env bash
# build_ffmpeg_static.sh
#
# Builds a minimal, audio-only FFmpeg as SHARED libraries (dylibs) with zero
# external Homebrew dependencies.
#
# Shared rather than static for a licensing reason, not a technical one. FFmpeg is
# LGPL 2.1, which requires that a user be able to substitute their own build of the
# library. Statically linked, that is impossible without relinking the whole app,
# which would oblige us to hand out Vibenator's own object files (LGPL 2.1 §6a).
# As dylibs in Contents/Frameworks, the library is a replaceable file and §6b is
# satisfied without publishing any of our code. Do not switch this back to
# --enable-static without reading that section first.
#
# The dylibs are flattened to unversioned names with @rpath install names, so the
# app bundle carries libavcodec.dylib rather than a symlink chain into
# libavcodec.61.19.101.dylib — Xcode's copy phases do not preserve symlink trees
# reliably, and a dangling one fails at launch on the customer's machine, never
# here.
#
# All required transitive dependencies are macOS system libraries:
#   libbz2, libz, libiconv, pthreads, libm
#   Frameworks: AudioToolbox, CoreFoundation, CoreMedia, CoreVideo, CoreServices
#
# Output:
#   Vibenator/FFmpegLibs/lib/   libavformat.a libavcodec.a libavutil.a libswresample.a
#   Vibenator/FFmpegLibs/include/  (FFmpeg public headers)
#
# Usage (run from repo root):
#   bash scripts/build_ffmpeg_static.sh
#
set -euo pipefail

FFMPEG_VERSION="7.1"
FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.bz2"

# Must match project.yml's deploymentTarget.macOS, or object files get stamped
# with the host SDK version and the linker warns "built for newer macOS
# version than being linked" for every .o in the archive.
DEPLOYMENT_TARGET="15.0"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
LIBS_DIR="${ROOT_DIR}/Vibenator/FFmpegLibs"
BUILD_BASE="${TMPDIR%/}/ffmpeg_vibenator"

# Build only for the host architecture to avoid nasm/yasm requirements on x86_64
HOST_ARCH="$(uname -m)"
if [[ "${HOST_ARCH}" == "arm64" ]]; then
    ARCHS=(arm64)
else
    ARCHS=(x86_64)
fi

# ── Download & extract ────────────────────────────────────────────────────────

mkdir -p "${BUILD_BASE}"
TARBALL="${BUILD_BASE}/ffmpeg-${FFMPEG_VERSION}.tar.bz2"
SRC_DIR="${BUILD_BASE}/ffmpeg-${FFMPEG_VERSION}"

# Fetch only when the extracted tree is absent — an already-extracted SRC_DIR is
# enough to build from, and re-fetching just to satisfy the tarball check makes
# the script fail on machines that cannot reach ffmpeg.org.
if [[ ! -d "${SRC_DIR}" ]]; then
    if [[ ! -f "${TARBALL}" ]]; then
        echo "==> Downloading FFmpeg ${FFMPEG_VERSION}…"
        curl -L --progress-bar "${FFMPEG_URL}" -o "${TARBALL}"
    fi
    echo "==> Extracting…"
    tar -xjf "${TARBALL}" -C "${BUILD_BASE}"
fi

# ── Apply local patches ───────────────────────────────────────────────────────
# scripts/patches/*.patch are applied to the pristine FFmpeg tree before
# configure. Idempotent: re-running against an already-patched SRC_DIR is a
# no-op. A patch that no longer applies is a hard error rather than a silent
# skip — on an FFMPEG_VERSION bump, re-check whether it is still needed upstream.

PATCH_DIR="${SCRIPT_DIR}/patches"
if [[ -d "${PATCH_DIR}" ]] && compgen -G "${PATCH_DIR}/*.patch" > /dev/null; then
    for PATCH_FILE in "${PATCH_DIR}"/*.patch; do
        PATCH_NAME="$(basename "${PATCH_FILE}")"
        if patch -p1 -N --dry-run -d "${SRC_DIR}" < "${PATCH_FILE}" > /dev/null 2>&1; then
            echo "==> Applying patch ${PATCH_NAME}"
            patch -p1 -N -d "${SRC_DIR}" < "${PATCH_FILE}" > /dev/null
        elif patch -p1 -R --dry-run -d "${SRC_DIR}" < "${PATCH_FILE}" > /dev/null 2>&1; then
            echo "==> Patch ${PATCH_NAME} already applied"
        else
            echo "!! Patch ${PATCH_NAME} does not apply to FFmpeg ${FFMPEG_VERSION}" >&2
            exit 1
        fi
    done
fi

# ── Common configure flags ────────────────────────────────────────────────────
# We enable only the demuxers, decoders and parsers needed for:
#   1. Audio metadata reading (all common audio containers)
#   2. PCM decoding for Chromaprint fingerprinting

COMMON_CONFIGURE=(
    # Build type — see the header for why this is shared, not static.
    --enable-shared
    --disable-static
    # Makes each dylib's own install name "@rpath/libfoo.dylib" instead of the
    # absolute build prefix. Without it every library would record the path it
    # was built at, which resolves on this machine and on no other.
    --install-name-dir=@rpath
    --disable-debug

    # No programs or docs
    --disable-programs
    --disable-doc
    --disable-htmlpages
    --disable-manpages
    --disable-podpages
    --disable-txtpages

    # Disable unused library components
    --disable-avdevice
    --disable-avfilter
    --disable-postproc
    --disable-network

    # Start from zero then enable only what we need
    --disable-everything

    # Take nothing from the host. Without this, configure finds whatever Homebrew
    # has installed and links it: a machine with libx11 present produced dylibs
    # referencing /opt/homebrew/opt/libx11, which would run here and fail to
    # launch on any customer's Mac. The static build hid this, because a .a
    # records no dependencies — the same libraries were being found all along,
    # they just never showed up until the link became real.
    --disable-autodetect

    # Library components we do want
    --enable-avformat
    --enable-avcodec
    --enable-avutil
    --enable-swresample

    # Only local file access
    --enable-protocol=file

    # ── Audio container formats (demuxers) ────────────────────────────────
    --enable-demuxer=aac
    --enable-demuxer=aiff
    --enable-demuxer=ape
    --enable-demuxer=au
    --enable-demuxer=caf
    --enable-demuxer=iff           # DFF / DSDIFF (DSD) — iff.c reads FRM8+DSD
    --enable-demuxer=dsf           # DSF (DSD)
    --enable-demuxer=dts           # raw DTS bitstream
    --enable-demuxer=flac
    --enable-demuxer=matroska      # MKA / MKV
    --enable-demuxer=mov           # MP4 / M4A / M4B / MOV
    --enable-demuxer=mp3
    --enable-demuxer=ogg           # OGG / OGA / OPUS container
    --enable-demuxer=w64           # Wave64
    --enable-demuxer=wav
    --enable-demuxer=wavpack
    --enable-demuxer=wv
    --enable-demuxer=tta           # True Audio
    --enable-demuxer=tak
    --enable-demuxer=asf           # WMA / ASF
    --enable-demuxer=mpc           # Musepack
    --enable-demuxer=mpc8
    --enable-demuxer=ape
    --enable-demuxer=rm            # RealMedia
    --enable-demuxer=amr
    --enable-demuxer=ac3
    --enable-demuxer=eac3
    --enable-demuxer=truehd
    --enable-demuxer=mlp

    # ── Audio codecs (decoders) ───────────────────────────────────────────
    # PCM (WAV, AIFF, raw)
    --enable-decoder=pcm_s8
    --enable-decoder=pcm_u8
    --enable-decoder=pcm_s16le
    --enable-decoder=pcm_s16be
    --enable-decoder=pcm_s24le
    --enable-decoder=pcm_s24be
    --enable-decoder=pcm_s32le
    --enable-decoder=pcm_s32be
    --enable-decoder=pcm_f32le
    --enable-decoder=pcm_f32be
    --enable-decoder=pcm_f64le
    --enable-decoder=pcm_f64be
    --enable-decoder=pcm_alaw
    --enable-decoder=pcm_mulaw
    --enable-decoder=pcm_dvd
    # Compressed
    --enable-decoder=aac
    --enable-decoder=aac_latm
    --enable-decoder=alac          # Apple Lossless
    --enable-decoder=ape           # Monkey's Audio
    --enable-decoder=dca           # DTS (ff_dca_decoder)
    --enable-decoder=flac
    --enable-decoder=mp1
    --enable-decoder=mp2
    --enable-decoder=mp3
    --enable-decoder=mp1float
    --enable-decoder=mp2float
    --enable-decoder=mp3float
    --enable-decoder=opus
    --enable-decoder=vorbis
    --enable-decoder=wavpack
    --enable-decoder=tta
    --enable-decoder=tak
    --enable-decoder=wmav1
    --enable-decoder=wmav2
    --enable-decoder=wmalossless
    --enable-decoder=wmavoice
    --enable-decoder=mpc7
    --enable-decoder=mpc8
    --enable-decoder=ra_144
    --enable-decoder=ra_288
    --enable-decoder=amrnb
    --enable-decoder=amrwb
    --enable-decoder=ac3
    --enable-decoder=eac3
    --enable-decoder=truehd
    --enable-decoder=mlp
    --enable-decoder=dsd_lsbf      # DSD raw
    --enable-decoder=dsd_msbf
    --enable-decoder=dsd_lsbf_planar
    --enable-decoder=dsd_msbf_planar
    --enable-decoder=dst           # DST — lossless-compressed DSD inside DFF

    # ── Parsers ───────────────────────────────────────────────────────────
    --enable-parser=aac
    --enable-parser=aac_latm
    --enable-parser=flac
    --enable-parser=mpegaudio      # MP1/MP2/MP3
    --enable-parser=vorbis
    --enable-parser=dca            # DTS
    --enable-parser=opus
    --enable-parser=tak
    --enable-parser=ac3
    --enable-parser=mlp

    # ── Bit-stream filters needed by some demuxers ────────────────────────
    --enable-bsf=aac_adtstoasc
    --enable-bsf=mp3_header_decompress

    # Compiler
    --cc=clang
    --extra-cflags="-O2"
    --disable-stripping
    --disable-x86asm
)

# ── Build one slice per architecture ─────────────────────────────────────────

echo "==> Building FFmpeg ${FFMPEG_VERSION} (audio-only, shared)"

SLICE_LIBS=()

for ARCH in "${ARCHS[@]}"; do
    INST="${BUILD_BASE}/install_${ARCH}"
    BUILD="${BUILD_BASE}/build_${ARCH}"
    mkdir -p "${BUILD}" "${INST}"
    SLICE_LIBS+=("${INST}")

    echo ""
    echo "── ${ARCH} ──────────────────────────────────────────────"
    cd "${SRC_DIR}"
    make distclean 2>/dev/null || true

    ./configure \
        "${COMMON_CONFIGURE[@]}" \
        --prefix="${INST}" \
        --arch="${ARCH}" \
        --extra-cflags="-arch ${ARCH} -O2 -mmacosx-version-min=${DEPLOYMENT_TARGET}" \
        --extra-ldflags="-arch ${ARCH} -mmacosx-version-min=${DEPLOYMENT_TARGET}"

    make -j"$(sysctl -n hw.ncpu)"
    make install
    make distclean
done

# ── Flatten to unversioned dylibs with @rpath install names ──────────────────

echo ""
echo "==> Collecting dylibs…"

OUTLIB="${LIBS_DIR}/lib"
OUTINC="${LIBS_DIR}/include"
mkdir -p "${OUTLIB}" "${OUTINC}"

FFMPEG_LIBS=(libavutil libswresample libavcodec libavformat)

# Any previous static build's archives would otherwise sit alongside the new
# dylibs and get linked in preference to them.
rm -f "${OUTLIB}"/*.a

# `make install` leaves a versioned real file plus two symlinks. Copy the real
# file under the plain name, so what ships is one ordinary file per library.
INST="${SLICE_LIBS[0]}"
for LIB in "${FFMPEG_LIBS[@]}"; do
    REAL="$(find "${INST}/lib" -name "${LIB}.*.dylib" -type f | sort | tail -1)"
    if [[ -z "${REAL}" ]]; then
        echo "error: no dylib produced for ${LIB} — did configure fall back to static?" >&2
        exit 1
    fi
    cp "${REAL}" "${OUTLIB}/${LIB}.dylib"
done

# Rewrite each library's own id, and the references they make to each other:
# libavcodec links libavutil, and that recorded path still points into the build
# prefix. otool reads back what was actually written rather than what we assume.
for LIB in "${FFMPEG_LIBS[@]}"; do
    TARGET="${OUTLIB}/${LIB}.dylib"
    install_name_tool -id "@rpath/${LIB}.dylib" "${TARGET}"
    # Rewrite by basename, and do NOT skip references that already say @rpath:
    # --install-name-dir=@rpath makes the cross-references @rpath/libavutil.59.dylib,
    # already rooted correctly but still VERSIONED, naming a file that no longer
    # exists once we flatten. Those are the dangerous ones — they link and run
    # from the build tree and fail at launch from the bundle.
    while read -r REF _; do
        BASE="$(basename "${REF}")"
        for DEP in "${FFMPEG_LIBS[@]}"; do
            if [[ "${BASE}" == "${DEP}."* && "${REF}" != "@rpath/${DEP}.dylib" ]]; then
                install_name_tool -change "${REF}" "@rpath/${DEP}.dylib" "${TARGET}"
            fi
        done
    done < <(otool -L "${TARGET}" | tail -n +2)
    # install_name_tool invalidates the signature it just edited past; an unsigned
    # dylib is refused at load time under the hardened runtime.
    codesign --force --sign - --timestamp=none "${TARGET}" 2>/dev/null
    echo "   ${LIB}.dylib  ($(du -sh "${TARGET}" | cut -f1))"
done

# Nothing may point outside the bundle — a leftover absolute path builds and runs
# here, then fails at launch everywhere else, which is the whole failure mode this
# conversion has to avoid.
echo ""
echo "==> Verifying install names…"
BAD=0
for LIB in "${FFMPEG_LIBS[@]}"; do
    while read -r REF _; do
        case "${REF}" in
            @rpath/*)
                # An @rpath reference is only good if the file it names is one we
                # actually ship: a versioned leftover resolves to nothing at launch.
                if [[ ! -f "${OUTLIB}/$(basename "${REF}")" ]]; then
                    echo "   ✗ ${LIB}.dylib references ${REF}, which is not among the shipped dylibs"
                    BAD=1
                fi
                ;;
            /usr/lib/*|/System/*) ;;
            *) echo "   ✗ ${LIB}.dylib references ${REF}"; BAD=1 ;;
        esac
    done < <(otool -L "${OUTLIB}/${LIB}.dylib" | tail -n +2)
done
if [[ "${BAD}" -ne 0 ]]; then
    echo "error: a dylib still points outside the bundle (see above)." >&2
    exit 1
fi
echo "   all references are @rpath or system paths"

# Copy public headers from the arm64 install (architecture-independent)
FIRST_INST="${SLICE_LIBS[0]}"
cp -R "${FIRST_INST}/include/." "${OUTINC}/"

echo ""
echo "==> Done."
echo "    Libraries : ${OUTLIB}"
echo "    Headers   : ${OUTINC}"
echo ""
ls -lh "${OUTLIB}"/*.dylib
