#!/usr/bin/env python3
"""Pre-release dependency report, run on a maintainer Mac (never on GitHub).

Lists what is behind upstream stable releases (npm lockfiles, Swift packages,
and the Node, CEF and Sparkle runtime records) and known vulnerabilities in
what ships (npm audit of production dependencies, OSV for Swift packages,
newer Node security releases). Changes nothing; prints a Markdown report.
"""
import json
from pathlib import Path
import re
import subprocess
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
LOCKFILES = ['default-agent', 'bots', 'remote/npm-runtime', 'remote/executor-runtime', 'ios/EmbeddedRuntime']

def fetch(url, payload=None):
    data = None if payload is None else json.dumps(payload).encode()
    request = urllib.request.Request(url, data=data, headers={'User-Agent': 'release-check',
                                                              'Content-Type': 'application/json'})
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)

def npm(folder, *args):
    result = subprocess.run(['npm', *args, '--package-lock-only', '--json'], cwd=ROOT / folder,
                            capture_output=True, text=True)
    return json.loads(result.stdout or '{}')

def numeric(version):
    return tuple(int(part) for part in re.findall(r'\d+', version)[:3])

def npm_section(outdated, vulnerable):
    for folder in LOCKFILES:
        lock = json.loads((ROOT / folder / 'package-lock.json').read_text())['packages']
        for name, info in sorted(npm(folder, 'outdated').items()):
            current = lock.get(f'node_modules/{name}', {}).get('version')
            latest = info.get('latest')
            if current and latest and numeric(current) < numeric(latest):
                outdated.append(f'npm `{name}` in `{folder}`: {current} → {latest}')
        for name, item in sorted(npm(folder, 'audit', '--omit=dev').get('vulnerabilities', {}).items()):
            titles = sorted({v['title'] for v in item.get('via', []) if isinstance(v, dict)})
            fix = item.get('fixAvailable')
            remedy = 'fix available' if fix else 'no fix published'
            if isinstance(fix, dict) and fix.get('isSemVerMajor'):
                remedy = f'fix needs {fix["name"]} {fix["version"]} (major)'
            vulnerable.append(f'**{item["severity"]}** npm `{name}` in `{folder}` (ships): '
                              f'{"; ".join(titles) or "via " + ", ".join(map(str, item.get("via", [])))} — {remedy}')

def swift_section(outdated, vulnerable):
    pins = json.loads((ROOT / 'app/Package.resolved').read_text())['pins']
    queries = []
    for pin in pins:
        version, url = pin['state'].get('version'), pin['location']
        tags = subprocess.run(['git', 'ls-remote', '--tags', '--refs', url], capture_output=True, text=True).stdout
        stable = [t.rsplit('/', 1)[1] for t in tags.split() if re.fullmatch(r'refs/tags/v?\d+\.\d+\.\d+', t)]
        latest = max(stable, key=numeric) if stable else None
        if version and latest and numeric(version) < numeric(latest):
            outdated.append(f'Swift `{pin["identity"]}`: {version} → {latest}')
        if version:
            queries.append((pin['identity'], {'package': {'ecosystem': 'SwiftURL', 'name': url}, 'version': version}))
    if queries:
        results = fetch('https://api.osv.dev/v1/querybatch', {'queries': [q for _, q in queries]})['results']
        for (name, query), result in zip(queries, results):
            for vuln in result.get('vulns', []):
                vulnerable.append(f'Swift `{name}` {query["version"]}: {vuln["id"]} (see https://osv.dev/vulnerability/{vuln["id"]})')

def runtime_section(outdated, vulnerable):
    node = (ROOT / 'default-agent/.node-version').read_text().strip()
    releases = [r for r in fetch('https://nodejs.org/dist/index.json')
                if re.fullmatch(r'v\d+\.\d+\.\d+', r['version'])]
    latest = releases[0]['version'].lstrip('v')
    if numeric(node) < numeric(latest):
        outdated.append(f'Node (bundled): {node} → {latest}')
    security = [r['version'].lstrip('v') for r in releases
                if r.get('security') and numeric(r['version']) > numeric(node)
                and numeric(r['version'])[0] == numeric(node)[0]]
    if security:
        vulnerable.append(f'**security** Node {node} (ships): newer security releases {", ".join(security)}')
    cef = json.loads((ROOT / 'app/Browser/cef-version.json').read_text())
    builds = fetch('https://cef-builds.spotifycdn.com/index.json')['macosarm64']['versions']
    stable = next(v['cef_version'] for v in builds if v['channel'] == 'stable')
    if stable != cef['version']:
        outdated.append(f'CEF/Chromium (bundled): {cef["version"]} → {stable}')
        vulnerable.append(f'**security** Chromium {cef["chromium"]} (ships): behind stable '
                          f'{stable.split("chromium-")[-1]}; Chromium stable updates usually carry security fixes')
    sparkle = json.loads((ROOT / 'app/Updater/sparkle-version.json').read_text())['version']
    newest = fetch('https://api.github.com/repos/sparkle-project/Sparkle/releases/latest')['tag_name']
    if numeric(sparkle) < numeric(newest):
        outdated.append(f'Sparkle (bundled): {sparkle} → {newest}')

def main():
    outdated, vulnerable = [], []
    for section in (npm_section, swift_section, runtime_section):
        try:
            section(outdated, vulnerable)
        except Exception as error:  # report a lookup failure instead of a false all-clear
            vulnerable.append(f'**check failed** {section.__name__}: {error}')
    revision = subprocess.run(['git', 'rev-parse', '--short', 'HEAD'], cwd=ROOT, capture_output=True, text=True).stdout.strip()
    print(f'# Release dependency check ({revision})\n')
    print(f'## Outdated ({len(outdated)})\n')
    print('\n'.join(f'- {line}' for line in outdated) or 'Everything is current.')
    print(f'\n## Known vulnerabilities in shipped code ({len(vulnerable)})\n')
    print('\n'.join(f'- {line}' for line in vulnerable) or 'None found.')

if __name__ == '__main__':
    main()
