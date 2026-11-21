#!/usr/bin/env python3
"""Check every shipped Mach-O image before submitting a release to Apple."""
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import zipfile

MAGIC = {bytes.fromhex(value) for value in (
    "feedface", "cefaedfe", "feedfacf", "cffaedfe",
    "cafebabe", "bebafeca", "cafebabf", "bfbafeca",
)}

ARCHIVES = (".tar", ".tar.gz", ".tgz", ".tar.xz", ".zip")

def archived_mach_o(path):
    """Mach-O members of an archive: Apple's notary scans inside archives, and they cannot be signed there."""
    if path.name.endswith(".zip"):
        with zipfile.ZipFile(path) as archive:
            for member in archive.infolist():
                if not member.is_dir():
                    with archive.open(member) as source:
                        if source.read(4) in MAGIC:
                            yield member.filename
        return
    with tarfile.open(path) as archive:
        for member in archive:
            if member.isfile():
                with archive.extractfile(member) as source:
                    if source.read(4) in MAGIC:
                        yield member.name

def validate(bundle):
    failures = []
    count = 0
    for path in sorted(bundle.rglob("*")):
        if path.is_symlink() or not path.is_file():
            continue
        if path.name.endswith(ARCHIVES):
            failures += [f"{path.relative_to(bundle)}: archive holds Mach-O {name}" for name in archived_mach_o(path)]
            continue
        with path.open("rb") as source:
            if source.read(4) not in MAGIC:
                continue
        count += 1
        verification = subprocess.run(["codesign", "--verify", "--strict", str(path)], capture_output=True, text=True)
        details = subprocess.run(["codesign", "-dvvv", str(path)], capture_output=True, text=True)
        signature = details.stdout + details.stderr
        kind = subprocess.run(["file", "-b", str(path)], capture_output=True, text=True, check=True).stdout
        reasons = []
        if verification.returncode or details.returncode:
            reasons.append("invalid signature")
        if "Authority=Developer ID Application:" not in signature:
            reasons.append("missing Developer ID signature")
        if not any(line.startswith("Timestamp=") for line in signature.splitlines()):
            reasons.append("missing secure timestamp")
        flags = re.search(r"CodeDirectory[^\n]*flags=0x([0-9a-fA-F]+)", signature)
        hardened = bool(flags and int(flags[1], 16) & 0x10000)
        if "executable" in kind and not hardened:
            reasons.append("missing hardened runtime")
        if reasons:
            failures.append(f"{path.relative_to(bundle)}: {', '.join(reasons)}")
    if not count:
        failures.append("No Mach-O images found in release bundle")
    if failures:
        raise SystemExit("Release signing validation failed:\n" + "\n".join(failures))
    print(f"Release signing validation passed for {count} Mach-O images.")

if __name__ == "__main__":
    if len(sys.argv) != 2 or not Path(sys.argv[1]).is_dir():
        raise SystemExit("usage: validate-release-code.py APP_BUNDLE")
    validate(Path(sys.argv[1]))
