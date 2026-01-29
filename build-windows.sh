#!/bin/bash
set -euo pipefail

FFMPEG_VERSION="${FFMPEG_VERSION:-8.0.1}"
ARCH="x86_64"

echo "Building FFmpeg $FFMPEG_VERSION for Windows $ARCH"

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
    --arch=x86_64 \
    --target-os=mingw64 \
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
    --enable-demuxer=mp3,flac,ape,wav,aiff \
    --enable-decoder=mp3,mp3float,flac,ape,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_f64le,pcm_alaw,pcm_mulaw \
    --enable-parser=mpegaudio,flac \
    --enable-encoder=flac,pcm_s16le,pcm_s24le          `# encoding for CD rip (FLAC) and WAV export` \
    --enable-muxer=flac,wav \
    --enable-indev=lavfi                                `# virtual input device for test fixture generation` \
    --enable-filter=anoisesrc,aformat,anull,abuffer,abuffersink  `# test fixtures: generate noise as FLAC` \
    \
    --enable-shared \
    --disable-static \
    --extra-cflags="-O2"

make -j"$(nproc)"
make install

# Create distribution zip
cd "$PREFIX"

# Windows uses zip format
powershell -Command "Compress-Archive -Path include,lib,bin -DestinationPath '$DIST/ffmpeg-windows-$ARCH.zip'" 2>/dev/null || \
    zip -r "$DIST/ffmpeg-windows-$ARCH.zip" include lib bin

echo "Built: $DIST/ffmpeg-windows-$ARCH.zip"
ls -lh "$DIST/ffmpeg-windows-$ARCH.zip"
