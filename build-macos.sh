#!/bin/bash
set -euo pipefail

ARCH="${1:-$(uname -m)}"
FFMPEG_VERSION="${FFMPEG_VERSION:-8.0.1}"

echo "Building FFmpeg $FFMPEG_VERSION for macOS $ARCH"

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
    --arch="$ARCH" \
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
    --enable-demuxer=mp3,flac,ape,wav,aiff,caf \
    --enable-decoder=mp3,mp3float,flac,ape,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_f64le,pcm_alaw,pcm_mulaw \
    --enable-parser=mpegaudio,flac \
    --enable-encoder=flac,pcm_s16le,pcm_s24le         `# encoding for CD rip (FLAC) and WAV export` \
    --enable-muxer=flac,wav \
    --enable-indev=lavfi                               `# virtual input device for test fixture generation` \
    --enable-filter=anoisesrc,aformat,anull,abuffer,abuffersink  `# test fixtures: generate noise as FLAC` \
    \
    --enable-shared \
    --disable-static \
    --enable-pic \
    --extra-cflags="-O2"

make -j"$(sysctl -n hw.ncpu)"
make install

# Create distribution tarball
cd "$PREFIX"

# Set install names to @rpath for bundling
for dylib in lib/*.dylib; do
    if [[ -f "$dylib" && ! -L "$dylib" ]]; then
        install_name_tool -id "@rpath/$(basename "$dylib")" "$dylib"

        # Update references to other FFmpeg libs
        for dep in lib/*.dylib; do
            if [[ -f "$dep" && ! -L "$dep" ]]; then
                dep_name=$(basename "$dep")
                otool -L "$dylib" | grep -q "$dep_name" && \
                    install_name_tool -change "$PREFIX/lib/$dep_name" "@rpath/$dep_name" "$dylib" || true
            fi
        done
    fi
done

# Set rpath on the ffmpeg binary so it finds libs relative to itself
if [[ -f bin/ffmpeg ]]; then
    install_name_tool -add_rpath "@executable_path/../lib" bin/ffmpeg
    # Update references to FFmpeg libs
    for dep in lib/*.dylib; do
        if [[ -f "$dep" && ! -L "$dep" ]]; then
            dep_name=$(basename "$dep")
            otool -L bin/ffmpeg | grep -q "$dep_name" && \
                install_name_tool -change "$PREFIX/lib/$dep_name" "@rpath/$dep_name" bin/ffmpeg || true
        fi
    done
fi

tar czf "$DIST/ffmpeg-macos-$ARCH.tar.gz" bin include lib

echo "Built: $DIST/ffmpeg-macos-$ARCH.tar.gz"
ls -lh "$DIST/ffmpeg-macos-$ARCH.tar.gz"
