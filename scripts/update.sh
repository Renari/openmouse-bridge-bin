#!/usr/bin/env bash
# Bumps the package to the latest stable upstream release (or --tag TAG).
#
# Updates PKGBUILD (_tag, _nodehid, pkgver, pkgrel, sha256sums), regenerates the
# udev rule and its helper from that release's install-linux.sh, and rewrites
# .SRCINFO.
# The release archive's checksum must agree with both upstream's published
# .sha256 file and the digest GitHub recorded for the asset.
#
# Must run as a non-root user with makepkg and pacman-contrib (updpkgsums).
# Under GitHub Actions it writes `updated`, `tag` and `pkgver` to
# $GITHUB_OUTPUT and the pull request body to $PR_BODY_FILE.
set -euo pipefail

REPO="OpenMouse-Project/OpenMouse-Bridge"
API="https://api.github.com/repos/${REPO}"
# The full package; the unsuffixed linux-x64.zip is only a small stub for old
# self-updaters. Matches _asset in the PKGBUILD.
ASSET="openmouse-bridge-linux-x64-full.zip"

cd "$(dirname "$0")/.."

tag=""
force=false
while [ $# -gt 0 ]; do
  case "$1" in
    --tag) tag="${2:?--tag needs a value}"; shift 2 ;;
    --force) force=true; shift ;;
    *) echo "usage: update.sh [--tag TAG] [--force]" >&2; exit 2 ;;
  esac
done

output() { [ -z "${GITHUB_OUTPUT:-}" ] || echo "$1=$2" >>"$GITHUB_OUTPUT"; }
log() { printf '==> %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

curl_api() {
  local auth=()
  [ -z "${GITHUB_TOKEN:-}" ] || auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  curl -fsSL --retry 3 -H 'Accept: application/vnd.github+json' "${auth[@]}" "$@"
}

# pacman's vercmp sorts "1.0.0beta.20" < "1.0.0rc.1" < "1.0.0", matching semver
# pre-release order, so dropping the "v" and the "-" is enough.
tag_to_pkgver() {
  local version="${1#v}"
  version="${version//-/}"
  [[ "$version" =~ ^[0-9][0-9A-Za-z.]*$ ]] || die "cannot turn tag '$1' into a pkgver"
  printf '%s' "$version"
}

if [ -n "$tag" ]; then
  release="$(curl_api "${API}/releases/tags/${tag}")"
else
  # /releases/latest never returns drafts or pre-releases.
  release="$(curl_api "${API}/releases/latest")"
fi
tag="$(jq -r '.tag_name' <<<"$release")"
[ "$(jq -r '.draft' <<<"$release")" = false ] || die "$tag is a draft"
[ "$(jq -r '.prerelease' <<<"$release")" = false ] || [ "$force" = true ] ||
  die "$tag is a pre-release (pass --force to package it anyway)"

new_pkgver="$(tag_to_pkgver "$tag")"
current_pkgver="$(bash -c 'source ./PKGBUILD && printf %s "$pkgver"')"
log "upstream ${tag} -> pkgver ${new_pkgver} (packaged: ${current_pkgver})"
if [ "$force" != true ] && [ "$(vercmp "$new_pkgver" "$current_pkgver")" -le 0 ]; then
  log "already up to date"
  output updated false
  exit 0
fi

asset="$ASSET"
[ "$(bash -c 'source ./PKGBUILD && printf %s "$_asset"')" = "$asset" ] ||
  die "PKGBUILD _asset is not $asset"
asset_json="$(jq -c --arg n "$asset" '.assets[] | select(.name == $n)' <<<"$release")"
[ -n "$asset_json" ] || die "$tag has no $asset"
asset_url="$(jq -r '.browser_download_url' <<<"$asset_json")"
github_digest="$(jq -r '.digest // empty' <<<"$asset_json")"
github_digest="${github_digest#sha256:}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

curl -fsSL --retry 3 "${asset_url}.sha256" -o "$work/asset.sha256"
published_sum="$(awk 'NR == 1 { print $1 }' "$work/asset.sha256")"
[[ "$published_sum" =~ ^[0-9a-f]{64}$ ]] || die "could not read ${asset}.sha256"
if [ -n "$github_digest" ] && [ "$github_digest" != "$published_sum" ]; then
  die "GitHub asset digest ($github_digest) disagrees with ${asset}.sha256 ($published_sum)"
fi

zip="$work/openmouse-bridge-${new_pkgver}.zip"
curl -fsSL --retry 3 "$asset_url" -o "$zip"
downloaded_sum="$(sha256sum "$zip" | cut -d' ' -f1)"
[ "$downloaded_sum" = "$published_sum" ] ||
  die "downloaded archive hashes to $downloaded_sum, upstream published $published_sum"
bsdtar -tf "$zip" openmouse-bridge native-hid/node/bin/node >/dev/null ||
  die "$asset is missing the Bridge executable or the bundled Node.js runtime"

nodehid="$(scripts/verify-node-hid.sh "$zip" "$work")"

curl -fsSL --retry 3 "https://raw.githubusercontent.com/${REPO}/${tag}/install-linux.sh" \
  -o "$work/install-linux.sh"
scripts/gen-udev-rules.sh "$work/install-linux.sh" .

sed -i \
  -e "s|^_tag=.*|_tag=${tag}|" \
  -e "s|^_nodehid=.*|_nodehid=${nodehid}|" \
  -e "s|^pkgver=.*|pkgver=${new_pkgver}|" \
  -e "s|^pkgrel=.*|pkgrel=1|" \
  PKGBUILD

# Reuses the verified downloads in $work and rewrites every checksum; the
# archive hash must still be the one upstream published.
SRCDEST="$work" updpkgsums
pkgbuild_sum="$(bash -c 'source ./PKGBUILD && printf %s "${sha256sums[0]}"')"
[ "$pkgbuild_sum" = "$published_sum" ] ||
  die "PKGBUILD archive checksum $pkgbuild_sum differs from upstream's $published_sum"

makepkg --printsrcinfo >.SRCINFO

output updated true
output tag "$tag"
output pkgver "$new_pkgver"

if [ -n "${PR_BODY_FILE:-}" ]; then
  release_url="$(jq -r '.html_url' <<<"$release")"
  # Keep upstream's notes from pinging people (@user -> `@user`) or adding
  # cross-reference events to upstream issues (redirect.github.com links
  # do not backlink).
  # shellcheck disable=SC2016 # the backticks are literal Markdown
  notes="$(jq -r '.body // ""' <<<"$release" | head -c 50000 |
    sed -E -e 's/(^|[^[:alnum:]`/])@([[:alnum:]][[:alnum:]-]*)/\1`@\2`/g' \
      -e 's#https://github\.com/#https://redirect.github.com/#g')"
  {
    echo "Automated bump to upstream [${tag}](${release_url})."
    echo
    echo "| | |"
    echo "|---|---|"
    echo "| Previous pkgver | \`${current_pkgver}\` |"
    echo "| New pkgver | \`${new_pkgver}\` |"
    echo "| Asset | \`${asset}\` |"
    echo "| SHA-256 (\`.sha256\` file) | \`${published_sum}\` |"
    echo "| SHA-256 (GitHub digest) | \`${github_digest:-not provided}\` |"
    echo "| Bundled node-hid | \`${nodehid}\` |"
    echo
    echo "**Before merging**, check the upstream diff for new runtime dependencies,"
    echo "license changes or anything unexpected. Merging publishes to the AUR."
    echo
    if ! git diff --quiet -- 69-openmouse-bridge.rules openmouse-bridge-is-mouse; then
      echo "### udev rule or helper changed"
      echo
      echo '```diff'
      git diff -- 69-openmouse-bridge.rules openmouse-bridge-is-mouse
      echo '```'
      echo
    fi
    echo "<details><summary>Upstream release notes</summary>"
    echo
    printf '%s\n' "$notes"
    echo
    echo "</details>"
  } >"$PR_BODY_FILE"
fi
