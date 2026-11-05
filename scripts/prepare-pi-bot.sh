#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
[ "$#" -eq 1 ] || { echo 'usage: scripts/prepare-pi-bot.sh OUTPUT' >&2; exit 64; }
output="$1"
selection="$repo_root/pi-bot/selection.json"
source_override="${WOVENMATTER_PI_BOT_SOURCE:-}"
if [ -n "$source_override" ] && [ "${CONFIGURATION:-Debug}" = Release ]; then
  echo 'WOVENMATTER_PI_BOT_SOURCE is forbidden in Release builds.' >&2; exit 64
fi
arch="${CURRENT_ARCH:-$(uname -m)}"
if [ "$arch" = undefined_arch ]; then arch="${NATIVE_ARCH_ACTUAL:-$(uname -m)}"; fi
case "$arch" in arm64|aarch64) node_arch=arm64 ;; x86_64|x64) node_arch=x64 ;; *) echo "Unsupported Pi Bot architecture: $arch" >&2; exit 1 ;; esac
case "$(uname -s)" in Darwin) node_os=darwin ;; Linux) node_os=linux ;; *) echo 'Unsupported Pi Bot build host.' >&2; exit 1 ;; esac
# Read the small record before bootstrapping Node, as prepare-default-agent does.
version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["node"]["version"])' "$selection")"
checksum="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["node"]["sha256"][sys.argv[2]])' "$selection" "$node_os-$node_arch")"
cache="${TMPDIR:-/tmp}/wovenmatter-node-$version-$node_arch"
if [ "$node_os" != darwin ]; then cache="$cache-$node_os"; fi
if [ ! -x "$cache/bin/node" ]; then
  archive="$(python3 "$repo_root/scripts/cached-download.py" "https://nodejs.org/dist/v$version/node-v$version-$node_os-$node_arch.tar.gz" sha256 "$checksum")"
  node_stage="$(mktemp -d)"
  trap 'rm -rf "$node_stage"' EXIT
  tar -xzf "$archive" --strip-components=1 -C "$node_stage"
  mkdir -p "$(dirname "$cache")"
  mv "$node_stage" "$cache"
  trap - EXIT
fi
export PATH="$cache/bin:$PATH"
commit="$(node -p 'require(process.argv[1]).commit' "$selection")"
repository="$(node -p 'require(process.argv[1]).repository' "$selection")"
[[ "$commit" =~ ^[a-f0-9]{40}$ ]] || { echo 'Pi Bot selection requires a full commit SHA.' >&2; exit 65; }
[ "$repository" = https://github.com/wovenmatter/pi-bot.git ] || { echo 'Unexpected Pi Bot repository.' >&2; exit 65; }
work="$(mktemp -d "${TMPDIR:-/tmp}/wovenmatter-pi-bot-build.XXXXXX")"
trap 'rm -rf "$work"' EXIT
if [ -n "$source_override" ]; then
  source_root="$(cd "$source_override" && pwd -P)"
  commit="$(git -C "$source_root" rev-parse HEAD)"
else
  source_root="$work/source"
  git init -q "$source_root"
  git -C "$source_root" remote add origin "$repository"
  git -C "$source_root" -c credential.helper= fetch --depth 1 origin "$commit" >&2
  git -C "$source_root" checkout -q --detach FETCH_HEAD
fi
if ! node -e 'if (!JSON.parse(require("node:fs").readFileSync(process.argv[1])).scripts?.["package:woven"]) process.exit(1)' "$source_root/package.json"; then
  printf 'Pi Bot commit %s has no package:woven script; update pi-bot/selection.json after the packaging change merges.\n' "$commit" >&2
  exit 65
fi
# Fingerprint and copy tracked plus nonignored source files, including dirty and
# newly added files. Dependencies and build caches never enter the checkout.
fingerprint="$(node - "$source_root" "$work/tree" "$selection" "$repo_root/pi-bot/tooling" "$0" <<'JS'
const fs = require('node:fs'), path = require('node:path'), crypto = require('node:crypto'), cp = require('node:child_process');
const [source, target, selection, tooling, script] = process.argv.slice(2);
const hash = crypto.createHash('sha256');
const files = [...new Set(cp.execFileSync('git', ['-C', source, 'ls-files', '--cached', '--others', '--exclude-standard', '-z']).toString().split('\0').filter(Boolean))].sort();
fs.mkdirSync(target);
for (const name of files) {
  if (name.split('/').some(part => ['.git', 'node_modules', '.DS_Store'].includes(part)) || /(^|\/)\.env($|\.)/.test(name)) continue;
  const file = path.join(source, name);
  if (!fs.existsSync(file)) { hash.update(name + '\0deleted\0'); continue; }
  const stat = fs.lstatSync(file);
  if (!stat.isFile()) throw Error('Pi Bot source must contain regular files: ' + name);
  const content = fs.readFileSync(file);
  hash.update(name + '\0' + (stat.mode & 0o111) + '\0').update(content);
  const destination = path.join(target, name);
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  fs.writeFileSync(destination, content, { mode: stat.mode & 0o777 });
}
for (const file of [selection, path.join(tooling, 'package.json'), path.join(tooling, 'package-lock.json'), script]) hash.update(fs.readFileSync(file));
console.log(hash.digest('hex'));
JS
)"
# HEAD does not identify uncommitted source, so a Debug build of it names its content.
# Otherwise a rebuild would look already installed, or conflict with what is.
if [ -n "$source_override" ] && [ -n "$(git -C "$source_root" status --porcelain)" ]; then
  commit="$(printf '%s' "$fingerprint" | cut -c1-40)"
  export PI_BOT_PACKAGE_COMMIT="$commit"
fi
key="$commit-$version-$node_os-$node_arch-$fingerprint"
dependency_root="${TMPDIR:-/tmp}/wovenmatter-pi-bot-dependencies-$key"
# Every producer owns a unique stage; a completed cache contains no dependencies.
if [ ! -f "$dependency_root/pi-bot-bundle.tar.gz" ]; then
  mkdir "$work/tooling"
  cp "$repo_root/pi-bot/tooling/package.json" "$repo_root/pi-bot/tooling/package-lock.json" "$work/tooling/"
  (cd -P "$work/tooling" && npm ci --no-audit --no-fund) >&2
  export PATH="$work/tooling/node_modules/.bin:$PATH"
  (
    cd -P "$work/tree"
    pnpm install --frozen-lockfile --store-dir "${TMPDIR:-/tmp}/wovenmatter-pi-bot-pnpm-store"
    # Packaging may ask Git for the revision; the copied source has no .git or
    # dependency links back into a possibly cloud-synced worktree.
    GIT_DIR="$(git -C "$source_root" rev-parse --absolute-git-dir)" GIT_WORK_TREE="$work/tree" pnpm package:woven --out "$work/pi-bot-bundle.tar.gz"
  ) >&2
  node - "$work/pi-bot-bundle.tar.gz" "$work/manifest.json" "$commit" <<'JS'
const fs = require('node:fs'), cp = require('node:child_process');
const [bundle, output, commit] = process.argv.slice(2);
const manifest = JSON.parse(cp.execFileSync('tar', ['-xOzf', bundle, 'manifest.json']));
if (manifest.commit !== commit || manifest.protocol !== 1) throw Error('Pi Bot bundle manifest does not match the selected source/protocol.');
fs.writeFileSync(output, JSON.stringify(manifest));
JS
  mkdir -p "$dependency_root"
  cp "$work/pi-bot-bundle.tar.gz" "$dependency_root/.bundle-$$.tar.gz"
  mv "$dependency_root/.bundle-$$.tar.gz" "$dependency_root/pi-bot-bundle.tar.gz"
fi
mkdir -p "$output/tooling"
cp "$dependency_root/pi-bot-bundle.tar.gz" "$output/"
node - "$selection" "$output/selection.json" "$commit" <<'JS'
const fs = require('node:fs');
const record = JSON.parse(fs.readFileSync(process.argv[2]));
record.commit = process.argv[4];
fs.writeFileSync(process.argv[3], JSON.stringify(record, null, 2) + '\n');
JS
cp -p "$repo_root/scripts/pi-bot-host.sh" "$output/pi-bot-host.sh"
cp "$repo_root/pi-bot/tooling/package.json" "$repo_root/pi-bot/tooling/package-lock.json" "$output/tooling/"
