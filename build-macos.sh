#!/bin/bash
set -euo pipefail

# macOS FFmpeg, one script for both arches. arm64 builds natively on an Apple
# Silicon runner, x86_64 natively on an Intel runner (macos-*-intel); pass the
# arch as $1. There is no cross-compile split like Windows has because both
# macOS arches share one toolchain (Apple clang) and one environment -- only the
# `-arch` flag differs -- so a `clang -arch $ARCH` prefix covers a same-host
# cross build too, with `--enable-cross-compile` added when host != target.
#
# Third-party deps (lame, opus) are built from source as STATIC libs and linked
# into FFmpeg's dylibs, so the shipped dylibs import only /usr/lib + /System
# frameworks + their sibling libav* -- no Homebrew. This matches the
# self-contained direction of build-windows-arm64.sh; earlier macOS builds
# linked Homebrew's lame/opus/libX11 dylibs by absolute path and were not
# relocatable off a Homebrew machine.
#
# The FFmpeg feature allowlist below is the canonical macOS/Windows set. Any
# change must stay in sync with build-windows.sh / build-windows-arm64.sh.

ARCH="${1:-$(uname -m)}"
HOST_ARCH="$(uname -m)"
FFMPEG_VERSION="${FFMPEG_VERSION:-8.1.2}"

LAME_VERSION="3.100"
OPUS_VERSION="1.5.2"

echo "Building FFmpeg $FFMPEG_VERSION for macOS $ARCH"

WORKDIR="$(pwd)/build"
PREFIX="$WORKDIR/install"           # FFmpeg install prefix (the artifact)
DEPS="$WORKDIR/deps-macos-$ARCH"    # static third-party libs live here
DIST="$(pwd)/dist"

mkdir -p "$WORKDIR" "$PREFIX" "$DEPS/lib" "$DEPS/include" "$DIST"

CC="clang -arch $ARCH"
export CC
export CFLAGS="-O2 -arch $ARCH"
export LDFLAGS="-arch $ARCH"

# Autotools can't run target binaries when the target arch differs from the
# build host, so declare a --host to force cross mode. Same-arch builds pass no
# --host and configure/run natively.
DEP_HOST=()
if [[ "$ARCH" != "$HOST_ARCH" ]]; then
    DEP_HOST=(--host="$ARCH-apple-darwin")
fi

# -f: fail on HTTP >= 400 instead of saving the error page as the "tarball";
# --retry: ride out flaky source mirrors.
CURL="curl -fL --retry 3 --retry-delay 2 --retry-all-errors"

JOBS="$(sysctl -n hw.ncpu)"

# ---------------------------------------------------------------------------
# Third-party deps -- static, so FFmpeg's dylibs carry them and the artifact
# imports no Homebrew dylib.
# ---------------------------------------------------------------------------

# libmp3lame: FFmpeg links -lmp3lame (check_lib, no pkg-config).
if [[ ! -f "$DEPS/lib/libmp3lame.a" ]]; then
    echo "=== lame $LAME_VERSION (static) ==="
    if [[ ! -d "$WORKDIR/lame-$LAME_VERSION" ]]; then
        $CURL "https://downloads.sourceforge.net/project/lame/lame/$LAME_VERSION/lame-$LAME_VERSION.tar.gz" \
            | tar xz -C "$WORKDIR"
    fi
    ( cd "$WORKDIR/lame-$LAME_VERSION" \
        && ./configure --prefix="$DEPS" ${DEP_HOST[@]+"${DEP_HOST[@]}"} \
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
        && ./configure --prefix="$DEPS" ${DEP_HOST[@]+"${DEP_HOST[@]}"} \
            --enable-static --disable-shared --disable-doc --disable-extra-programs \
        && make -j"$JOBS" && make install )
fi

# ---------------------------------------------------------------------------
# FFmpeg
# ---------------------------------------------------------------------------
cd "$WORKDIR"
if [[ ! -d "ffmpeg-$FFMPEG_VERSION" ]]; then
    $CURL "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" | tar xJ
fi
cd "ffmpeg-$FFMPEG_VERSION"
make distclean 2>/dev/null || true

# Point pkg-config exclusively at our static deps so no Homebrew .pc leaks in,
# and emit each dep's private (static) libs.
export PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig"

CROSS_FLAGS=()
if [[ "$ARCH" != "$HOST_ARCH" ]]; then
    CROSS_FLAGS=(--enable-cross-compile)
fi

# Audio-only FFmpeg with minimal footprint.
# bae is an audio app -- no video codecs, filters, or devices needed.
# NOTE: allowlist below MUST stay identical to build-windows.sh.
#
# --disable-xlib: an audio build has no business linking X11; FFmpeg otherwise
# autodetects Homebrew's libX11 and links it into every dylib.
./configure \
    --prefix="$PREFIX" \
    --arch="$ARCH" \
    --cc="$CC" \
    ${CROSS_FLAGS[@]+"${CROSS_FLAGS[@]}"} \
    --pkg-config-flags=--static \
    \
    --enable-ffmpeg               `# CLI binary for generating test fixtures` \
    --disable-ffplay              `# not needed` \
    --disable-ffprobe             `# not needed` \
    --disable-doc \
    \
    --disable-swscale             `# video scaling -- audio only` \
    --disable-network             `# no streaming support needed` \
    --disable-xlib                `# audio only -- do not link X11` \
    --disable-everything          `# start from zero, enable only what we need` \
    \
    --enable-protocol=file \
    --enable-demuxer=mp3,flac,ape,wav,mov,ipod,ogg,aiff,wv,dsf,iff \
    --enable-decoder=mp3,mp3float,flac,ape,alac,aac,opus,vorbis,wavpack,dsd_lsbf,dsd_msbf,dsd_lsbf_planar,dsd_msbf_planar,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_f64le,pcm_alaw,pcm_mulaw,pcm_u8,pcm_s16be,pcm_s24be,pcm_s32be \
    --enable-parser=mpegaudio,flac,aac,opus,vorbis \
    --enable-encoder=flac,pcm_s16le,pcm_s24le,pcm_s32le,pcm_s16be,pcm_s24be,pcm_s32be,aac,libmp3lame,libopus  `# encoding for CD rip, track export (WAV/AIFF at every offered depth, AAC), and test fixtures` \
    --enable-muxer=flac,wav,aiff,mp3,ogg,ipod  `# ipod is the .m4a flavor of mp4, for AAC export` \
    --enable-libmp3lame \
    --enable-libopus \
    --enable-indev=lavfi                               `# virtual input device for test fixture generation` \
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

# Verify the shipped dylibs import only system libraries + sibling libav*.
# This is the proof that static bundling worked; keep it in CI output so a
# regression (a Homebrew dylib creeping back in) is visible.
echo "=== dylib load commands (expect only /usr/lib, /System, @rpath siblings) ==="
leaked=0
for dylib in lib/*.dylib bin/ffmpeg; do
    [[ -f "$dylib" && ! -L "$dylib" ]] || continue
    echo "--- $dylib ---"
    otool -L "$dylib" | tail -n +2
    if otool -L "$dylib" | tail -n +2 | grep -Eq '/opt/homebrew|/usr/local/opt|/usr/local/Cellar'; then
        leaked=1
    fi
done
if [[ "$leaked" == 1 ]]; then
    echo "ERROR: a shipped binary still imports a Homebrew dylib -- not self-contained" >&2
    exit 1
fi

tar czf "$DIST/ffmpeg-macos-$ARCH.tar.gz" bin include lib

echo "Built: $DIST/ffmpeg-macos-$ARCH.tar.gz"
ls -lh "$DIST/ffmpeg-macos-$ARCH.tar.gz"
