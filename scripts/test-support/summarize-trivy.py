#!/usr/bin/env python3
"""Print complete vulnerability counts and reject high-risk language packages."""

import collections
import json
from pathlib import Path
import sys


def summarize(path: Path) -> tuple[dict[str, int], list[dict]]:
    document = json.loads(path.read_text())
    counts: collections.Counter[str] = collections.Counter()
    language_high_risk: list[dict] = []
    for result in document.get("Results") or []:
        for vulnerability in result.get("Vulnerabilities") or []:
            severity = vulnerability.get("Severity", "UNKNOWN").upper()
            counts[severity] += 1
            if result.get("Class") == "lang-pkgs" and severity in {"HIGH", "CRITICAL"}:
                language_high_risk.append({
                    "target": result.get("Target"),
                    "type": result.get("Type"),
                    "id": vulnerability.get("VulnerabilityID"),
                    "package": vulnerability.get("PkgName"),
                    "installed": vulnerability.get("InstalledVersion"),
                    "fixed": vulnerability.get("FixedVersion"),
                    "severity": severity,
                })
    return dict(counts), language_high_risk


def main() -> int:
    if len(sys.argv) < 2:
        raise SystemExit("usage: summarize-trivy.py report.json [report.json ...]")
    rejected: list[dict] = []
    for value in sys.argv[1:]:
        path = Path(value)
        counts, language_high_risk = summarize(path)
        ordered = {severity: counts.get(severity, 0)
                   for severity in ("CRITICAL", "HIGH", "MEDIUM", "LOW", "UNKNOWN")}
        print(json.dumps({"image": path.stem, "vulnerabilities": ordered}, sort_keys=True))
        rejected.extend(language_high_risk)
    if rejected:
        print(json.dumps({"highRiskLanguagePackages": rejected}, indent=2), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
