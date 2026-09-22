# Lagoon's libdovi artifact

`Libdovi.xcframework` is **libdovi**, the C API of the `dolby_vision` Rust
crate behind [dovi_tool](https://github.com/quietvoid/dovi_tool), crate
version **3.4.0** (upstream tag `libdovi-3.4.0`). Lagoon uses it for one
thing: rewriting a Dolby Vision profile 7 RPU into single-layer profile 8.1
while the packet is in flight (`dovi_parse_unspec62_nalu`,
`dovi_convert_rpu_with_mode(rpu, 2)`, `dovi_write_unspec62_nalu`), so a
UHD Blu-ray remux plays as Dolby Vision on an Apple TV instead of HDR10.

## Provenance

Vendored from [superuser404notfound/LibDovi](https://github.com/superuser404notfound/LibDovi)
at tag `2.1.0`, commit `0d7cce1d6836a30d13a3a2326e50a153af53f014`, which
cross-compiles the crate with stable Rust and `cargo-c` (its `build.sh`).
Two things differ from upstream's `Dovi.xcframework`:

- the two visionOS slices are dropped, Lagoon ships iOS and tvOS only;
- every `libdovi.a` is stripped of local symbols (`strip -x -S`), which
  halves each slice without touching the exported `dovi_*` API.

The tvOS simulator slice is arm64 only. `x86_64-apple-tvos` is a tier-3 Rust
target with no prebuilt standard library, and the project excludes x86_64 for
the Apple TV simulator SDK instead (`EXCLUDED_ARCHS[sdk=appletvsimulator*]`
in the Xcode project); nothing this project runs on is an Intel Mac.

| Slice | SHA-256 of `libdovi.a` | Size |
|---|---|---|
| `ios-arm64` | `49e5d29609d3c9120b5e2fa325f5cea4b5ecabc31a7f504485eaba7cd07cf2b9` |  12M |
| `ios-arm64_x86_64-simulator` | `3947c54589447ec7bc648b0e812ed845aaf339ec37972bf40ef674c2507c7067` |  23M |
| `tvos-arm64` | `a40623a36f075ef7bbe42b34b7dddeaf804f64ab936ef7406338eb0692673441` |  12M |
| `tvos-arm64-simulator` | `3971b6142dd470cd7b0fb75bc9f3f903762e45193a531c42ac7ff966c8d259ca` |  12M |
| `macos-arm64_x86_64` | `73bedef3079b6aa70571818709e4ccff7e687db64802350ffa0476e61dc55bd1` |  24M |

`dovi.h` SHA-256: `772414183763c6ab234789f38fd6850168faf6b288a1763b6bb19370b14af7be` (identical in every slice; the module map exposes it
as `import Dovi`).

## Rebuilding

Not built by this repository: the machine it is maintained on has no Rust
toolchain, and a from-source build is upstream's `build.sh` verbatim
(`rustup target add …`, `cargo install cargo-c`, `./build.sh`). To take a
newer libdovi, bump the LibDovi tag, copy the five slices, strip them, drop
the visionOS entries from `Info.plist`, and refresh the table above. A
repo-owned build script is the right move if this ever needs a patch, the way
dav1d and libavformat did.

## License

libdovi is dual-licensed MIT or Apache-2.0 and is used here under the MIT
option; the copyright notice that must accompany the binary is quietvoid's
and belongs in the acknowledgements. LibDovi's own packaging is MIT.
