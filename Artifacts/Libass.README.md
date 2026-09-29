# Lagoon's libass artifact

`Libass.xcframework` is **libass 0.17.5** and the three libraries it renders
with, **FreeType 2.14.3**, **FriBidi 1.0.17** and **HarfBuzz 14.5.0**, merged
into one static archive per slice. The engine uses it to draw styled ASS/SSA
subtitles (`StyledSubtitleRenderer`); only libass's own API (`ass/ass.h`) is
exposed.

## Provenance

Built by `scripts/build-libass.sh` from each project's release tarball,
SHA-256 pinned in the script, with meson for every slice the other artifacts
carry (tvOS and iOS devices and simulators, and macOS for indexing). Choices:

- **Fonts.** CoreText is libass's system font provider; fontconfig is not
  built. The media's own fonts come from its attachments at runtime.
- **FreeType** without HarfBuzz, PNG or Brotli, with its internal zlib, and
  without mmap: it reads font files through stdio, so it never calls `fstat`.
- **HarfBuzz** with only the FreeType integration: no GLib, ICU, Cairo,
  CoreText, subsetter or utilities, and built with `HB_NO_MMAP`, which drops
  its only `fstat` caller. (Its source promotes the now-unused resource-fork
  reader to an error, so `HB_NO_PRAGMA_GCC_DIAGNOSTIC_ERROR` is set; the
  function is not emitted.)
- **FriBidi** as the library only.
- **libass** with its assembly (nasm for the x86_64 simulators), no
  libunibreak, tests or tools.
- Local symbols are stripped (`strip -x -S`); the exported API is untouched.

The script fails unless every slice defines libass, FreeType, FriBidi and
HarfBuzz entry points, none references fontconfig, and none imports `stat`,
`fstat`, `lstat`, `fstatat` or `getattrlist`: file-timestamp APIs a host
would have to declare in its privacy manifest.

## Licences

| Library | Licence | Text |
|---|---|---|
| libass | ISC | `LICENSES/libass.COPYING` |
| FreeType | FreeType Licence (FTL), chosen over its GPL-2.0 alternative | `LICENSES/freetype.LICENSE.TXT`, `LICENSES/freetype.FTL.TXT` |
| HarfBuzz | MIT ("Old MIT") | `LICENSES/harfbuzz.COPYING` |
| FriBidi | LGPL-2.1-or-later | `LICENSES/fribidi.COPYING` |

FriBidi is linked statically, so, as for FFmpeg, every release attaches its
complete corresponding source (`scripts/fribidi-source-bundle.sh`, run by
`scripts/publish-release.sh`). The FTL asks that documentation of a product
using FreeType credit it; hosts do so in their acknowledgements.
