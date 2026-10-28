#!/bin/bash
set -euo pipefail

# Third-party deps (lame, opus) are built from source as STATIC libs and linked
# into FFmpeg's shared libs, so the shipped .so files need only glibc, zlib and
# each other -- no libmp3lame0/libopus0 package on the consumer's machine. This
# matches build-macos.sh and build-windows.sh.

ROOT="$(cd "$(dirname "$0")" && pwd)"
ARCH="${1:-$(uname -m)}"
FFMPEG_VERSION="${FFMPEG_VERSION:-8.1.2}"

LAME_VERSION="3.100"
OPUS_VERSION="1.5.2"

echo "Building FFmpeg $FFMPEG_VERSION for Linux $ARCH"

# For cross-compilation to aarch64
if [[ "$ARCH" == "aarch64" && "$(uname -m)" != "aarch64" ]]; then
    # Run in QEMU
    docker run --rm --platform linux/arm64 \
        -v "$(pwd)":/work \
        -w /work \
        -e FFMPEG_VERSION="$FFMPEG_VERSION" \
        ubuntu:22.04 \
        bash -c "apt-get update && apt-get install -y build-essential curl xz-utils pkg-config nasm patchelf zlib1g-dev && ./build-linux.sh aarch64"
    exit 0
fi

# Install build dependencies (skip if inside Docker - already installed)
if command -v apt-get &>/dev/null && [[ ! -f /.dockerenv ]]; then
    sudo apt-get update
    sudo apt-get install -y build-essential nasm pkg-config patchelf zlib1g-dev
fi

WORKDIR="$(pwd)/build"
PREFIX="$WORKDIR/install"
DEPS="$WORKDIR/deps-linux-$ARCH"    # static third-party libs live here
DIST="$(pwd)/dist"

mkdir -p "$WORKDIR" "$PREFIX" "$DEPS/lib" "$DEPS/include" "$DIST"
cd "$WORKDIR"

# -f: fail on HTTP >= 400 instead of saving the error page as the "tarball";
# --retry: ride out flaky source mirrors.
CURL="curl -fL --retry 3 --retry-delay 2 --retry-all-errors"
JOBS="$(nproc)"

# ---------------------------------------------------------------------------
# Third-party deps -- static and position-independent, so FFmpeg's shared libs
# carry them.
# ---------------------------------------------------------------------------

# libmp3lame: FFmpeg links -lmp3lame (check_lib, no pkg-config).
if [[ ! -f "$DEPS/lib/libmp3lame.a" ]]; then
    echo "=== lame $LAME_VERSION (static) ==="
    if [[ ! -d "$WORKDIR/lame-$LAME_VERSION" ]]; then
        $CURL "https://downloads.sourceforge.net/project/lame/lame/$LAME_VERSION/lame-$LAME_VERSION.tar.gz" \
            | tar xz -C "$WORKDIR"
    fi
    ( cd "$WORKDIR/lame-$LAME_VERSION" \
        && CFLAGS="-O2 -fPIC" ./configure --prefix="$DEPS" \
            --enable-static --disable-shared --disable-frontend \
        && make -j"$JOBS" && make install )
fi

# libopus: FFmpeg finds it via pkg-config (opus.pc).
if [[ ! -f "$DEPS/lib/libopus.a" ]]; then
    echo "=== opus $OPUS_VERSION (static) ==="
    if [[ ! -d "$WORKDIR/opus-$OPUS_VERSION" ]]; then
        $CURL "https://downloads.xiph.org/releases/opus/opus-$OPUS_VERSION.tar.gz" \
            | tar xz -C "$WORKDIR"
    fi
    ( cd "$WORKDIR/opus-$OPUS_VERSION" \
        && CFLAGS="-O2" ./configure --prefix="$DEPS" --with-pic \
            --enable-static --disable-shared --disable-doc --disable-extra-programs \
        && make -j"$JOBS" && make install )
fi

# Download FFmpeg source
if [[ ! -d "ffmpeg-$FFMPEG_VERSION" ]]; then
    curl -L "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" | tar xJ
fi

cd "ffmpeg-$FFMPEG_VERSION"
make distclean 2>/dev/null || true

# Point pkg-config exclusively at the static deps so no distro .pc leaks in,
# and emit each dep's private (static) libs.
export PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig"

# Audio-only FFmpeg with minimal footprint.
# bae is an audio app -- no video codecs, filters, or devices needed.
#
# --disable-autodetect: configure otherwise links whatever the build host has
# installed (ALSA, libxcb, SDL2, liblzma, VAAPI, ...), and silently leaves out
# what it lacks: the aarch64 container had no zlib headers, so that dist alone
# built without zlib. Only what is enabled below is linked, and a missing one
# fails: threads, and zlib, which glibc systems provide. (iconv only converts
# subtitle character sets, which no enabled decoder has.)
./configure \
    --prefix="$PREFIX" \
    --pkg-config-flags=--static \
    \
    --enable-ffmpeg               `# CLI binary for generating test fixtures` \
    --disable-ffplay              `# not needed` \
    --disable-ffprobe             `# not needed` \
    --disable-doc \
    \
    --disable-swscale             `# video scaling -- audio only` \
    --disable-network             `# no streaming support needed` \
    --disable-everything          `# start from zero, enable only what we need` \
    --disable-autodetect          `# link no library the build host happens to have` \
    --enable-pthreads \
    --enable-zlib \
    \
    --enable-protocol=file \
    --enable-demuxer=mp3,flac,ape,wav,mov,ipod,ogg,aiff,wv,dsf,iff \
    --enable-decoder=mp3,mp3float,flac,ape,alac,aac,opus,vorbis,wavpack,dsd_lsbf,dsd_msbf,dsd_lsbf_planar,dsd_msbf_planar,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_f64le,pcm_alaw,pcm_mulaw,pcm_u8,pcm_s16be,pcm_s24be,pcm_s32be \
    --enable-parser=mpegaudio,flac,aac,opus,vorbis \
    --enable-encoder=flac,pcm_s16le,pcm_s24le,pcm_s32le,pcm_s16be,pcm_s24be,pcm_s32be,aac,libmp3lame,libopus  `# encoding for CD rip, track export (WAV/AIFF at every offered depth, AAC), and test fixtures` \
    --enable-muxer=flac,wav,aiff,mp3,ogg,ipod  `# ipod is the .m4a flavor of mp4, for AAC export` \
    --enable-libmp3lame \
    --enable-libopus \
    --enable-indev=lavfi                                `# virtual input device for test fixture generation` \
    --enable-filter=anoisesrc,aformat,anull,aresample,abuffer,abuffersink  `# test fixtures: generate noise as FLAC` \
    \
    --enable-shared \
    --disable-static \
    --enable-pic \
    --extra-cflags="-O2 -I$DEPS/include" \
    --extra-ldflags="-L$DEPS/lib"

make -j"$JOBS"
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

# Each library finds its siblings, and the ffmpeg binary the libraries, through
# its own runpath: glibc searches no other folder of the dist. A failed rewrite
# fails the build (the aarch64 container once lacked patchelf, and the dist
# shipped with no runpaths at all).
for so in lib/*.so*; do
    if [[ -f "$so" && ! -L "$so" ]]; then
        patchelf --set-rpath '$ORIGIN' "$so"
    fi
done

if [[ -f bin/ffmpeg ]]; then
    patchelf --set-rpath '$ORIGIN/../lib' bin/ffmpeg
fi

# The shipped libraries and ffmpeg must need only glibc, zlib and each other.
"$ROOT/verify-dist.sh" linux "$PREFIX"

tar czf "$DIST/ffmpeg-linux-$ARCH.tar.gz" bin include lib

echo "Built: $DIST/ffmpeg-linux-$ARCH.tar.gz"
ls -lh "$DIST/ffmpeg-linux-$ARCH.tar.gz"
