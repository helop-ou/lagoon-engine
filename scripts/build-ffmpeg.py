#!/usr/bin/env python3
"""Build the engine's four FFmpeg libraries from one configure.

libavutil, libavcodec, libavformat and libswresample, FFmpeg n8.1.2, as four
xcframeworks. Requires Xcode, Python 3 and pkg-config, and the Libdav1d, lcms2
and Libuavs3d artifacts already in Artifacts/ (build-dav1d.sh, build-lcms2.sh,
build-uavs3d.sh), because libavcodec links against them.

Networking (HTTP/HTTPS/TLS/TCP/UDP protocols and everything
GnuTLS/GMP/nettle/hogweed) is compiled out; the engine reaches the server over
Foundation's URLSession instead, so libavformat carries only the local-file
protocols it still needs itself (temporary files, `data:` URIs). With GnuTLS
gone, so is the --enable-version3 it required, and every library is
LGPL-2.1-or-later; check_license() fails the build if that ever changes. The
only download is FFmpeg's own source tarball, SHA-256 checked; everything else
the build needs is in this repository. Work/downloads stay outside it. See
Artifacts/FFmpeg.README.md.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
ARTIFACTS = ROOT / "Artifacts"
PATCHES = sorted((ROOT / "Patches").glob("*.patch"))
VERSION = "8.1.2"
SOURCE_URL = "https://codeload.github.com/FFmpeg/FFmpeg/tar.gz/refs/tags/n8.1.2"
SOURCE_SHA = "9fd092511605bbebafe095ea6d38d9e40f34d12f7386e1258372df8be0576eb7"
SELECTIONS = Path(__file__).resolve().parent / "ffmpeg-selections.txt"
# Framework name -> FFmpeg's directory for it. One configure builds all four,
# so they share one config.h and cannot drift from each other.
LIBRARIES = {
    "Libavutil": "libavutil",
    "Libavcodec": "libavcodec",
    "Libavformat": "libavformat",
    "Libswresample": "libswresample",
}
# Headers upstream installs but that describe hardware APIs no Apple SDK has,
# so they cannot be part of a module a Swift target imports. The same set the
# previous artifacts excluded.
MODULE_EXCLUDES = {
    "Libavutil": ("hwcontext_vulkan.h", "hwcontext_vdpau.h", "hwcontext_vaapi.h", "hwcontext_qsv.h",
                  "hwcontext_opencl.h", "hwcontext_dxva2.h", "hwcontext_d3d11va.h", "hwcontext_d3d12va.h",
                  "hwcontext_cuda.h", "hwcontext_amf.h"),
    "Libavcodec": ("xvmc.h", "vdpau.h", "qsv.h", "dxva2.h", "d3d11va.h", "d3d12va.h"),
}
# group -> (sdk, Info.plist platform, xcframework platform, variant, target OS, architectures)
GROUPS = {
    "ios": ("iphoneos", "iPhoneOS", "ios", None, "ios26.0", ["arm64"]),
    "ios-simulator": ("iphonesimulator", "iPhoneSimulator", "ios", "simulator", "ios26.0-simulator", ["arm64", "x86_64"]),
    "tvos": ("appletvos", "AppleTVOS", "tvos", None, "tvos26.0", ["arm64"]),
    "tvos-simulator": ("appletvsimulator", "AppleTVSimulator", "tvos", "simulator", "tvos26.0-simulator", ["arm64", "x86_64"]),
    "macos": ("macosx", "MacOSX", "macos", None, "macos14.0", ["arm64", "x86_64"]),
}
# The native libraries libavcodec links against: artifact, framework binary,
# pkg-config name, -l name, extra link flags. All three are built here too.
DEPENDENCIES = (
    ("Libdav1d.xcframework", "Libdav1d", "dav1d", "dav1d", ""),
    ("lcms2.xcframework", "lcms2", "lcms2", "lcms2", ""),
    ("Libuavs3d.xcframework", "Libuavs3d", "uavs3d", "uavs3d", " -lm -lpthread"),
)

# Networking symbols that must not survive --disable-network/--disable-protocols.
FORBIDDEN_DEFINED_SYMBOLS = (
    "_ff_http_protocol", "_ff_https_protocol", "_ff_tls_protocol",
    "_ff_tcp_protocol", "_ff_udp_protocol",
)
# Libraries the previous artifacts linked and these must not: the TLS/bignum
# stack that left with the network stack, and the Vulkan/libplacebo/shaderc/
# libass stack the upstream build carried for a player UI this engine is not.
FORBIDDEN_UNDEFINED_PREFIXES = (
    "_gnutls_", "_nettle_", "___gmpz_", "___gmpn_",
    "_vkGet", "_vkCreate", "_pl_", "_shaderc_", "_ass_",
)


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
    for line in run(["nm", "-arch", arch, "-g", binary], stderr=subprocess.DEVNULL).splitlines():
        fields = line.split()
        if len(fields) < 2:
            continue
        symtype, name = fields[-2], fields[-1]
        (undefined if symtype == "U" else defined).add(name)
    return defined, undefined


def read_selections():
    """The muxer/demuxer/encoder/decoder flags, in file order.

    Committed rather than derived, so the build needs nothing but the FFmpeg
    tarball. See the file itself for its provenance and how to regenerate it.
    """
    flags = [line.strip() for line in SELECTIONS.read_text().splitlines()]
    flags = [flag for flag in flags if flag and not flag.startswith("#")]
    if not flags:
        raise RuntimeError(f"No configure flags in {SELECTIONS}")
    for flag in flags:
        if not flag.startswith("--"):
            raise RuntimeError(f"{SELECTIONS}: not a configure flag: {flag}")
    return flags


def slice_directory(xcframework, group):
    """The slice of an xcframework that serves one platform group."""
    _sdk, _platform, platform, variant, _target, _archs = GROUPS[group]
    info = plistlib.loads((xcframework / "Info.plist").read_bytes())
    for library in info["AvailableLibraries"]:
        if library["SupportedPlatform"] == platform and library.get("SupportedPlatformVariant") == variant:
            return xcframework / library["LibraryIdentifier"] / library["LibraryPath"]
    raise RuntimeError(f"{xcframework.name} has no slice for {group}")


def write_dependencies(group, deps):
    """pkg-config files, and library links, that point configure at the
    dependency artifacts in this repository rather than at anything installed
    on the machine. The archives are fat; the linker takes the matching
    architecture from them.
    """
    sysroot = run(["xcrun", "--sdk", GROUPS[group][0], "--show-sdk-path"])
    include, lib, pc = deps / "include", deps / "lib", deps / "lib/pkgconfig"
    for directory in (include, lib, pc):
        directory.mkdir(parents=True, exist_ok=True)
    (pc / "libxml-2.0.pc").write_text(
        f"Name: libxml2\nDescription: Apple SDK libxml2\nVersion: 2.9.13\n"
        f"Libs: -lxml2\nCflags: -I{sysroot}/usr/include/libxml2\n")
    versions = {}
    for artifact, binary, package, link, extra in DEPENDENCIES:
        framework = slice_directory(ARTIFACTS / artifact, group)
        version = plistlib.loads((framework / "Info.plist").read_bytes())["CFBundleShortVersionString"]
        versions[artifact] = version
        (lib / f"lib{link}.a").symlink_to(framework / binary)
        (pc / f"{package}.pc").write_text(
            f"Name: {package}\nDescription: {artifact}\nVersion: {version}\n"
            f"Libs: -L{lib} -l{link}{extra}\nCflags: -I{framework / 'Headers'}\n")
    return pc, versions


def read_config_header(artifact, library, work):
    """The built config.h + config_components.h for one xcframework slice,
    concatenated. FFmpeg 8.x splits per-component enables (CONFIG_*_DEMUXER,
    CONFIG_*_PROTOCOL, ...) into config_components.h; general build config
    (CONFIG_NETWORK, CONFIG_GPL, FFMPEG_CONFIGURATION, ...) stays in config.h.

    Both are copied into every framework's Headers during the build (see
    main()), so the artifact itself is the primary source; `work`, when
    given, is a fallback to that group's build directory for use mid-build.
    """
    headers = artifact / library["LibraryIdentifier"] / library["LibraryPath"] / "Headers"
    if not (headers / "config.h").exists() and work is not None:
        group = next(name for name in GROUPS if GROUPS[name][2] == library["SupportedPlatform"]
                     and GROUPS[name][3] == library.get("SupportedPlatformVariant"))
        headers = work / f"build-{group}-{GROUPS[group][5][0]}"
    if not (headers / "config.h").exists():
        raise RuntimeError(f"config.h not found for {library['LibraryIdentifier']}")
    text = (headers / "config.h").read_text()
    components = headers / "config_components.h"
    if components.exists():
        text += "\n" + components.read_text()
    return text


def check_license(text, where):
    for define in ("#define CONFIG_GPL 0", "#define CONFIG_NONFREE 0", "#define CONFIG_VERSION3 0"):
        if define not in text:
            raise RuntimeError(f"{where}: build is not LGPL-2.1-or-later, missing '{define}' in config.h")


def check_config_header(text, name, binary):
    check_license(text, binary)
    required = ["#define CONFIG_NETWORK 0"]
    if name == "Libavformat":
        required.append("#define CONFIG_HLS_DEMUXER 1")
    if name == "Libavcodec":
        # The engine asks for libdav1d by name, and AVS3 has no other decoder.
        required += ["#define CONFIG_LIBDAV1D_DECODER 1", "#define CONFIG_LIBUAVS3D_DECODER 1",
                     "#define CONFIG_LCMS2 1"]
    for define in required:
        if define not in text:
            raise RuntimeError(f"{binary}: config.h is missing '{define}'")
    configuration = re.search(r'^#define FFMPEG_CONFIGURATION "(.*)"$', text, re.M)[1]
    if "--disable-network" not in configuration:
        raise RuntimeError(f"{binary}: FFMPEG_CONFIGURATION is missing --disable-network")
    if "--enable-version3" in configuration:
        raise RuntimeError(f"{binary}: FFMPEG_CONFIGURATION still requests --enable-version3")


def verify(artifact, work=None):
    name = artifact.name.removesuffix(".xcframework")
    if name not in LIBRARIES:
        raise RuntimeError(f"{artifact}: not one of {', '.join(LIBRARIES)}")
    metadata = json.loads((artifact / "BUILD.json").read_text())
    if metadata.get("patches", {}) != {patch.name: sha(patch) for patch in PATCHES}:
        raise RuntimeError("Patches changed: rebuild FFmpeg")
    for relative, checksum in metadata["files"].items():
        if sha(artifact / relative) != checksum:
            raise RuntimeError(f"Artifact changed: {relative}")
    info = plistlib.loads((artifact / "Info.plist").read_bytes())
    for library in info["AvailableLibraries"]:
        binary = artifact / library["LibraryIdentifier"] / library["LibraryPath"] / name
        check_config_header(read_config_header(artifact, library, work), name, binary)
        for arch in library["SupportedArchitectures"]:
            defined, undefined = nm_symbols(binary, arch)
            for symbol in FORBIDDEN_DEFINED_SYMBOLS:
                if symbol in defined:
                    raise RuntimeError(f"Network protocol linked into {binary} ({arch}): {symbol}")
            for symbol in undefined:
                if symbol.startswith(FORBIDDEN_UNDEFINED_PREFIXES):
                    raise RuntimeError(f"{binary} ({arch}) references a library it must not: {symbol}")
    print(f"Verified {artifact.name}: checksums; LGPL-2.1-or-later (CONFIG_GPL/NONFREE/VERSION3 0); "
          f"CONFIG_NETWORK 0; no network protocols; no GnuTLS/GMP/nettle/Vulkan/libplacebo/libass "
          f"references in every architecture; {len(PATCHES)} patch(es) recorded")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--work", type=Path, help="Persistent build/download directory (default: new temporary directory)")
    parser.add_argument("--output", type=Path, default=ARTIFACTS, help="Directory the four xcframeworks are written to")
    parser.add_argument("--groups", nargs="+", choices=GROUPS, default=list(GROUPS), help="Subset for development; commit only the complete artifacts")
    parser.add_argument("--verify-only", type=Path, nargs="+", metavar="XCFRAMEWORK")
    args = parser.parse_args()
    if args.verify_only:
        for artifact in args.verify_only:
            verify(artifact.resolve())
        return
    work = (args.work or Path(tempfile.mkdtemp(prefix="lagoon-ffmpeg-"))).resolve()
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

    selections = read_selections()
    frameworks = {name: [] for name in LIBRARIES}
    configurations = {}
    dependency_versions = {}
    for group in args.groups:
        sdk, platform, _platform, _variant, target_os, architectures = GROUPS[group]
        sysroot = run(["xcrun", "--sdk", sdk, "--show-sdk-path"])
        builds = []
        for arch in architectures:
            build = work / f"build-{group}-{arch}"
            if build.exists():
                shutil.rmtree(build)
            build.mkdir()
            pc, dependency_versions = write_dependencies(group, build / "deps")
            triple = f"{arch}-apple-{target_os}"
            flags = f"-target {triple} -isysroot {sysroot}"
            options = [
                f"--prefix={build / 'install'}",
                "--target-os=darwin", f"--arch={'aarch64' if arch == 'arm64' else arch}",
                "--enable-cross-compile", "--cc=clang", "--cxx=clang++", "--host-cc=clang",
                "--host-ld=clang", "--enable-static", "--disable-shared",
                "--enable-pic", "--enable-runtime-cpudetect", "--disable-autodetect", "--disable-programs",
                "--disable-doc", "--disable-debug", "--disable-avdevice", "--disable-avfilter", "--disable-swscale",
                "--disable-filters", "--disable-devices", "--disable-bzlib", "--disable-iconv",
                # x86_64 is only ever an Intel simulator; nasm objects carry no
                # platform load command. Same trade as build-dav1d.sh.
                "--disable-xlib", "--disable-x86asm", "--disable-network", "--disable-protocols",
                "--enable-protocol=file", "--enable-protocol=data",
                "--enable-libxml2", "--enable-zlib",
                "--enable-videotoolbox", "--enable-audiotoolbox",
                "--enable-libdav1d", "--enable-libuavs3d", "--enable-lcms2",
                "--pkg-config-flags=--static",
                f"--extra-cflags={flags}",
                f"--extra-ldflags={flags} -framework Security -framework CoreFoundation",
            ] + selections
            configurations[f"{group}-{arch}"] = options
            env = dict(os.environ, PKG_CONFIG_LIBDIR=str(pc), PKG_CONFIG_PATH="")
            print(f"Building {group} {arch}", flush=True)
            with (work / f"{group}-{arch}.log").open("w") as log:
                subprocess.run([str(source / "configure"), *options], cwd=build, env=env,
                               stdout=log, stderr=subprocess.STDOUT, check=True)
                targets = [f"{directory}/{directory}.a" for directory in LIBRARIES.values()]
                subprocess.run(["make", f"-j{min(os.cpu_count() or 4, 12)}", *targets],
                               cwd=build, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
                subprocess.run(["make", "install-headers"],
                               cwd=build, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
            check_license((build / "config.h").read_text(), f"{group} {arch} config.h")
            builds.append(build)
        # Headers are the same for every architecture but config.h, which is
        # vended for verify() and describes the group's first architecture.
        primary = builds[0]
        for name, directory in LIBRARIES.items():
            framework = work / "frameworks" / group / f"{name}.framework"
            if framework.exists():
                shutil.rmtree(framework)
            framework.mkdir(parents=True)
            run(["lipo", "-create", *[build / directory / f"{directory}.a" for build in builds],
                 "-output", framework / name])
            # Upstream's own public header set for this library, as `make
            # install-headers` lays it out; their includes of each other resolve
            # across the four frameworks.
            shutil.copytree(primary / "install/include" / directory, framework / "Headers")
            shutil.copyfile(primary / "config.h", framework / "Headers/config.h")
            shutil.copyfile(primary / "config_components.h", framework / "Headers/config_components.h")
            (framework / "Modules").mkdir()
            excludes = "".join(f'    exclude header "{header}"\n' for header in MODULE_EXCLUDES.get(name, ())
                               if (framework / "Headers" / header).exists())
            (framework / "Modules/module.modulemap").write_text(
                f'framework module {name} [system] {{\n    umbrella "."\n{excludes}    export *\n}}\n')
            info = dict(CFBundleExecutable=name, CFBundleIdentifier=f"ee.helop.{name}",
                        CFBundleName=name, CFBundlePackageType="FMWK", CFBundleVersion=VERSION,
                        CFBundleShortVersionString=VERSION, CFBundleSupportedPlatforms=[platform],
                        MinimumOSVersion="100.0", CFBundleInfoDictionaryVersion="6.0")
            (framework / "Info.plist").write_bytes(plistlib.dumps(info))
            frameworks[name] += ["-framework", str(framework)]

    args.output.mkdir(parents=True, exist_ok=True)
    for name in LIBRARIES:
        output = (args.output / f"{name}.xcframework").resolve()
        if output.exists():
            shutil.rmtree(output)
        run(["xcodebuild", "-create-xcframework", *frameworks[name], "-output", output])
        for license_name in ("COPYING.LGPLv2.1", "LICENSE.md"):
            shutil.copyfile(source / license_name, output / license_name)
        metadata = dict(source_url=SOURCE_URL, source_sha256=SOURCE_SHA, network=False, license="LGPL-2.1-or-later",
                        patches={patch.name: sha(patch) for patch in PATCHES},
                        dependencies=dependency_versions,
                        xcode=run(["xcodebuild", "-version"]), configurations=configurations,
                        files={str(path.relative_to(output)): sha(path) for path in sorted(output.rglob("*")) if path.is_file()})
        (output / "BUILD.json").write_text(json.dumps(metadata, indent=2) + "\n")
        verify(output, work)


if __name__ == "__main__":
    main()
