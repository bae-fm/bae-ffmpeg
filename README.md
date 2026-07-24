# bae-ffmpeg

Minimal audio-only FFmpeg builds for [bae](https://github.com/bae-fm/bae).

## What's included

Audio codecs only:
- **Decoders**: MP3, FLAC, APE, ALAC, AAC, Opus, Vorbis, WavPack, DSD, WAV/AIFF PCM
- **Encoders**: FLAC, PCM (for CD ripping)
- **Demuxers**: MP3, FLAC, APE, WAV, MP4/M4A, Ogg, AIFF, WavPack, DSF, DFF
- **Muxers**: FLAC, WAV
- **Filters**: `anoisesrc`, `aformat`, `anull`, `aresample` (for test fixture generation)
- **CLI**: `ffmpeg` binary included (for generating test fixtures)

Everything else is disabled (video codecs, video filters, network protocols, etc.).

## Build targets

| Platform | Architecture | Format |
|----------|-------------|--------|
| macOS | arm64 | .tar.gz |
| macOS | x86_64 | .tar.gz |
| Linux | x86_64 | .tar.gz |
| Linux | aarch64 | .tar.gz |
| Windows | x86_64 | .zip |
| Windows | aarch64 | .zip |
| iOS | arm64 (device) | .tar.gz |
| iOS | arm64 (simulator) | .tar.gz |
| Android | arm64 | .tar.gz |
| Android | x86_64 | .tar.gz |

Every platform and every build context (local dev, CI, release) links these
same prebuilt artifacts at the same FFmpeg version — no system/Homebrew/MSYS2
FFmpeg anywhere.

## Usage in bae CI

```yaml
- name: Download bae-ffmpeg
  run: |
    curl -L https://github.com/bae-fm/bae-ffmpeg/releases/download/v8.1.2-bae4/ffmpeg-macos-arm64.tar.gz | \
      tar xz -C /opt/bae-ffmpeg
    echo "FFMPEG_DIR=/opt/bae-ffmpeg" >> $GITHUB_ENV
    echo "PKG_CONFIG_PATH=/opt/bae-ffmpeg/lib/pkgconfig" >> $GITHUB_ENV
```

## Building locally

```bash
# macOS
./build-macos.sh arm64  # or x86_64

# Linux
./build-linux.sh x86_64  # or aarch64

# Windows (llvm-mingw, cross-compiled from Linux; deps bundled static)
./build-windows.sh x86_64  # or aarch64

# iOS (device + simulator)
./build-ios.sh

# Android (arm64 + x86_64; needs ANDROID_NDK_HOME)
./build-android.sh
```

Output goes to `dist/`.

## Releasing

Push a tag like `v8.1.2-bae4` to trigger a build and release:

```bash
git tag v8.1.2-bae4
git push origin v8.1.2-bae4
```

The version scheme is `v{ffmpeg_version}-bae{revision}`. The release CI builds
every platform in the table above — macOS, Linux, Windows, iOS, and Android —
and attaches each `dist/` artifact to the release.
