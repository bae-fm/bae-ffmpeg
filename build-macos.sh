#!/bin/bash
set -euo pipefail

ARCH="${1:-$(uname -m)}"
FFMPEG_VERSION="${FFMPEG_VERSION:-8.1.2}"

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
    --enable-demuxer=mp3,flac,ape,wav,mov,ipod,ogg,aiff,wv,dsf,iff \
    --enable-decoder=mp3,mp3float,flac,ape,alac,aac,opus,vorbis,wavpack,dsd_lsbf,dsd_msbf,dsd_lsbf_planar,dsd_msbf_planar,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_f64le,pcm_alaw,pcm_mulaw,pcm_u8,pcm_s16be,pcm_s24be,pcm_s32be \
    --enable-parser=mpegaudio,flac,aac,opus,vorbis \
    --enable-encoder=flac,pcm_s16le,pcm_s24le,libmp3lame,libopus  `# encoding for CD rip, track export, and test fixtures` \
    --enable-muxer=flac,wav,mp3,ogg \
    --enable-libmp3lame \
    --enable-libopus \
    --enable-indev=lavfi                               `# virtual input device for test fixture generation` \
    --enable-filter=anoisesrc,aformat,anull,aresample,abuffer,abuffersink  `# test fixtures: generate noise as FLAC` \
    \
    --enable-shared \
    --disable-static \
    --enable-pic \
    --extra-cflags="-O2 -I$(brew --prefix)/include" \
    --extra-ldflags="-L$(brew --prefix)/lib"

make -j"$(sysctl -n hw.ncpu)"
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

# Rewrite all dylib paths to @rpath so libraries are relocatable.
# FFmpeg bakes absolute build-directory paths into inter-library references;
# we replace every reference under $PREFIX/lib/ with @rpath/<name>.
rewrite_deps() {
    local target="$1"
    local deps
    deps=$(otool -L "$target" | tail -n +2 | awk '{print $1}' | grep "^$PREFIX/lib/" || true)
    for dep_path in $deps; do
        local dep_name
        dep_name=$(basename "$dep_path")
        install_name_tool -change "$dep_path" "@rpath/$dep_name" "$target"
    done
}

for dylib in lib/*.dylib; do
    if [[ -f "$dylib" && ! -L "$dylib" ]]; then
        install_name_tool -id "@rpath/$(basename "$dylib")" "$dylib"
        rewrite_deps "$dylib"
    fi
done

# Set rpath on the ffmpeg binary so it finds libs relative to itself
if [[ -f bin/ffmpeg ]]; then
    install_name_tool -add_rpath "@executable_path/../lib" bin/ffmpeg
    rewrite_deps bin/ffmpeg
fi

tar czf "$DIST/ffmpeg-macos-$ARCH.tar.gz" bin include lib

echo "Built: $DIST/ffmpeg-macos-$ARCH.tar.gz"
ls -lh "$DIST/ffmpeg-macos-$ARCH.tar.gz"
