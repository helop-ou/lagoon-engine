#!/usr/bin/env python3
"""Build Lagoon's libavformat without its network stack.

Requires Xcode, Python 3 and pkg-config. Only libavformat is rebuilt; the other
FFmpeg libraries remain at their Package.swift pins. Networking (HTTP/HTTPS/TLS/
TCP/UDP protocols and everything GnuTLS/GMP/nettle/hogweed) is compiled out;
the app reaches the server over Foundation's URLSession instead, so this build
carries only the local-file protocols libavformat itself still needs (opening
temporary files, `data:` URIs). Downloads are SHA-256 checked. Work/downloads
stay outside the repository. See the artifact README.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import stat
import subprocess
import tarfile
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "Packages/LagoonFFmpeg"
PATCHES = sorted((PACKAGE / "Patches").glob("*.patch"))
VERSION = "8.1.2"
SOURCE_URL = "https://codeload.github.com/FFmpeg/FFmpeg/tar.gz/refs/tags/n8.1.2"
SOURCE_SHA = "9fd092511605bbebafe095ea6d38d9e40f34d12f7386e1258372df8be0576eb7"
UPSTREAM_FORMAT_URL = "https://github.com/mpvkit/MPVKit/releases/download/1.0.0/Libavformat.xcframework.zip"
UPSTREAM_FORMAT_SHA = "2afb601375929640e743e7bdaa6c4a88e2b582a07e1c5f2dc95cc7f5b26a0810"
GROUPS = {
    "ios": ("iphoneos", "iPhoneOS", "ios-arm64", "ios26.0", ["arm64"]),
    "ios-simulator": ("iphonesimulator", "iPhoneSimulator", "ios-arm64_x86_64-simulator", "ios26.0-simulator", ["arm64", "x86_64"]),
    "tvos": ("appletvos", "AppleTVOS", "tvos-arm64_arm64e", "tvos26.0", ["arm64"]),
    "tvos-simulator": ("appletvsimulator", "AppleTVSimulator", "tvos-arm64_x86_64-simulator", "tvos26.0-simulator", ["arm64", "x86_64"]),
    "macos": ("macosx", "MacOSX", "macos-arm64_x86_64", "macos14.0", ["arm64", "x86_64"]),
}
GROUP_BY_SLICE = {info[2]: name for name, info in GROUPS.items()}

# Networking symbols that must not survive --disable-network/--disable-protocols.
FORBIDDEN_DEFINED_SYMBOLS = (
    "_ff_http_protocol", "_ff_https_protocol", "_ff_tls_protocol",
    "_ff_tcp_protocol", "_ff_udp_protocol",
)
# The TLS/bignum stack that leaves the package with the network stack.
FORBIDDEN_UNDEFINED_PREFIXES = ("_gnutls_", "_nettle_", "___gmpz_", "___gmpn_")


def run(args, **kwargs):
    return subprocess.check_output([str(arg) for arg in args], text=True, **kwargs).strip()


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def download(url, checksum, path):
    if not path.exists() or sha(path) != checksum:
        print(f"Downloading {path.name}", flush=True)
        with urllib.request.urlopen(url, timeout=120) as response, path.open("wb") as output:
            shutil.copyfileobj(response, output)
    if sha(path) != checksum:
        raise RuntimeError(f"Checksum mismatch: {path}")


def nm_symbols(binary, arch):
    """Return (defined, undefined) external symbol names for one slice."""
    defined, undefined = set(), set()
    for line in run(["nm", "-arch", arch, "-g", binary]).splitlines():
        fields = line.split()
        if len(fields) < 2:
            continue
        symtype, name = fields[-2], fields[-1]
        (undefined if symtype == "U" else defined).add(name)
    return defined, undefined


def read_config_header(artifact, library, work):
    """The built config.h + config_components.h for one xcframework slice,
    concatenated. FFmpeg 8.x splits per-component enables (CONFIG_*_DEMUXER,
    CONFIG_*_PROTOCOL, ...) into config_components.h; general build config
    (CONFIG_NETWORK, CONFIG_GPL, FFMPEG_CONFIGURATION, ...) stays in config.h.

    Both are copied into the framework's Headers during the build (see
    main()), so the artifact itself is the primary source; `work`, when
    given, is a fallback to that group's build directory for use mid-build.
    """
    headers = artifact / library["LibraryIdentifier"] / library["LibraryPath"] / "Headers"
    if not (headers / "config.h").exists() and work is not None:
        group = GROUP_BY_SLICE.get(library["LibraryIdentifier"])
        arch = library["SupportedArchitectures"][0]
        headers = work / f"build-{group}-{arch}"
    if not (headers / "config.h").exists():
        raise RuntimeError(f"config.h not found for {library['LibraryIdentifier']}")
    text = (headers / "config.h").read_text()
    components = headers / "config_components.h"
    if components.exists():
        text += "\n" + components.read_text()
    return text


def check_config_header(text, binary):
    if "#define CONFIG_NETWORK 0" not in text:
        raise RuntimeError(f"Networking still compiled into {binary}: CONFIG_NETWORK is not 0")
    if "#define CONFIG_HLS_DEMUXER 1" not in text:
        raise RuntimeError(f"HLS demuxer missing from {binary}: CONFIG_HLS_DEMUXER is not 1")
    configuration = re.search(r'^#define FFMPEG_CONFIGURATION "(.*)"$', text, re.M)[1]
    if "--disable-network" not in configuration:
        raise RuntimeError(f"{binary}: FFMPEG_CONFIGURATION is missing --disable-network")
    if "--enable-version3" in configuration:
        raise RuntimeError(f"{binary}: FFMPEG_CONFIGURATION still requests --enable-version3")


def check_license(text, where):
    for define in ("#define CONFIG_GPL 0", "#define CONFIG_NONFREE 0", "#define CONFIG_VERSION3 0"):
        if define not in text:
            raise RuntimeError(f"{where}: build is not LGPL-2.1-or-later, missing '{define}' in config.h")


def verify(artifact, work=None):
    metadata = json.loads((artifact / "BUILD.json").read_text())
    if metadata.get("patches", {}) != {patch.name: sha(patch) for patch in PATCHES}:
        raise RuntimeError("Patches changed: rebuild libavformat")
    for relative, checksum in metadata["files"].items():
        if sha(artifact / relative) != checksum:
            raise RuntimeError(f"Artifact changed: {relative}")
    info = plistlib.loads((artifact / "Info.plist").read_bytes())
    for library in info["AvailableLibraries"]:
        binary = artifact / library["LibraryIdentifier"] / library["LibraryPath"] / "Libavformat"
        check_config_header(read_config_header(artifact, library, work), binary)
        for arch in library["SupportedArchitectures"]:
            defined, undefined = nm_symbols(binary, arch)
            for symbol in FORBIDDEN_DEFINED_SYMBOLS:
                if symbol in defined:
                    raise RuntimeError(f"Network protocol linked into {binary} ({arch}): {symbol}")
            for symbol in undefined:
                if symbol.startswith(FORBIDDEN_UNDEFINED_PREFIXES):
                    raise RuntimeError(f"GnuTLS/GMP/nettle reference remains in {binary} ({arch}): {symbol}")
    print(f"Verified {artifact}: checksums; no http/https/tls/tcp/udp protocol symbols; "
          f"no gnutls_/nettle_/__gmpz_/__gmpn_ references; CONFIG_NETWORK 0; CONFIG_HLS_DEMUXER 1 in every architecture; "
          f"{len(PATCHES)} patch(es) recorded")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work", type=Path, help="Persistent build/download directory (default: new temporary directory)")
    parser.add_argument("--output", type=Path, default=PACKAGE / "Artifacts/Libavformat.xcframework")
    parser.add_argument("--groups", nargs="+", choices=GROUPS, default=list(GROUPS), help="Subset for development; commit only the complete artifact")
    parser.add_argument("--verify-only", type=Path)
    args = parser.parse_args()
    if args.verify_only:
        verify(args.verify_only)
        return
    work = (args.work or Path(tempfile.mkdtemp(prefix="lagoon-libavformat-"))).resolve()
    work.mkdir(parents=True, exist_ok=True)
    print(f"Build logs and source: {work}", flush=True)
    archive = work / "ffmpeg-n8.1.2.tar.gz"
    download(SOURCE_URL, SOURCE_SHA, archive)
    source = work / "FFmpeg-n8.1.2"
    if source.exists():
        shutil.rmtree(source)
    with tarfile.open(archive) as tar:
        tar.extractall(work, filter="data")
    for patch in PATCHES:
        # hls.c refuses any URL whose scheme has no registered protocol, which
        # with the network stack gone is every http(s) URL; the patch lets it
        # classify the scheme from the URL and hand the open to io_open.
        print(f"Applying {patch.name}", flush=True)
        with patch.open() as stream:
            subprocess.run(["patch", "-p1", "--batch"], cwd=source, stdin=stream, check=True)

    # The original format configuration is itself checksum-pinned. Retain its
    # muxer/demuxer set and in-tree codec options for internal ABI compatibility.
    # (hls is a demuxer, carried over below; its keepalive code is compiled
    # out on its own, guarded by `#if CONFIG_HTTP_PROTOCOL` in hls.c.)
    manifest = (PACKAGE / "Package.swift").read_text()
    pins = {name: (url, checksum) for name, url, checksum in re.findall(
        r'name: "([^"]+)",\s*url: "([^"]+)",\s*checksum: "([^"]+)"', manifest)}
    pins["Libavformat"] = (UPSTREAM_FORMAT_URL, UPSTREAM_FORMAT_SHA)
    dependencies = {}
    for name in ("Libavformat",):
        url, checksum = pins[name]
        archive = work / f"{name}.xcframework.zip"
        download(url, checksum, archive)
        directory = work / "dependencies" / name
        if directory.exists():
            shutil.rmtree(directory)
        directory.mkdir(parents=True)
        with zipfile.ZipFile(archive) as zipped:
            zipped.extractall(directory)
            # macOS frameworks use Versions/Current symlinks. zipfile otherwise
            # writes the link target as text, which is not a static archive.
            for member in zipped.infolist():
                if stat.S_ISLNK(member.external_attr >> 16):
                    link = directory / member.filename
                    link.unlink()
                    link.symlink_to(zipped.read(member).decode())
        dependencies[name] = directory / f"{name}.xcframework"
    header = dependencies["Libavformat"] / "ios-arm64/Libavformat.framework/Headers/config.h"
    original = re.search(r'^#define FFMPEG_CONFIGURATION "(.*)"$', header.read_text(), re.M)[1]
    selections = [flag for flag in shlex.split(original) if flag.startswith((
        "--disable-muxers", "--enable-muxer=", "--disable-demuxers", "--enable-demuxer=",
        "--disable-encoders", "--enable-encoder=", "--disable-decoders", "--enable-decoder="))
        and "libdav1d" not in flag and "libuavs3d" not in flag]
    frameworks = []
    configurations = {}
    for group in args.groups:
        sdk, platform, dep_slice, target_os, architectures = GROUPS[group]
        sysroot = run(["xcrun", "--sdk", sdk, "--show-sdk-path"])
        libs = []
        for arch in architectures:
            build = work / f"build-{group}-{arch}"
            if build.exists():
                shutil.rmtree(build)
            build.mkdir()
            include = build / "deps/include"
            lib = build / "deps/lib"
            include.mkdir(parents=True)
            lib.mkdir(parents=True)
            pc = lib / "pkgconfig"
            pc.mkdir()
            (pc / "libxml-2.0.pc").write_text(
                f"Name: libxml2\nDescription: Apple SDK libxml2\nVersion: 2.9.13\n"
                f"Libs: -lxml2\nCflags: -I{sysroot}/usr/include/libxml2\n")
            triple = f"{arch}-apple-{target_os}"
            flags = f"-target {triple} -isysroot {sysroot}"
            options = [
                "--target-os=darwin", f"--arch={'aarch64' if arch == 'arm64' else arch}",
                "--enable-cross-compile", "--cc=clang", "--cxx=clang++", "--host-cc=clang",
                "--host-ld=clang", "--enable-static", "--disable-shared",
                "--enable-pic", "--disable-autodetect", "--disable-programs",
                "--disable-doc", "--disable-debug", "--disable-avdevice", "--disable-avfilter",
                "--disable-filters", "--disable-devices", "--disable-bzlib", "--disable-iconv",
                "--disable-xlib", "--disable-x86asm", "--disable-network", "--disable-protocols",
                "--enable-protocol=file", "--enable-protocol=data",
                "--enable-libxml2", "--enable-zlib",
                "--enable-videotoolbox", "--enable-audiotoolbox", "--pkg-config-flags=--static",
                f"--extra-cflags={flags} -I{include}",
                f"--extra-ldflags={flags} -L{lib} -framework Security -framework CoreFoundation",
            ] + selections
            configurations[f"{group}-{arch}"] = options
            env = dict(os.environ, PKG_CONFIG_LIBDIR=str(pc), PKG_CONFIG_PATH="")
            print(f"Building {group} {arch}", flush=True)
            with (work / f"{group}-{arch}.log").open("w") as log:
                subprocess.run([str(source / "configure"), *options], cwd=build, env=env,
                               stdout=log, stderr=subprocess.STDOUT, check=True)
                subprocess.run(["make", f"-j{min(os.cpu_count() or 4, 12)}", "libavformat/libavformat.a"],
                               cwd=build, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
            libs.append(build / "libavformat/libavformat.a")
        framework = work / "frameworks" / group / "Libavformat.framework"
        if framework.exists():
            shutil.rmtree(framework)
        framework.mkdir(parents=True)
        run(["lipo", "-create", *libs, "-output", framework / "Libavformat"])
        # Upstream public headers match this exact source release and preserve
        # its framework module layout (including libavutil/libavcodec includes).
        shutil.copytree(dependencies["Libavformat"] / dep_slice / "Libavformat.framework/Headers", framework / "Headers")
        shutil.copyfile(build / "config.h", framework / "Headers/config.h")
        # FFmpeg 8.x moves per-component enables (CONFIG_*_DEMUXER, CONFIG_*_PROTOCOL, ...)
        # out of config.h into this sibling; verify() needs both to confirm the build.
        shutil.copyfile(build / "config_components.h", framework / "Headers/config_components.h")
        check_license((framework / "Headers/config.h").read_text(), f"{group} config.h")
        (framework / "Modules").mkdir()
        (framework / "Modules/module.modulemap").write_text('framework module Libavformat [system] {\n    umbrella "."\n    export *\n}\n')
        info = dict(CFBundleExecutable="Libavformat", CFBundleIdentifier="ee.helop.Libavformat",
                    CFBundleName="Libavformat", CFBundlePackageType="FMWK", CFBundleVersion=VERSION,
                    CFBundleShortVersionString=VERSION, CFBundleSupportedPlatforms=[platform],
                    MinimumOSVersion="100.0", CFBundleInfoDictionaryVersion="6.0")
        (framework / "Info.plist").write_bytes(plistlib.dumps(info))
        frameworks += ["-framework", str(framework)]
    output = args.output.resolve()
    if output.exists():
        shutil.rmtree(output)
    run(["xcodebuild", "-create-xcframework", *frameworks, "-output", output])
    for license_name in ("COPYING.LGPLv2.1", "COPYING.LGPLv3", "COPYING.GPLv3", "LICENSE.md"):
        shutil.copyfile(source / license_name, output / license_name)
    metadata = dict(source_url=SOURCE_URL, source_sha256=SOURCE_SHA, network=False, license="LGPL-2.1-or-later",
                    patches={patch.name: sha(patch) for patch in PATCHES},
                    xcode=run(["xcodebuild", "-version"]), configurations=configurations,
                    files={str(path.relative_to(output)): sha(path) for path in sorted(output.rglob("*")) if path.is_file()})
    (output / "BUILD.json").write_text(json.dumps(metadata, indent=2) + "\n")
    verify(output, work)


if __name__ == "__main__":
    main()
