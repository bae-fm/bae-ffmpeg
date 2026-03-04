#!/bin/bash
set -euo pipefail

FFMPEG_VERSION="${FFMPEG_VERSION:-8.0.1}"
NDK="${ANDROID_NDK_HOME:-/Users/dima/Library/Android/sdk/ndk/29.0.14206865}"
API_LEVEL=35
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/darwin-x86_64"
SYSROOT="$TOOLCHAIN/sysroot"

SRCDIR="$(pwd)/build"
DIST="$(pwd)/dist"

if [[ ! -d "$NDK" ]]; then
    echo "ERROR: NDK not found at $NDK"
    echo "Set ANDROID_NDK_HOME to your NDK installation path."
    exit 1
fi

mkdir -p "$SRCDIR" "$DIST"
cd "$SRCDIR"

# Download FFmpeg source
if [[ ! -d "ffmpeg-$FFMPEG_VERSION" ]]; then
    echo "Downloading FFmpeg $FFMPEG_VERSION..."
    curl -L "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" | tar xJ
fi

build_arch() {
    local arch="$1"
    local cc_prefix
    local ffmpeg_arch
    local extra_configure=""

    case "$arch" in
        arm64)
            cc_prefix="aarch64-linux-android${API_LEVEL}"
            ffmpeg_arch="aarch64"
            # NEON assembly works fine with NDK clang
            ;;
        x86_64)
            cc_prefix="x86_64-linux-android${API_LEVEL}"
            ffmpeg_arch="x86_64"
            # x86 assembly needs nasm/yasm which the NDK doesn't provide
            extra_configure="--disable-asm"
            ;;
        *)
            echo "Unknown arch: $arch"
            exit 1
            ;;
    esac

    local cc="$TOOLCHAIN/bin/${cc_prefix}-clang"
    local prefix="$SRCDIR/install-android-$arch"

    echo "========================================"
    echo "Building FFmpeg $FFMPEG_VERSION for Android $arch"
    echo "========================================"

    # Clean previous build artifacts (source is shared between arches)
    cd "$SRCDIR/ffmpeg-$FFMPEG_VERSION"
    make distclean 2>/dev/null || true

    # Audio-only FFmpeg with minimal footprint.
    # bae is an audio app -- no video codecs, filters, or devices needed.
    # Android build is library-only (no CLI binaries, no test fixture generation).
    ./configure \
        --prefix="$prefix" \
        --arch="$ffmpeg_arch" \
        --target-os=android \
        --enable-cross-compile \
        --cc="$cc" \
        --sysroot="$SYSROOT" \
        \
        --disable-programs \
        --disable-doc \
        \
        --disable-swscale             `# video scaling -- audio only` \
        --disable-network             `# no streaming support needed` \
        --disable-everything          `# start from zero, enable only what we need` \
        \
        --enable-protocol=file \
        --enable-demuxer=mp3,flac,ape,wav,aiff \
        --enable-decoder=mp3,mp3float,flac,ape,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_f64le,pcm_alaw,pcm_mulaw \
        --enable-parser=mpegaudio,flac \
        --enable-encoder=flac,pcm_s16le,pcm_s24le         `# encoding for CD rip (FLAC) and WAV export` \
        --enable-muxer=flac,wav \
        \
        --enable-static \
        --disable-shared \
        --enable-pic \
        --extra-cflags="-O2" \
        $extra_configure

    make -j"$(sysctl -n hw.ncpu)"
    make install

    # Package static libs + headers
    cd "$prefix"
    tar czf "$DIST/ffmpeg-android-$arch.tar.gz" include lib

    echo "Built: $DIST/ffmpeg-android-$arch.tar.gz"
    ls -lh "$DIST/ffmpeg-android-$arch.tar.gz"
}

build_arch arm64
build_arch x86_64

echo ""
echo "All Android builds complete:"
ls -lh "$DIST"/ffmpeg-android-*.tar.gz
