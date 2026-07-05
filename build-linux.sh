#!/bin/bash
set -euo pipefail

ARCH="${1:-$(uname -m)}"
FFMPEG_VERSION="${FFMPEG_VERSION:-8.1.2}"

echo "Building FFmpeg $FFMPEG_VERSION for Linux $ARCH"

# For cross-compilation to aarch64
if [[ "$ARCH" == "aarch64" && "$(uname -m)" != "aarch64" ]]; then
    # Run in QEMU
    docker run --rm --platform linux/arm64 \
        -v "$(pwd)":/work \
        -w /work \
        -e FFMPEG_VERSION="$FFMPEG_VERSION" \
        ubuntu:22.04 \
        bash -c "apt-get update && apt-get install -y build-essential curl xz-utils pkg-config nasm libmp3lame-dev libopus-dev && ./build-linux.sh aarch64"
    exit 0
fi

# Install build dependencies (skip if inside Docker - already installed)
if command -v apt-get &>/dev/null && [[ ! -f /.dockerenv ]]; then
    sudo apt-get update
    sudo apt-get install -y build-essential nasm pkg-config libmp3lame-dev libopus-dev
fi

WORKDIR="$(pwd)/build"
PREFIX="$WORKDIR/install"
DIST="$(pwd)/dist"

mkdir -p "$WORKDIR" "$PREFIX" "$DIST"
cd "$WORKDIR"

# Download FFmpeg source
if [[ ! -d "ffmpeg-$FFMPEG_VERSION" ]]; then
    curl -L "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" | tar xJ
fi

cd "ffmpeg-$FFMPEG_VERSION"

# Audio-only FFmpeg with minimal footprint.
# bae is an audio app -- no video codecs, filters, or devices needed.
./configure \
    --prefix="$PREFIX" \
    \
    --enable-ffmpeg               `# CLI binary for generating test fixtures` \
    --disable-ffplay              `# not needed` \
    --disable-ffprobe             `# not needed` \
    --disable-doc \
    \
    --disable-swscale             `# video scaling -- audio only` \
    --disable-network             `# no streaming support needed` \
    --disable-everything          `# start from zero, enable only what we need` \
    \
    --enable-protocol=file \
    --enable-demuxer=mp3,flac,ape,wav,mov,ipod,ogg,aiff,wv,dsf,iff \
    --enable-decoder=mp3,mp3float,flac,ape,alac,aac,opus,vorbis,wavpack,dsd_lsbf,dsd_msbf,dsd_lsbf_planar,dsd_msbf_planar,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_f64le,pcm_alaw,pcm_mulaw,pcm_u8,pcm_s16be,pcm_s24be,pcm_s32be \
    --enable-parser=mpegaudio,flac,aac,opus,vorbis \
    --enable-encoder=flac,pcm_s16le,pcm_s24le,libmp3lame,libopus  `# encoding for CD rip, track export, and test fixtures` \
    --enable-muxer=flac,wav,mp3,ogg \
    --enable-libmp3lame \
    --enable-libopus \
    --enable-indev=lavfi                                `# virtual input device for test fixture generation` \
    --enable-filter=anoisesrc,aformat,anull,aresample,abuffer,abuffersink  `# test fixtures: generate noise as FLAC` \
    \
    --enable-shared \
    --disable-static \
    --enable-pic \
    --extra-cflags="-O2"

make -j"$(nproc)"
make install

# Make pkg-config relocatable: FFmpeg bakes this build machine's absolute paths
# into prefix/libdir/includedir, so the .pc is dead on any other machine. Resolve
# prefix from each .pc file's own location (${pcfiledir}) and derive libdir/
# includedir from it, so the libs work wherever the tarball is extracted. (No
# `sed -i`: its syntax differs across BSD/GNU/MSYS2.)
for pc in "$PREFIX"/lib/pkgconfig/*.pc; do
    sed -e 's,^prefix=.*,prefix=${pcfiledir}/../..,' \
        -e 's,^libdir=.*,libdir=${prefix}/lib,' \
        -e 's,^includedir=.*,includedir=${prefix}/include,' "$pc" > "$pc.tmp" \
        && mv "$pc.tmp" "$pc"
done

# Create distribution tarball
cd "$PREFIX"

# Set RPATH for bundling
for so in lib/*.so*; do
    if [[ -f "$so" && ! -L "$so" ]]; then
        patchelf --set-rpath '$ORIGIN' "$so" 2>/dev/null || true
    fi
done

# Set RPATH on ffmpeg binary
if [[ -f bin/ffmpeg ]]; then
    patchelf --set-rpath '$ORIGIN/../lib' bin/ffmpeg 2>/dev/null || true
fi

tar czf "$DIST/ffmpeg-linux-$ARCH.tar.gz" bin include lib

echo "Built: $DIST/ffmpeg-linux-$ARCH.tar.gz"
ls -lh "$DIST/ffmpeg-linux-$ARCH.tar.gz"
