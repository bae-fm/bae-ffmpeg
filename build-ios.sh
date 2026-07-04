#!/bin/bash
set -euo pipefail

FFMPEG_VERSION="${FFMPEG_VERSION:-8.1.2}"
# 16.0 is bae's iOS deployment floor: the app links these static libs directly,
# so their minos must be <= the app target. A higher floor here makes the app
# linker reach for runtime symbols the SDK only vends for the negotiated minimum.
MIN_IOS="16.0"

echo "Building FFmpeg $FFMPEG_VERSION for iOS (device + simulator)"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="$SCRIPT_DIR/build"
DIST="$SCRIPT_DIR/dist"

mkdir -p "$WORKDIR" "$DIST"
cd "$WORKDIR"

# Download the FFmpeg source tarball. Kept as the immutable archive; each target
# extracts its own pristine copy from it (below), so no build state can leak
# between the device and simulator builds.
SRC_TARBALL="$WORKDIR/ffmpeg-$FFMPEG_VERSION.tar.xz"
if [[ ! -f "$SRC_TARBALL" ]]; then
    curl -L "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" -o "$SRC_TARBALL"
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
    --enable-demuxer=mp3,flac,ape,wav,mov,ipod,ogg,aiff,wv,dsf,iff
    --enable-decoder=mp3,mp3float,flac,ape,alac,aac,opus,vorbis,wavpack,dsd_lsbf,dsd_msbf,dsd_lsbf_planar,dsd_msbf_planar,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_f64le,pcm_alaw,pcm_mulaw,pcm_u8,pcm_s16be,pcm_s24be,pcm_s32be
    --enable-parser=mpegaudio,flac,aac,opus,vorbis
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
    # A pristine source per target, extracted fresh from the immutable tarball.
    # Device and simulator build in the same in-tree layout (FFmpeg's configure
    # has no clean out-of-tree build), and `make distclean` leaves some generated
    # objects behind (e.g. alac_data.o), so a shared or copied-from-built tree
    # would link stale objects into the wrong archive -- a mixed .a the app linker
    # rejects ("built for 'iOS'"). Extracting per target guarantees no build state
    # leaks between device and simulator.
    local src="$WORKDIR/ffmpeg-$FFMPEG_VERSION-$label"
    rm -rf "$src"
    mkdir -p "$src"
    tar xJf "$SRC_TARBALL" -C "$src" --strip-components=1

    echo ""
    echo "=== Building for $label (sdk=$sdk) ==="
    echo ""

    cd "$src"

    ./configure \
        --prefix="$prefix" \
        "${COMMON_FLAGS[@]}" \
        --cc="xcrun -sdk $sdk clang" \
        --sysroot="$sysroot" \
        --extra-cflags="-O2 -mios-version-min=$MIN_IOS $extra_cflags" \
        --extra-ldflags="$extra_cflags"

    make -j"$(sysctl -n hw.ncpu)"
    make install

    # Make pkg-config relocatable: FFmpeg bakes this build machine's absolute
    # paths into prefix/libdir/includedir. Resolve prefix from each .pc file's
    # own location (${pcfiledir}) and derive libdir/includedir from it, so the
    # libs work wherever the tarball is extracted. (No `sed -i`: BSD/GNU/MSYS2
    # differ.)
    for pc in "$prefix"/lib/pkgconfig/*.pc; do
        sed -e 's,^prefix=.*,prefix=${pcfiledir}/../..,' \
            -e 's,^libdir=.*,libdir=${prefix}/lib,' \
            -e 's,^includedir=.*,includedir=${prefix}/include,' "$pc" > "$pc.tmp" \
            && mv "$pc.tmp" "$pc"
    done

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
