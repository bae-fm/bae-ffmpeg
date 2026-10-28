#!/bin/bash
set -euo pipefail

# Fail unless every shared library and program in an FFmpeg install prefix
# loads only its sibling FFmpeg libraries and the platform's own libraries.
#
#   ./verify-dist.sh macos   <prefix>   # otool
#   ./verify-dist.sh linux   <prefix>   # $READELF, default readelf
#   ./verify-dist.sh android <prefix>   # $READELF (the NDK's llvm-readelf)
#   ./verify-dist.sh windows <prefix>   # $OBJDUMP (llvm-mingw's objdump)
#
# Each build script runs this on its install prefix before packaging it, so a
# dependency the build host happened to have (a Homebrew or distro library
# that configure found, a toolchain runtime) can't ship. bae checks the
# artifacts it downloads the same way.

PLATFORM="${1:?usage: verify-dist.sh <macos|linux|android|windows> <prefix>}"
PREFIX="${2:?usage: verify-dist.sh <macos|linux|android|windows> <prefix>}"

failures=0
fail() {
    echo "ERROR: $1" >&2
    failures=$((failures + 1))
}

# Files under $PREFIX/$1 matching $2 that are not symlinks.
binaries() {
    local dir="$PREFIX/$1"
    [[ -d "$dir" ]] || return 0
    find "$dir" -maxdepth 1 -type f -name "$2"
}

case "$PLATFORM" in
macos)
    while IFS= read -r file; do
        while IFS= read -r load; do
            case "$load" in
                /usr/lib/* | /System/Library/*) ;;
                @rpath/*) [[ -e "$PREFIX/lib/${load#@rpath/}" ]] \
                    || fail "$file loads $load, which the dist lacks" ;;
                *) fail "$file loads $load, outside the dist and macOS" ;;
            esac
        done < <(otool -l "$file" | awk '/cmd LC_(LOAD|LOAD_WEAK|REEXPORT|LAZY_LOAD|LOAD_UPWARD)_DYLIB$/ { getline; getline; print $2 }')
        while IFS= read -r rpath; do
            case "$rpath" in
                @executable_path/* | @loader_path/*) ;;
                *) fail "$file has runpath $rpath, outside the dist" ;;
            esac
        done < <(otool -l "$file" | awk '/cmd LC_RPATH$/ { getline; getline; print $2 }')
    done < <(binaries lib '*.dylib'; binaries bin '*')
    ;;
linux | android)
    READELF="${READELF:-readelf}"
    if [[ "$PLATFORM" == linux ]]; then
        # glibc's own libraries and zlib, which every glibc distribution's base
        # system installs.
        system=" libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 librt.so.1 libz.so.1 ld-linux-x86-64.so.2 ld-linux-aarch64.so.1 "
    else
        # Android's stable NDK libraries the build can link.
        system=" libc.so libm.so libdl.so liblog.so libz.so "
    fi
    while IFS= read -r file; do
        dynamic="$("$READELF" -d "$file")"
        if [[ "$PLATFORM" == linux ]]; then
            # glibc finds a sibling only through the object's own runpath.
            case "$file" in
                "$PREFIX"/bin/*) expected='$ORIGIN/../lib' ;;
                *) expected='$ORIGIN' ;;
            esac
            runpath="$(sed -n 's/.*(RUNPATH).*\[\(.*\)\]/\1/p; s/.*(RPATH).*\[\(.*\)\]/\1/p' <<< "$dynamic")"
            [[ "$runpath" == "$expected" ]] \
                || fail "$file has runpath '${runpath}', expected '$expected'"
        fi
        while IFS= read -r needed; do
            [[ "$system" == *" $needed "* ]] && continue
            [[ -e "$PREFIX/lib/$needed" ]] \
                || fail "$file needs $needed, outside the dist and $PLATFORM"
        done < <(sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' <<< "$dynamic")
    done < <(binaries lib '*.so*'; binaries bin '*')
    ;;
windows)
    OBJDUMP="${OBJDUMP:?set OBJDUMP to the toolchain objdump}"
    # Windows' own DLLs; the Universal CRT (ucrtbase, api-ms-win-crt-*) is part
    # of Windows 10 and later.
    system=" advapi32.dll bcrypt.dll kernel32.dll ole32.dll oleaut32.dll shell32.dll user32.dll ucrtbase.dll ws2_32.dll "
    while IFS= read -r file; do
        while IFS= read -r dll; do
            lower="$(tr '[:upper:]' '[:lower:]' <<< "$dll")"
            [[ "$lower" == api-ms-win-* || "$system" == *" $lower "* ]] && continue
            ls "$PREFIX/bin" | tr '[:upper:]' '[:lower:]' | grep -qxF "$lower" \
                || fail "$file imports $dll, outside the dist and Windows"
        done < <("$OBJDUMP" -p "$file" | sed -n 's/.*DLL Name: *//p')
    done < <(binaries bin '*.dll'; binaries bin '*.exe')
    ;;
*)
    echo "verify-dist.sh: unknown platform $PLATFORM" >&2
    exit 2
    ;;
esac

if [[ "$failures" -gt 0 ]]; then
    echo "$failures reference(s) outside the dist and the OS" >&2
    exit 1
fi
echo "verify-dist.sh: $PLATFORM dist at $PREFIX loads only its own and system libraries"
