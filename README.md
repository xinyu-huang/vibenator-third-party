# Vibenator — third-party library sources

Vibenator is a macOS music library application. It uses three third-party
libraries released under free-software licences. This repository exists so that
anyone who has a copy of Vibenator can obtain, inspect, modify and rebuild those
libraries — it holds the modifications made to them and the exact scripts used to
build the binaries that ship inside the app.

Nothing here is part of Vibenator itself. This repository is published to meet the
obligations of the libraries' licences, and everything in it relates to FFmpeg,
Chromaprint and TagLib rather than to the application.

## The libraries

| Library | Version | Licence | Modified? | Linking |
|---|---|---|---|---|
| [FFmpeg](https://ffmpeg.org/) | 7.1 | LGPL 2.1 or later | **Yes** — see `patches/` | Dynamic (`libav*.dylib`) |
| [Chromaprint](https://acoustid.org/chromaprint) | 1.5.1 | LGPL 2.1 or later | No | Dynamic (`libchromaprint.dylib`) |
| [TagLib](https://taglib.org/) | as released | LGPL 2.1 **or** MPL 1.1 | No | Static, under MPL 1.1 |

FFmpeg is built **without** `--enable-gpl` and **without** `--enable-nonfree`, so
the result is LGPL, not GPL. See `scripts/build_ffmpeg_static.sh` for the complete
configure invocation — every enabled demuxer, decoder and parser is listed there.

FFmpeg and Chromaprint are linked dynamically and ship as separate `.dylib` files
inside `Vibenator.app/Contents/Frameworks/`, so either may be replaced with your
own build (see below). TagLib is linked statically under the MPL 1.1 half of its
dual licence; it is unmodified, so its source is the upstream release.

## Modifications to FFmpeg

Two patches, both applied to a pristine FFmpeg 7.1 tree before `configure`. Each
is a unified diff and carries an inline comment explaining the reasoning.

- **`patches/0001-iff-tolerate-garbage-trailing-chunk.patch`** — `libavformat/iff.c`.
  Some DSDIFF rippers append a trailing chunk whose 64-bit size field is garbage,
  after an otherwise valid audio body. Upstream aborts the whole header parse, so
  the file becomes unreadable even though its audio chunk was already located and
  is intact. The patch stops scanning for further metadata when a body chunk has
  already been found, and falls through to the original error when none has, so
  genuinely corrupt files are still rejected.

- **`patches/0002-dstdec-raw-dsd-output-option.patch`** — `libavcodec/dstdec.c`.
  Adds a decoder option to emit raw DSD rather than converted output.

## Rebuilding

Both scripts are the ones actually used to produce the shipped binaries — they are
not a reconstruction. They download the upstream release, verify the patches apply,
build, and write the libraries into the application's source tree.

```sh
bash scripts/build_ffmpeg_static.sh
bash scripts/build_chromaprint_static.sh
```

Requirements: Xcode command line tools, and `cmake` for Chromaprint. Neither script
takes anything from Homebrew — FFmpeg is configured with `--disable-autodetect`
precisely so the build cannot pick up whatever happens to be installed on the build
machine.

The scripts are named `..._static.sh` for historical reasons; both now produce
shared libraries.

### Replacing a library in an installed copy of Vibenator

The libraries live in `Vibenator.app/Contents/Frameworks/`, named
`libavcodec.dylib`, `libavformat.dylib`, `libavutil.dylib`, `libswresample.dylib`
and `libchromaprint.dylib`. Each has an `@rpath` install name and the application
carries an `@executable_path/../Frameworks` runpath, so a replacement of the same
name is picked up in place.

Because macOS applications are code-signed, replacing a file inside the bundle
invalidates the signature; you will need to re-sign the bundle locally
(`codesign --force --deep --sign - Vibenator.app`) for the modified library to
load. This is a platform constraint rather than a restriction imposed by the
application.

## Obtaining the unmodified sources

- FFmpeg 7.1 — <https://ffmpeg.org/releases/ffmpeg-7.1.tar.bz2>
- Chromaprint 1.5.1 — <https://github.com/acoustid/chromaprint/releases/tag/v1.5.1>
- TagLib — <https://taglib.org/>

## Licences

FFmpeg and Chromaprint are used under the GNU Lesser General Public License,
version 2.1 or later: <https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html>

TagLib is used under the Mozilla Public License, version 1.1:
<https://www.mozilla.org/en-US/MPL/1.1/>

The patches in `patches/` are modifications to FFmpeg and are offered under the
same terms as FFmpeg itself (LGPL 2.1 or later). The build scripts in `scripts/`
are released into the public domain; use them however you like.
