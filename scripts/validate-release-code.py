#!/usr/bin/env python3
"""Check every shipped Mach-O image before submitting a release to Apple."""
from pathlib import Path
import re
import subprocess
import sys

MAGIC = {bytes.fromhex(value) for value in (
    "feedface", "cefaedfe", "feedfacf", "cffaedfe",
    "cafebabe", "bebafeca", "cafebabf", "bfbafeca",
)}

def validate(bundle):
    failures = []
    count = 0
    for path in sorted(bundle.rglob("*")):
        if path.is_symlink() or not path.is_file():
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
