#!/bin/bash
set -euo pipefail

FFMPEG_VERSION="${FFMPEG_VERSION:-8.1.2}"
NDK="${ANDROID_NDK_HOME:-/Users/dima/Library/Android/sdk/ndk/29.0.14206865}"
API_LEVEL=26 # matches minSdk in bae-android/app/build.gradle.kts

# NDK prebuilt toolchains are named by host: darwin-x86_64 on macOS (incl Apple
# Silicon via Rosetta), linux-x86_64 on the x86_64 Linux runner.
case "$(uname -s)" in
    Darwin) NDK_HOST_TAG="darwin-x86_64" ;;
    Linux) NDK_HOST_TAG="linux-x86_64" ;;
    *) echo "build-android.sh: unsupported host OS $(uname -s)" >&2; exit 1 ;;
esac
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/$NDK_HOST_TAG"

SRCDIR="$(pwd)/build"
DIST="$(pwd)/dist"

if [[ ! -x "$TOOLCHAIN/bin/llvm-ar" ]]; then
    echo "ERROR: NDK toolchain not found at $TOOLCHAIN"
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
    local ffmpeg_arch="$2"
    local triple="$3"
    local extra_configure="$4"

    local cc="$TOOLCHAIN/bin/${triple}${API_LEVEL}-clang"
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
    # Shared libs with UNVERSIONED sonames (libavcodec.so, not libavcodec.so.61)
    # so Android's packager + dynamic loader find them; they ship as jniLibs
    # sidecars next to libbae_bridge.so. LGPL-clean: no gpl/version3/nonfree,
    # shared (replaceable) libs.
    ./configure \
        --prefix="$prefix" \
        --arch="$ffmpeg_arch" \
        --target-os=android \
        --enable-cross-compile \
        --cc="$cc" \
        --cxx="$TOOLCHAIN/bin/${triple}${API_LEVEL}-clang++" \
        --cross-prefix="$TOOLCHAIN/bin/llvm-" \
        --nm="$TOOLCHAIN/bin/llvm-nm" \
        --ar="$TOOLCHAIN/bin/llvm-ar" \
        --ranlib="$TOOLCHAIN/bin/llvm-ranlib" \
        --strip="$TOOLCHAIN/bin/llvm-strip" \
        --sysroot="$TOOLCHAIN/sysroot" \
        \
        --disable-programs \
        --disable-doc \
        \
        --disable-swscale             `# video scaling -- audio only` \
        --disable-avdevice \
        --disable-avfilter \
        --disable-postproc \
        --disable-network             `# no streaming support needed` \
        --disable-everything          `# start from zero, enable only what we need` \
        \
        --enable-protocol=file \
        --enable-demuxer=mp3,flac,ape,wav,mov,ipod,ogg,aiff \
        --enable-decoder=mp3,mp3float,flac,ape,alac,aac,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_f64le,pcm_alaw,pcm_mulaw,pcm_u8,pcm_s16be,pcm_s24be,pcm_s32be \
        --enable-parser=mpegaudio,flac,aac \
        --enable-encoder=flac              `# standalone-FLAC for CUE byte-range tracks` \
        --enable-muxer=flac \
        --enable-swresample \
        \
        --enable-shared \
        --disable-static \
        --enable-pic \
        --extra-cflags="-O2" \
        --extra-ldflags="-Wl,-z,max-page-size=16384" \
        $extra_configure

    # Override the soname/install vars so output is libavcodec.so with SONAME
    # libavcodec.so (no version suffix) -- required for Android's loader.
    local slib_overrides=(
        SLIBNAME_WITH_VERSION='$(SLIBNAME)'
        SLIBNAME_WITH_MAJOR='$(SLIBNAME)'
        SLIB_INSTALL_NAME='$(SLIBNAME)'
        SLIB_INSTALL_LINKS=''
    )
    make -j"$(sysctl -n hw.ncpu)" "${slib_overrides[@]}"
    make install "${slib_overrides[@]}"

    # Package shared libs + headers
    cd "$prefix"
    tar czf "$DIST/ffmpeg-android-$arch.tar.gz" include lib

    echo "Built: $DIST/ffmpeg-android-$arch.tar.gz"
    ls -lh "$DIST/ffmpeg-android-$arch.tar.gz"
}

# arm64: real devices, clang/NEON (no external assembler).
build_arch aarch64 aarch64 aarch64-linux-android ""
# x86_64: emulator only -- disable x86 asm so we don't need nasm on the host.
build_arch x86_64 x86_64 x86_64-linux-android "--disable-x86asm"

echo ""
echo "All Android builds complete:"
ls -lh "$DIST"/ffmpeg-android-*.tar.gz
