#!/usr/bin/env python3
"""Prints an xcodebuild destination for the first named simulator that can run.

    scripts/pick-simulator.py tvOS "Apple TV 4K (4th generation)" "Apple TV 4K (3rd generation)"

A runner image can keep a device whose runtime it no longer has: simctl still
lists it, and xcodebuild then fails with "Unable to find a destination". Only
devices on an installed runtime count, newest runtime first, so the job fails
here with the devices it has rather than later without them.
"""
import json
import subprocess
import sys

PLATFORMS = {"iOS", "tvOS"}


def simctl(*arguments):
    return json.loads(subprocess.check_output(["xcrun", "simctl", "list", "-j", *arguments], text=True))


def version_key(runtime):
    return tuple(int(part) for part in runtime["version"].split(".") if part.isdigit())


def main():
    if len(sys.argv) < 3 or sys.argv[1] not in PLATFORMS:
        sys.exit(__doc__)
    platform, names = sys.argv[1], sys.argv[2:]

    runtimes = sorted(
        (runtime for runtime in simctl("runtimes")["runtimes"]
         if runtime.get("isAvailable") and runtime.get("platform") == platform),
        key=version_key,
        reverse=True,
    )
    devices = simctl("devices", "available")["devices"]
    for name in names:
        for runtime in runtimes:
            for device in devices.get(runtime["identifier"], []):
                if device.get("name") == name and device.get("isAvailable"):
                    print(f"platform={platform} Simulator,id={device['udid']}")
                    print(f"Using {name}, {platform} {runtime['version']}", file=sys.stderr)
                    return

    print(f"error: no {platform} simulator named any of {names} on an installed runtime", file=sys.stderr)
    for runtime in runtimes:
        for device in devices.get(runtime["identifier"], []):
            print(f"  {platform} {runtime['version']}: {device.get('name')}", file=sys.stderr)
    sys.exit(1)


if __name__ == "__main__":
    main()
