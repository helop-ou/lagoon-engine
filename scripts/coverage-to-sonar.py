#!/usr/bin/env python3
"""Writes a test run's engine coverage as SonarQube generic coverage.

    scripts/coverage-to-sonar.py tvOS   # build/TestResults.xcresult to build/coverage-tvOS.xml

Paths are fixed and the platform comes from a list, so nothing from the
command line reaches the file system or xccov.

Only the package sources are kept. Sonar ignores coverage for test files.
"""
import json
import subprocess
import sys
from pathlib import Path
from xml.sax.saxutils import quoteattr

SOURCE_ROOTS = ("Sources",)
ROOT = Path(__file__).resolve().parent.parent
RESULT = ROOT / "build" / "TestResults.xcresult"
OUTPUTS = {
    "tvOS": ROOT / "build" / "coverage-tvOS.xml",
    "iOS": ROOT / "build" / "coverage-iOS.xml",
}


def main() -> None:
    platform = sys.argv[1] if len(sys.argv) == 2 else ""
    if platform not in OUTPUTS:
        sys.exit(f"usage: coverage-to-sonar.py <{'|'.join(OUTPUTS)}>")
    output = OUTPUTS[platform]
    archive = json.loads(subprocess.run(
        ["xcrun", "xccov", "view", "--archive", "--json", str(RESULT)],
        check=True, capture_output=True, text=True,
    ).stdout)

    lines = ['<coverage version="1">']
    files = 0
    for path in sorted(archive):
        try:
            relative = Path(path).resolve().relative_to(ROOT)
        except ValueError:
            continue
        if relative.parts[0] not in SOURCE_ROOTS:
            continue
        executable = [line for line in archive[path] if line.get("isExecutable")]
        if not executable:
            continue
        files += 1
        lines.append(f"  <file path={quoteattr(relative.as_posix())}>")
        for line in executable:
            covered = "true" if line.get("executionCount", 0) > 0 else "false"
            lines.append(f'    <lineToCover lineNumber="{line["line"]}" covered="{covered}"/>')
        lines.append("  </file>")
    lines.append("</coverage>")

    if files == 0:
        sys.exit(f"error: {RESULT} has no coverage for {', '.join(SOURCE_ROOTS)}")
    output.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"wrote {output.relative_to(ROOT)} ({files} files)")


if __name__ == "__main__":
    main()
