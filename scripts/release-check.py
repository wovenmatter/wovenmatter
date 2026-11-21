#!/usr/bin/env python3
"""Pre-release dependency report for a desktop release, run on a maintainer Mac
(never on GitHub).

Lists every top-level package the Mac app ships or builds with that is behind
its upstream stable release: the direct npm dependencies of each project, the
directly declared Swift packages, and the runtime records (Node, npm, CEF,
Sparkle, Cua Driver, Docker Engine, the bot images' Ubuntu, Node and
Playwright, the Mac VM guest, the Swift toolchain and SQLite the Linux server
is built with, Lucide, and the exact-pinned GitHub Actions). Packages are
taken as upstream ships them, so what they pin themselves is not listed.
Also lists known vulnerabilities in what ships (npm audit of production
dependencies, OSV for Swift packages, newer Node security releases), and
copies of one selection that disagree. iPhone-only packages (`ios/`) are out
of scope. Changes nothing; prints a Markdown report.
"""
import json
from pathlib import Path
import re
import subprocess
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
LOCKFILES = ['default-agent', 'bots', 'harnesses/npm-runtime']
SWIFT_GRAPHS = ['app/Package.resolved', 'server/Package.resolved', 'library/Package.resolved']
SWIFT_MANIFESTS = ['server/Package.swift', 'library/Package.swift']
PINNED_ACTIONS = ['.github/workflows/release.yml', '.github/workflows/pr-author.yml']

def get(url, payload=None):
    data = None if payload is None else json.dumps(payload).encode()
    request = urllib.request.Request(url, data=data, headers={'User-Agent': 'release-check',
                                                              'Content-Type': 'application/json'})
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read()

def fetch(url, payload=None):
    return json.loads(get(url, payload))

def text(url):
    return get(url).decode()

def record(path):
    return json.loads((ROOT / path).read_text())

def npm(folder, *args):
    result = subprocess.run(['npm', *args, '--package-lock-only', '--json'], cwd=ROOT / folder,
                            capture_output=True, text=True)
    return json.loads(result.stdout or '{}')

def numeric(version):
    return tuple(int(part) for part in re.findall(r'\d+', version)[:3])

def every_number(version):
    return tuple(int(part) for part in re.findall(r'\d+', version))

def tags(url, pattern):
    """Stable tags of a Git repository whose whole name matches `pattern`, by its first group."""
    output = subprocess.run(['git', 'ls-remote', '--tags', '--refs', url], capture_output=True, text=True).stdout
    return [m[1] for t in output.split() if (m := re.fullmatch('refs/tags/' + pattern, t))]

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
    direct = {url.removesuffix('.git').lower() for manifest in SWIFT_MANIFESTS
              for url in re.findall(r'\.package\(url: "([^"]+)"', (ROOT / manifest).read_text())}
    pins = {}
    for graph in SWIFT_GRAPHS:
        for pin in record(graph)['pins']:
            if pin['state'].get('version') and pin['location'].removesuffix('.git').lower() in direct:
                pins.setdefault((pin['identity'], pin['state']['version']), (pin['location'], []))[1].append(graph)
    queries = []
    for (identity, version), (url, graphs) in sorted(pins.items()):
        stable = tags(url, r'v?(\d+\.\d+\.\d+)')
        latest = max(stable, key=numeric) if stable else None
        if latest and numeric(version) < numeric(latest):
            outdated.append(f'Swift `{identity}` in {", ".join(f"`{g}`" for g in graphs)}: {version} → {latest}')
        queries.append((identity, {'package': {'ecosystem': 'SwiftURL', 'name': url}, 'version': version}))
    if queries:
        results = fetch('https://api.osv.dev/v1/querybatch', {'queries': [q for _, q in queries]})['results']
        for (name, query), result in zip(queries, results):
            for vuln in result.get('vulns', []):
                vulnerable.append(f'Swift `{name}` {query["version"]}: {vuln["id"]} (see https://osv.dev/vulnerability/{vuln["id"]})')

def node_section(outdated, vulnerable):
    node = (ROOT / 'default-agent/.node-version').read_text().strip()
    releases = [r for r in fetch('https://nodejs.org/dist/index.json')
                if re.fullmatch(r'v\d+\.\d+\.\d+', r['version'])]
    latest = releases[0]['version'].lstrip('v')
    if numeric(node) < numeric(latest):
        outdated.append(f'Node (Mac app and Linux server): {node} → {latest}')
    security = [r['version'].lstrip('v') for r in releases
                if r.get('security') and numeric(r['version']) > numeric(node)
                and numeric(r['version'])[0] == numeric(node)[0]]
    if security:
        vulnerable.append(f'**security** Node {node} (ships): newer security releases {", ".join(security)}')
    npm_record = record('harnesses/npm-version.json')['version']
    newest = fetch('https://registry.npmjs.org/npm/latest')['version']
    if numeric(npm_record) < numeric(newest):
        outdated.append(f'npm (bundled tooling, `harnesses/npm-version.json`): {npm_record} → {newest}')

def mac_section(outdated, vulnerable):
    cef = record('app/Browser/cef-version.json')
    builds = fetch('https://cef-builds.spotifycdn.com/index.json')['macosarm64']['versions']
    stable = next(v['cef_version'] for v in builds if v['channel'] == 'stable')
    if stable != cef['version']:
        outdated.append(f'CEF/Chromium (bundled): {cef["version"]} → {stable}')
        vulnerable.append(f'**security** Chromium {cef["chromium"]} (ships): behind stable '
                          f'{stable.split("chromium-")[-1]}; Chromium stable updates usually carry security fixes')
    sparkle = record('app/Updater/sparkle-version.json')['version']
    newest = fetch('https://api.github.com/repos/sparkle-project/Sparkle/releases/latest')['tag_name']
    if numeric(sparkle) < numeric(newest):
        outdated.append(f'Sparkle (bundled): {sparkle} → {newest}')
    cua = record('app/Automation/cua-version.json')['version']
    # A published release with the universal executable, not a bare tag: tags appear before their assets.
    stable = [m[1] for r in fetch('https://api.github.com/repos/trycua/cua/releases?per_page=100')
              if not r['draft'] and (m := re.fullmatch(r'cua-driver-rs-v(\d+\.\d+\.\d+)', r['tag_name']))
              and any(a['name'] == f'cua-driver-rs-{m[1]}-darwin-universal-binary.tar.gz' for a in r['assets'])]
    newest = max(stable, key=numeric) if stable else cua
    if numeric(cua) < numeric(newest):
        outdated.append(f'Cua Driver (bundled): {cua} → {newest}')

def vm_guest_section(outdated, vulnerable):
    guest = record('app/VMHelper/guest-version.json')
    image = guest['image']
    suite_url = image['url'].rsplit('/release-', 1)[0] + '/'
    serials = re.findall(r'href="release-(\d{8})/"', text(suite_url))
    if serials and max(serials) > image['serial']:
        outdated.append(f'VM guest Ubuntu cloud image: {image["serial"]} → {max(serials)}')
    docker = guest['docker']
    packages = text(f'{docker["repository"]}/dists/{docker["suite"]}/stable/binary-arm64/Packages')
    for package, key in (('docker-ce', 'dockerCE'), ('containerd.io', 'containerd')):
        versions = re.findall(rf'^Package: {re.escape(package)}\n(?:[^\n]+\n)*?Version: (\S+)', packages, re.M)
        newest = max(versions, key=every_number) if versions else docker[key]
        if every_number(docker[key]) < every_number(newest):
            outdated.append(f'VM guest `{package}`: {docker[key]} → {newest}')

def linux_server_section(outdated, vulnerable):
    build = record('server/linux-build.json')
    swift = build['swiftVersion']
    releases = tags('https://github.com/swiftlang/swift.git', r'swift-(\d+\.\d+(?:\.\d+)?)-RELEASE')
    newest = max(releases, key=numeric) if releases else swift
    if numeric(swift) < numeric(newest):
        outdated.append(f'Swift toolchain and Static Linux SDK (Linux server): {swift} → {newest}')
    current = re.search(r'sqlite-amalgamation-(\d+)\.zip', build['sqliteURL'])[1]
    published = re.findall(r'sqlite-amalgamation-(\d+)\.zip', text('https://www.sqlite.org/download.html'))
    if published and int(max(published)) > int(current):
        outdated.append(f'SQLite (Linux server): {current} → {max(published)}')

def latest_release(repo):
    """Newest stable release tag of a GitHub repository and the commit it names."""
    found = {}
    for line in subprocess.run(['git', 'ls-remote', '--tags', f'https://github.com/{repo}.git'],
                               capture_output=True, text=True).stdout.splitlines():
        sha, ref = line.split('\t')
        name = ref.removeprefix('refs/tags/')
        if name.endswith('^{}'):
            found[name[:-3]] = sha
        else:
            found.setdefault(name, sha)
    stable = [t for t in found if re.fullmatch(r'v\d+\.\d+\.\d+', t)]
    newest = max(stable, key=numeric)
    return newest, found[newest]

def records_section(outdated, vulnerable):
    engine = (ROOT / 'bots/engine/bots-engine.py').read_text()
    docker = re.search(r"DOCKER_VERSION = '([^']+)'", engine)[1]
    published = re.findall(r'docker-(\d+\.\d+\.\d+)\.tgz', text('https://download.docker.com/linux/static/stable/x86_64/'))
    newest = max(published, key=numeric) if published else docker
    if numeric(docker) < numeric(newest):
        outdated.append(f'Docker Engine (Linux bot engines, `bots/engine/bots-engine.py`): {docker} → {newest}')
    guest = record('app/VMHelper/guest-version.json')['docker']['dockerCE']
    if not guest.split(':')[-1].startswith(docker + '-'):
        outdated.append(f'Mac VM `docker-ce` {guest} does not match the Docker Engine release {docker}')

    images = {path: (ROOT / path).read_text() for path in ('bots/image/Dockerfile', 'bots/image/toolchain/Dockerfile')}
    ubuntu = {re.search(r'^FROM ubuntu:(\S+)', body, re.M)[1] for body in images.values()}
    releases = re.findall(r'^Version: (\d+\.\d+)', text('https://changelogs.ubuntu.com/meta-release'), re.M)
    newest = max(releases, key=numeric) if releases else max(ubuntu)
    for current in sorted(ubuntu):
        if numeric(current) < numeric(newest):
            outdated.append(f'Ubuntu (bot images): {current} → {newest}')
    toolchain = images['bots/image/toolchain/Dockerfile']
    node = (ROOT / 'default-agent/.node-version').read_text().strip()
    image_node = re.search(r'ARG NODE_VERSION=(\S+)', toolchain)[1]
    if image_node != node:
        outdated.append(f'Node (bot toolchain image): {image_node} → {node} (`default-agent/.node-version`)')
    playwright = fetch('https://registry.npmjs.org/playwright-core/latest')['version']
    image_playwright = re.search(r'ARG PLAYWRIGHT_VERSION=(\S+)', toolchain)[1]
    if numeric(image_playwright) < numeric(playwright):
        outdated.append(f'Playwright (bot toolchain image): {image_playwright} → {playwright}')

    lucide = record('docs/assets/lucide-provenance.json')['version']
    newest = fetch('https://registry.npmjs.org/lucide-static/latest')['version']
    if numeric(lucide) < numeric(newest):
        outdated.append(f'Lucide icons (`docs/assets/lucide-provenance.json`): {lucide} → {newest}')

    for workflow in PINNED_ACTIONS:
        for repo, sha, tag in re.findall(r'uses: ([\w-]+/[\w-]+)@([0-9a-f]{40}) # (\S+)', (ROOT / workflow).read_text()):
            newest, commit = latest_release(repo)
            if commit != sha:
                outdated.append(f'GitHub Action `{repo}` in `{workflow}`: {tag} → {newest}')

    swift = record('server/linux-build.json')['swiftVersion']
    container = re.search(r'container: swift:(\S+?)-', (ROOT / '.github/workflows/ci.yml').read_text())[1]
    if container != swift:
        outdated.append(f'PR CI Swift container {container} does not match the Linux server toolchain {swift}')

def main():
    outdated, vulnerable = [], []
    for section in (npm_section, swift_section, node_section, mac_section, vm_guest_section,
                    linux_server_section, records_section):
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
