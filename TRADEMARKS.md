# Name and brand assets

Lagoon Engine's source code is licensed under the Mozilla Public License 2.0,
in [LICENSE](LICENSE). This file describes the one thing that licence does
not give you.

**The Lagoon name and the wordmark are not part of the grant.** MPL-2.0
covers every file in a repository by default, so this is an explicit
carve-out. This repository ships no artwork; the carve-out is about the name
alone.

## What you may do

Fork the code, build it, change it and ship it, under the terms in LICENSE.
Nothing here narrows those terms for the source.

## What to change first

Give your fork its own name before you distribute it. A build that calls
itself Lagoon Engine is one that people will report bugs about to this
project, which is the practical reason for the carve-out as much as the legal
one.

Renaming means the package name and any product name you show downstream of
it.

## What stays true

Say where it came from. That is the whole ask: MPL-2.0 already requires the
licence notice to travel with the files it covers, and this project's interest
is attribution rather than getting changes back.

Referring to Lagoon or Lagoon Engine by name to say what your fork is based
on, or to discuss or review the project, is normal nominative use and needs no
permission.

## The native libraries are separate

The FFmpeg, dav1d, uavs3d, lcms2 and libdovi binaries the engine links carry
their own licences, which this file and LICENSE do not alter. Their texts
travel with the vendored artifacts in this repository.

- FFmpeg's four libraries: LGPL-2.1-or-later, built here without their network
  stack. Every release attaches their complete corresponding source
  (`lagoon-engine-<version>-ffmpeg-8.1.3-source.tar.gz`), and libavcodec's
  Independent JPEG Group code asks an app to credit the IJG.
- dav1d and uavs3d: BSD. lcms2 and libdovi: MIT. libdovi's licence file also
  lists the Rust crates and standard library it links.

An app that statically links these libraries takes on the LGPL's relinking
terms for FFmpeg. Lagoon meets them by publishing its own source.

Everything but libdovi is built here from checksum-pinned upstream source, and
nothing is downloaded when the package resolves. Provenance and rebuild steps
are in [`FFmpeg.README.md`](Artifacts/FFmpeg.README.md),
[`Libdovi.README.md`](Artifacts/Libdovi.README.md), and the header of each
`scripts/build-*` script.

Copyright © Helop OÜ. Lagoon Engine is a project of Helop OÜ.
