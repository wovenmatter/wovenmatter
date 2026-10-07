#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf '%s\n' 'usage: publish-release.sh [--verify-only | --approved-notes FILE] vX.Y.Z EXPECTED_COMMIT_SHA' >&2
  exit 64
}

verify_only=true
approved_notes=""
case "${1:-}" in
  --verify-only) shift ;;
  --approved-notes)
    [ "$#" -ge 2 ] || usage
    approved_notes="$2"
    verify_only=false
    shift 2
    ;;
esac

[ "$#" -eq 2 ] || usage
tag="$1"
expected_sha="$2"
repository="wovenmatter/wovenmatter"

[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage
[[ "$expected_sha" =~ ^[0-9a-f]{40}$ ]] || usage

# Snapshot the approved description before changing directory or contacting GitHub.
# The operator must obtain Trey's approval; this flag is an explicit attestation.
notes_snapshot="$(mktemp)"
trap 'rm -f "$notes_snapshot"' EXIT
if ! "$verify_only"; then
  [ -f "$approved_notes" ] || { printf '%s\n' 'Approved notes file is required.' >&2; exit 65; }
  cp "$approved_notes" "$notes_snapshot"
  python3 - "$notes_snapshot" <<'PYNOTES'
from pathlib import Path
import sys
body = Path(sys.argv[1]).read_text(encoding="utf-8").strip()
if not body or body == "Signed and notarized Apple Silicon release.":
    sys.exit("Release description must not be empty or the workflow placeholder.")
PYNOTES
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$repo_root"

export GH_HOST=github.com
export GH_PROMPT_DISABLED=1
export GH_BROWSER=/usr/bin/false
scripts/check-release-access.sh

git fetch origin main --tags
local_tag_sha="$(git rev-parse "${tag}^{commit}")"
test "$local_tag_sha" = "$expected_sha" \
  || { printf '%s does not resolve to expected commit %s.\n' "$tag" "$expected_sha" >&2; exit 65; }

remote_tag_sha="$(git ls-remote --tags origin "refs/tags/${tag}^{}" | awk 'NR == 1 { print $1 }')"
if [ -z "$remote_tag_sha" ]; then
  remote_tag_sha="$(git ls-remote --tags origin "refs/tags/${tag}" | awk 'NR == 1 { print $1 }')"
fi
test "$remote_tag_sha" = "$expected_sha" \
  || { printf 'Remote %s does not resolve to expected commit %s.\n' "$tag" "$expected_sha" >&2; exit 65; }
git merge-base --is-ancestor "$expected_sha" origin/main \
  || { printf '%s is not an accepted main commit.\n' "$expected_sha" >&2; exit 65; }

release_json="$(gh release view "$tag" --repo "$repository" \
  --json tagName,name,isDraft,isPrerelease,assets)"
is_draft="$(jq -r '.isDraft' <<<"$release_json")"
test "$is_draft" = "true" \
  || { printf '%s is not a private draft; refusing publication.\n' "$tag" >&2; exit 65; }

version="${tag#v}"
expected_asset="WovenMatter_${version}_arm64.dmg"
expected_assets="$(printf '%s\n' SHA256SUMS.txt "$expected_asset" latest-mac.json | sort)"
actual_assets="$(jq -r '.assets[].name' <<<"$release_json" | sort)"
test "$actual_assets" = "$expected_assets" \
  || { printf '%s has an unexpected release asset set.\n' "$tag" >&2; exit 65; }

release_runs="$(gh run list --repo "$repository" --workflow release.yml \
  --event push --branch "$tag" --limit 20 \
  --json headSha,status,conclusion,url)"
release_run_url="$(jq -r --arg sha "$expected_sha" '
  map(select(
    .headSha == $sha
    and .status == "completed"
    and .conclusion == "success"
  )) | first | .url // empty
' <<<"$release_runs")"
test -n "$release_run_url" \
  || { printf 'No successful Release workflow found for %s at %s.\n' "$tag" "$expected_sha" >&2; exit 65; }

# Identify bytes independently of tag/asset names. Notes edits do not invalidate
# this identity; replacing an asset changes its ID/digest and forces a download.
asset_identity() {
  gh api "repos/$repository/releases/tags/$tag" | jq -ce --arg tag "$tag" --arg sha "$expected_sha" '
    select(.tag_name == $tag and .draft == true)
    | {tag: .tag_name, source: $sha, release_id: .id,
       assets: (.assets | map({id, name, size, digest, updated_at, state}) | sort_by(.name))}
  '
}
identity="$(asset_identity)"
jq -e --arg asset "$expected_asset" '
  (.assets | map(.name)) == ["SHA256SUMS.txt", $asset, "latest-mac.json"]
' <<<"$identity" >/dev/null
cacheable=false
if jq -e '.assets | all(.state == "uploaded" and (.id | type == "number")
  and (.size | type == "number") and ((.digest // "") | test("^sha256:[0-9a-f]{64}$")))' <<<"$identity" >/dev/null; then
  cacheable=true
fi
matches_remote_assets() {
  (cd "$1" && jq -r '.assets[] | (.digest | ltrimstr("sha256:")) + "  " + .name' <<<"$identity" | shasum -a 256 -c -)
}

temporary="$(mktemp -d "${TMPDIR:-/tmp}/wovenmatter-publish-${version}.XXXXXX")"
trap 'rm -rf "$temporary"; rm -f "$notes_snapshot"' EXIT
payload="$temporary"
cache_root="${WOVENMATTER_PUBLISH_CACHE_DIR:-${TMPDIR:-/tmp}/wovenmatter-verified-downloads}"
cache_key="$(printf '%s' "$identity" | shasum -a 256 | awk '{ print $1 }')"
cache_dir="$cache_root/$cache_key"
if "$cacheable" && [ -d "$cache_dir" ] && matches_remote_assets "$cache_dir" >/dev/null 2>&1; then
  payload="$cache_dir"
  printf '%s\n' 'Reusing exact-identity downloaded assets; rechecking signatures and Gatekeeper.'
else
  gh release download "$tag" --repo "$repository" --dir "$payload"
fi
if "$cacheable"; then matches_remote_assets "$payload"; fi

(
  cd "$payload"
  shasum -a 256 -c SHA256SUMS.txt
)

dmg="${payload}/${expected_asset}"
manifest="${payload}/latest-mac.json"
dmg_sha="$(shasum -a 256 "$dmg" | awk '{ print $1 }')"
jq -e \
  --arg version "$version" \
  --arg asset "$expected_asset" \
  --arg sha "$dmg_sha" '
    .schema_version == 1
    and .version == $version
    and (.build | type == "number" and . > 0)
    and .architecture == "arm64"
    and .minimum_macos == "26.0"
    and .download_url == ("https://github.com/wovenmatter/wovenmatter/releases/download/v" + $version + "/" + $asset)
    and .release_url == ("https://github.com/wovenmatter/wovenmatter/releases/tag/v" + $version)
    and .sha256 == $sha
  ' "$manifest" >/dev/null

codesign --verify --verbose=2 "$dmg"
codesign -dvv "$dmg" 2>&1 | grep -F 'Authority=Developer ID Application:' >/dev/null
xcrun stapler validate "$dmg"
gatekeeper_result="$(spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg" 2>&1)"
grep -Fq 'accepted' <<<"$gatekeeper_result"
grep -Fq 'source=Notarized Developer ID' <<<"$gatekeeper_result"

# Reject a draft asset replacement during verification, including on cache hits.
test "$(asset_identity)" = "$identity" \
  || { printf '%s\n' 'Release asset identity changed during verification.' >&2; exit 65; }
if "$cacheable" && [ "$payload" = "$temporary" ]; then
  (umask 077; mkdir -p "$cache_dir")
  mv "$payload/$expected_asset" "$payload/latest-mac.json" "$payload/SHA256SUMS.txt" "$cache_dir/"
fi

printf 'Verified private release %s at %s.\n' "$tag" "$expected_sha"
printf 'Release workflow: %s\n' "$release_run_url"
if "$verify_only"; then
  printf '%s\n' 'Release remains private. Present the description to Trey and wait for explicit approval before using --approved-notes.'
  exit 0
fi

gh release edit "$tag" --repo "$repository" --notes-file "$notes_snapshot" --draft=false >/dev/null
public_release="$(gh release view "$tag" --repo "$repository" \
  --json tagName,isDraft,publishedAt,url)"
jq -e --arg tag "$tag" '
  .tagName == $tag
  and .isDraft == false
  and .publishedAt != null
' <<<"$public_release" >/dev/null

printf 'Published %s\n' "$(jq -r '.url' <<<"$public_release")"
