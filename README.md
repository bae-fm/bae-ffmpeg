# bae-ffmpeg

Minimal audio-only FFmpeg builds for [bae](https://github.com/bae-fm/bae).

## What's included

Audio codecs only:
- **Decoders**: MP3, FLAC, APE, WAV/PCM
- **Encoders**: FLAC, PCM (for CD ripping)
- **Demuxers**: MP3, FLAC, APE, WAV, AIFF, CAF
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

## Usage in bae CI

```yaml
- name: Download bae-ffmpeg
  run: |
    curl -L https://github.com/bae-fm/bae-ffmpeg/releases/download/v8.0.1-bae6/ffmpeg-macos-arm64.tar.gz | \
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

# Windows (MSYS2)
./build-windows.sh
```

Output goes to `dist/`.

## Releasing

Push a tag like `v8.0.1-bae6` to trigger a build and release:

```bash
git tag v8.0.1-bae6
git push origin v8.0.1-bae6
```

The version scheme is `v{ffmpeg_major}.{ffmpeg_minor}-bae{revision}`.
