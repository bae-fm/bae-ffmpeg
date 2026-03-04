#!/bin/bash
set -euo pipefail

FFMPEG_VERSION="${FFMPEG_VERSION:-8.0.1}"
MIN_IOS="17.0"

echo "Building FFmpeg $FFMPEG_VERSION for iOS (device + simulator)"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="$SCRIPT_DIR/build"
DIST="$SCRIPT_DIR/dist"

mkdir -p "$WORKDIR" "$DIST"
cd "$WORKDIR"

# Download FFmpeg source
if [[ ! -d "ffmpeg-$FFMPEG_VERSION" ]]; then
    curl -L "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" | tar xJ
fi

# Audio-only FFmpeg with minimal footprint.
# bae is an audio app -- no video codecs, filters, or devices needed.
# iOS builds are static libraries only (no CLI binary, no test fixture support).
COMMON_FLAGS=(
    --disable-programs                # no CLI binaries on iOS
    --disable-doc

    --disable-swscale                 # video scaling -- audio only
    --disable-network                 # no streaming support needed
    --disable-everything              # start from zero, enable only what we need

    --enable-protocol=file
    --enable-demuxer=mp3,flac,ape,wav,aiff,caf
    --enable-decoder=mp3,mp3float,flac,ape,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_f64le,pcm_alaw,pcm_mulaw
    --enable-parser=mpegaudio,flac
    --enable-encoder=flac,pcm_s16le,pcm_s24le
    --enable-muxer=flac,wav

    --enable-static
    --disable-shared
    --enable-pic
    --enable-cross-compile
    --arch=arm64
    --target-os=darwin
)

build_target() {
    local sdk="$1"
    local label="$2"
    local extra_cflags="$3"

    local sysroot
    sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"

    local prefix="$WORKDIR/install-$label"
    local src="$WORKDIR/ffmpeg-$FFMPEG_VERSION"

    echo ""
    echo "=== Building for $label (sdk=$sdk) ==="
    echo ""

    # Clean previous build artifacts from the source tree.
    # FFmpeg's configure doesn't support out-of-tree builds cleanly,
    # so we clean between targets.
    cd "$src"
    if [[ -f config.mak ]]; then
        make distclean || true
    fi

    ./configure \
        --prefix="$prefix" \
        "${COMMON_FLAGS[@]}" \
        --cc="xcrun -sdk $sdk clang" \
        --sysroot="$sysroot" \
        --extra-cflags="-O2 -mios-version-min=$MIN_IOS $extra_cflags" \
        --extra-ldflags="$extra_cflags"

    make -j"$(sysctl -n hw.ncpu)"
    make install

    # Package: include + lib (static .a files only)
    cd "$prefix"
    local tarball="$DIST/ffmpeg-$label.tar.gz"
    tar czf "$tarball" include lib

    echo "Built: $tarball"
    ls -lh "$tarball"
}

# Device: standard arm64 for iphoneos
build_target iphoneos ios-arm64 ""

# Simulator: arm64 with explicit target triple to distinguish from device arm64
build_target iphonesimulator ios-sim-arm64 "-target arm64-apple-ios${MIN_IOS}-simulator"

echo ""
echo "Done. Artifacts in $DIST/"
ls -lh "$DIST"/ffmpeg-ios*.tar.gz
