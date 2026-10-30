#!/usr/bin/env bash
# PKGBUILD variables are imported with eval, which shellcheck cannot follow.
# shellcheck disable=SC2154
# Checks that the committed package still matches upstream for its pinned tag:
#   - the archive checksum equals upstream's .sha256 file and GitHub's digest
#   - the asset is the full package (not the post-beta.21 updater stub)
#   - the udev rule matches that tag's install-linux.sh vendor list
#   - _nodehid and its tarball checksum match the node-hid the release bundles
#   - pkgver is what scripts/update.sh would derive from _tag
#   - _updateurl (Bridge's patched update check) resolves to that same release
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="OpenMouse-Project/OpenMouse-Bridge"
eval "$(bash -c 'source ./PKGBUILD; declare -p _tag _asset _nodehid _repoid _updateurl pkgver source sha256sums')"
failures=0
fail() { echo "::error::$*"; failures=$((failures + 1)); }

auth=()
[ -z "${GITHUB_TOKEN:-}" ] || auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
release="$(curl -fsSL --retry 3 -H 'Accept: application/vnd.github+json' "${auth[@]}" \
  "https://api.github.com/repos/${REPO}/releases/tags/${_tag}")"

expected_pkgver="${_tag#v}"
expected_pkgver="${expected_pkgver//-/}"
[ "$pkgver" = "$expected_pkgver" ] || fail "pkgver $pkgver does not match tag $_tag (expected $expected_pkgver)"

repoid="$(curl -fsSL --retry 3 -H 'Accept: application/vnd.github+json' "${auth[@]}" \
  "https://api.github.com/repos/${REPO}" | jq -r .id)"
[ "$_repoid" = "$repoid" ] || fail "_repoid is $_repoid, but ${REPO} has ID $repoid"
update_tag="$(curl -fsSL --retry 3 -H 'Accept: application/vnd.github+json' "${auth[@]}" \
  "$_updateurl" | jq -r .tag_name)"
[ "$update_tag" = "$_tag" ] || fail "_updateurl returns release $update_tag, not $_tag"

if jq -e '.assets[] | select(.name == "openmouse-bridge-linux-x64-full.zip")' >/dev/null <<<"$release" &&
  [ "$_asset" != "openmouse-bridge-linux-x64-full.zip" ]; then
  fail "$_tag publishes openmouse-bridge-linux-x64-full.zip; $_asset is only the updater stub"
fi

digest="$(jq -r --arg n "$_asset" '.assets[] | select(.name == $n) | .digest // empty' <<<"$release")"
digest="${digest#sha256:}"
published="$(curl -fsSL --retry 3 \
  "https://github.com/${REPO}/releases/download/${_tag}/${_asset}.sha256" | awk 'NR == 1 { print $1 }')"
echo "PKGBUILD:     ${sha256sums[0]}"
echo ".sha256 file: ${published}"
echo "GitHub:       ${digest:-not provided}"
[ "${sha256sums[0]}" = "$published" ] || fail "archive checksum differs from upstream's ${_asset}.sha256"
[ -z "$digest" ] || [ "${sha256sums[0]}" = "$digest" ] || fail "archive checksum differs from GitHub's asset digest"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
installer="$work/install-linux.sh"
curl -fsSL --retry 3 "https://raw.githubusercontent.com/${REPO}/${_tag}/install-linux.sh" -o "$installer"
if ! diff -u 69-openmouse-bridge.rules <(scripts/gen-udev-rules.sh "$installer"); then
  fail "69-openmouse-bridge.rules is out of date with ${_tag}'s install-linux.sh (run scripts/gen-udev-rules.sh)"
fi

zip="$work/release.zip"
curl -fsSL --retry 3 "https://github.com/${REPO}/releases/download/${_tag}/${_asset}" -o "$zip"
[ "$(sha256sum "$zip" | cut -d' ' -f1)" = "${sha256sums[0]}" ] || fail "downloaded ${_asset} does not match sha256sums[0]"
if nodehid="$(scripts/verify-node-hid.sh "$zip" "$work")"; then
  [ "$nodehid" = "$_nodehid" ] || fail "release bundles node-hid ${nodehid}, PKGBUILD has _nodehid=${_nodehid}"
  for i in "${!source[@]}"; do
    if [ "${source[$i]%%::*}" = "node-hid-${_nodehid}.tgz" ]; then
      [ "$(sha256sum "$work/node-hid-${nodehid}.tgz" | cut -d' ' -f1)" = "${sha256sums[$i]}" ] ||
        fail "node-hid-${_nodehid}.tgz checksum in PKGBUILD differs from the npm-verified tarball"
    fi
  done
else
  fail "could not verify the node-hid tarball"
fi

[ "$failures" -eq 0 ] || exit 1
echo "package matches upstream ${_tag}"
