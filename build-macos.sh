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

# Configure for audio-only with minimal footprint
./configure \
    --prefix="$PREFIX" \
    --arch="$ARCH" \
    --disable-programs \
    --disable-doc \
    --disable-swscale \
        --disable-avfilter \
    --disable-avdevice \
    --disable-network \
    --disable-everything \
    --enable-protocol=file \
    --enable-demuxer=mp3,flac,ape,wav,aiff,caf \
    --enable-decoder=mp3,mp3float,flac,ape,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_alaw,pcm_mulaw \
    --enable-parser=mpegaudio,flac \
    --enable-encoder=flac,pcm_s16le,pcm_s24le \
    --enable-muxer=flac,wav \
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

tar czf "$DIST/ffmpeg-macos-$ARCH.tar.gz" include lib

echo "Built: $DIST/ffmpeg-macos-$ARCH.tar.gz"
ls -lh "$DIST/ffmpeg-macos-$ARCH.tar.gz"
