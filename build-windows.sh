#!/bin/bash
set -euo pipefail

# Windows FFmpeg for x86_64 and aarch64, cross-compiled on Linux with llvm-mingw.
#
#   ./build-windows.sh x86_64
#   ./build-windows.sh aarch64
#
# Both arches are built the same way: third-party deps (lame/opus/iconv/zlib) are
# built from source as STATIC libraries and linked into FFmpeg's DLLs, and
# `-static` folds the llvm-mingw C runtime in too, so the shipped DLLs import only
# OS libraries (ucrtbase, kernel32, ...) plus their sibling FFmpeg DLLs. The
# artifact is self-contained -- the consumer provisions no external runtime DLLs.
#
# This replaces the earlier split (x86_64 built natively under MSYS2, aarch64
# cross-compiled): llvm-mingw targets x86_64-w64-mingw32 and aarch64-w64-mingw32
# equally well, so one Linux-cross script covers both and Windows joins
# build-macos.sh / build-linux.sh as a normal arch-parameterized platform. No
# Windows runner, no MSYS2.
#
# The FFmpeg feature allowlist below is kept IDENTICAL to the other platform
# scripts (build-macos.sh, build-linux.sh). Any change there must change here too.

ARCH="${1:?usage: build-windows.sh <x86_64|aarch64>}"
case "$ARCH" in
    x86_64)  TRIPLE="x86_64-w64-mingw32"; MACHINE="x64"  ;;
    aarch64) TRIPLE="aarch64-w64-mingw32"; MACHINE="arm64" ;;
    *) echo "ERROR: unsupported arch '$ARCH' (expected x86_64 or aarch64)"; exit 1 ;;
esac

FFMPEG_VERSION="${FFMPEG_VERSION:-8.1.2}"

# Pinned llvm-mingw toolchain (UCRT: Windows-on-ARM ships only the UCRT, and it
# interops cleanly with the MSVC-built consumer on both arches). Runs on the
# x86_64 Linux CI runner. Bump deliberately -- this is the compiler, not a detail.
LLVM_MINGW_VERSION="${LLVM_MINGW_VERSION:-20260616}"
LLVM_MINGW_ASSET="llvm-mingw-${LLVM_MINGW_VERSION}-ucrt-ubuntu-22.04-x86_64"

ZLIB_VERSION="1.3.1"
LAME_VERSION="3.100"
OPUS_VERSION="1.5.2"
ICONV_VERSION="1.17"

echo "Building FFmpeg $FFMPEG_VERSION for Windows $ARCH (llvm-mingw $LLVM_MINGW_VERSION)"

WORKDIR="$(pwd)/build"
PREFIX="$WORKDIR/install-windows-$ARCH"   # FFmpeg install prefix (the artifact)
DEPS="$WORKDIR/deps-windows-$ARCH"        # static third-party libs live here
DIST="$(pwd)/dist"
TOOLCHAIN="$WORKDIR/$LLVM_MINGW_ASSET"

mkdir -p "$WORKDIR" "$PREFIX" "$DEPS/lib" "$DEPS/include" "$DIST"

# ---------------------------------------------------------------------------
# Toolchain
# ---------------------------------------------------------------------------
if [[ ! -x "$TOOLCHAIN/bin/${TRIPLE}-clang" ]]; then
    echo "Fetching llvm-mingw $LLVM_MINGW_VERSION..."
    curl -fL --retry 3 --retry-delay 2 --retry-all-errors \
        "https://github.com/mstorsjo/llvm-mingw/releases/download/${LLVM_MINGW_VERSION}/${LLVM_MINGW_ASSET}.tar.xz" \
        | tar xJ -C "$WORKDIR"
fi
export PATH="$TOOLCHAIN/bin:$PATH"

CC="${TRIPLE}-clang"
AR="${TRIPLE}-ar"
RANLIB="${TRIPLE}-ranlib"

for tool in "$CC" "$AR" "$RANLIB" llvm-lib; do
    command -v "$tool" >/dev/null || { echo "ERROR: $tool not on PATH"; exit 1; }
done

# x86_64 FFmpeg (and lame) carry hand-written x86 assembly that needs an external
# nasm; without it configure silently drops the SIMD paths. aarch64 uses only C
# intrinsics, so nasm is irrelevant there.
if [[ "$ARCH" == "x86_64" ]]; then
    command -v nasm >/dev/null || { echo "ERROR: nasm not on PATH (required for x86_64 asm)"; exit 1; }
fi

JOBS="$(nproc)"

# Static-dep configure defaults shared by the autotools deps below.
export CC AR RANLIB
export CFLAGS="-O2"

# -f: fail (non-zero) on HTTP >= 400 instead of saving the error page as the
# "tarball"; --retry: ride out flaky source mirrors.
CURL="curl -fL --retry 3 --retry-delay 2 --retry-all-errors"

fetch() { # url
    local url="$1" tar="${1##*/}"
    [[ -f "$WORKDIR/$tar" ]] || $CURL "$url" -o "$WORKDIR/$tar"
}

# ---------------------------------------------------------------------------
# Third-party deps -- static, so the FFmpeg DLLs carry them and consumers need
# no external runtime DLLs.
# ---------------------------------------------------------------------------

# zlib: build only the static lib and drop it + its headers into $DEPS. FFmpeg
# detects zlib by trying `-lz` directly (no pkg-config), so lib + headers is all
# it needs. (win32/Makefile.gcc is the reliable cross path; its `install` target
# is DESTDIR-awkward, so copy by hand.)
if [[ ! -f "$DEPS/lib/libz.a" ]]; then
    echo "=== zlib $ZLIB_VERSION (static) ==="
    fetch "https://github.com/madler/zlib/releases/download/v$ZLIB_VERSION/zlib-$ZLIB_VERSION.tar.gz"
    tar xzf "$WORKDIR/zlib-$ZLIB_VERSION.tar.gz" -C "$WORKDIR"
    make -C "$WORKDIR/zlib-$ZLIB_VERSION" -f win32/Makefile.gcc clean || true
    # PREFIX sets the ${TRIPLE}- tool prefix (ar/ranlib/windres); CC overrides
    # the derived ${TRIPLE}-gcc with clang. ARFLAGS defaults to `rcs` in the
    # Makefile -- don't fold it into AR or ar gets a bogus archive name.
    make -C "$WORKDIR/zlib-$ZLIB_VERSION" -f win32/Makefile.gcc -j"$JOBS" libz.a \
        PREFIX="${TRIPLE}-" CC="$CC"
    cp "$WORKDIR/zlib-$ZLIB_VERSION/libz.a" "$DEPS/lib/"
    cp "$WORKDIR/zlib-$ZLIB_VERSION/zlib.h" "$WORKDIR/zlib-$ZLIB_VERSION/zconf.h" "$DEPS/include/"
fi

# libiconv: FFmpeg links -liconv for metadata charset conversion.
if [[ ! -f "$DEPS/lib/libiconv.a" ]]; then
    echo "=== libiconv $ICONV_VERSION (static) ==="
    fetch "https://ftp.gnu.org/pub/gnu/libiconv/libiconv-$ICONV_VERSION.tar.gz"
    tar xzf "$WORKDIR/libiconv-$ICONV_VERSION.tar.gz" -C "$WORKDIR"
    ( cd "$WORKDIR/libiconv-$ICONV_VERSION" \
        && ./configure --host="$TRIPLE" --prefix="$DEPS" \
            --enable-static --disable-shared \
        && make -j"$JOBS" && make install )
fi

# libmp3lame: FFmpeg links -lmp3lame (check_lib, no pkg-config).
if [[ ! -f "$DEPS/lib/libmp3lame.a" ]]; then
    echo "=== lame $LAME_VERSION (static) ==="
    fetch "https://downloads.sourceforge.net/project/lame/lame/$LAME_VERSION/lame-$LAME_VERSION.tar.gz"
    tar xzf "$WORKDIR/lame-$LAME_VERSION.tar.gz" -C "$WORKDIR"
    ( cd "$WORKDIR/lame-$LAME_VERSION" \
        && ./configure --host="$TRIPLE" --prefix="$DEPS" \
            --enable-static --disable-shared --disable-frontend \
        && make -j"$JOBS" && make install )
fi

# libopus: FFmpeg finds it via pkg-config (opus.pc).
if [[ ! -f "$DEPS/lib/libopus.a" ]]; then
    echo "=== opus $OPUS_VERSION (static) ==="
    fetch "https://downloads.xiph.org/releases/opus/opus-$OPUS_VERSION.tar.gz"
    tar xzf "$WORKDIR/opus-$OPUS_VERSION.tar.gz" -C "$WORKDIR"
    # aarch64: NEON is baseline on Windows-on-ARM, so drop the runtime CPU probe.
    # x86_64: keep runtime detection so SSE/AVX get selected on capable hosts.
    OPUS_RTCD=()
    [[ "$ARCH" == "aarch64" ]] && OPUS_RTCD=(--disable-rtcd)
    ( cd "$WORKDIR/opus-$OPUS_VERSION" \
        && ./configure --host="$TRIPLE" --prefix="$DEPS" \
            --enable-static --disable-shared --disable-doc --disable-extra-programs \
            "${OPUS_RTCD[@]}" \
        && make -j"$JOBS" && make install )
fi

# ---------------------------------------------------------------------------
# FFmpeg
# ---------------------------------------------------------------------------
if [[ ! -d "$WORKDIR/ffmpeg-$FFMPEG_VERSION" ]]; then
    $CURL "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" | tar xJ -C "$WORKDIR"
fi
cd "$WORKDIR/ffmpeg-$FFMPEG_VERSION"
make distclean 2>/dev/null || true

# Point pkg-config exclusively at our static deps so nothing on the Linux host
# leaks in, and emit each dep's private (static) libs.
export PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig"

# Audio-only FFmpeg with minimal footprint.
# bae is an audio app -- no video codecs, filters, or devices needed.
# NOTE: allowlist below MUST stay identical to build-macos.sh / build-linux.sh.
#
# --extra-ldflags="-static": fold the llvm-mingw runtime and the static
# third-party libs into each FFmpeg DLL so the artifact imports only OS DLLs.
./configure \
    --prefix="$PREFIX" \
    --arch="$ARCH" \
    --target-os=mingw32 \
    --enable-cross-compile \
    --cross-prefix="${TRIPLE}-" \
    --cc="$CC" \
    --pkg-config=pkg-config \
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
    --extra-cflags="-O2 -I$DEPS/include" \
    --extra-ldflags="-static -L$DEPS/lib"

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

# ---------------------------------------------------------------------------
# MSVC import libraries (bin/<name>.lib)
#
# The consumer links under *-pc-windows-msvc, whose link.exe needs MSVC-format
# import libs. Cross-building on Linux there is no MSVC lib.exe, so synthesize
# them from FFmpeg's generated .def files with llvm-lib (its lib.exe-compatible
# replacement). The .def has no LIBRARY line, so prepend the real versioned DLL
# name (avcodec-62) or the import lib would point at the wrong DLL.
# ---------------------------------------------------------------------------
if ! ls "$PREFIX"/lib/*.def >/dev/null 2>&1; then
    find "$WORKDIR/ffmpeg-$FFMPEG_VERSION" -maxdepth 2 -name '*-[0-9]*.def' \
        -exec cp {} "$PREFIX/lib/" \;
fi
for def in "$PREFIX"/lib/*.def; do
    base="$(basename "$def" .def)"   # e.g. avcodec-62
    stem="${base%-*}"                # e.g. avcodec
    { printf 'LIBRARY %s.dll\n' "$base"; cat "$def"; } > "$def.named"
    llvm-lib "/def:$def.named" "/out:$PREFIX/bin/$stem.lib" "/machine:$MACHINE"
    rm -f "$def.named"
done

# ---------------------------------------------------------------------------
# Verify the shipped DLLs import only OS libraries (no bundled third-party or
# mingw runtime DLL). This is the proof that static bundling worked; keep it in
# CI output so a regression is visible.
# ---------------------------------------------------------------------------
echo "=== DLL import dependencies (expect only OS DLLs: KERNEL32, ucrtbase, ...) ==="
for dll in "$PREFIX"/bin/*.dll; do
    echo "--- $(basename "$dll") ---"
    "${TRIPLE}-objdump" -p "$dll" | grep -i 'DLL Name' || true
done

# ---------------------------------------------------------------------------
# Package -- include/, lib/ (.dll.a + .def + pkgconfig), bin/ (.dll + .lib +
# ffmpeg.exe). bae's fetch step reshapes lib/ from bin/*.lib.
# ---------------------------------------------------------------------------
cd "$PREFIX"
rm -f "$DIST/ffmpeg-windows-$ARCH.zip"
zip -r "$DIST/ffmpeg-windows-$ARCH.zip" include lib bin

echo "Built: $DIST/ffmpeg-windows-$ARCH.zip"
ls -lh "$DIST/ffmpeg-windows-$ARCH.zip"
