#!/usr/bin/env bash
# PKGBUILD variables are imported with eval, which shellcheck cannot follow.
# shellcheck disable=SC2154
# Checks that the committed package still matches upstream for its pinned tag:
#   - the archive checksum equals upstream's .sha256 file and GitHub's digest
#   - the asset is the full package (not the updater stub)
#   - the udev rule and its helper match that tag's install-linux.sh
#   - _nodehid and its tarball checksum match the node-hid the release bundles
#   - pkgver is what scripts/update.sh would derive from _tag
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="OpenMouse-Project/OpenMouse-Bridge"
eval "$(bash -c 'source ./PKGBUILD; declare -p _tag _asset _nodehid pkgver source sha256sums')"
failures=0
fail() { echo "::error::$*"; failures=$((failures + 1)); }

auth=()
[ -z "${GITHUB_TOKEN:-}" ] || auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
release="$(curl -fsSL --retry 3 -H 'Accept: application/vnd.github+json' "${auth[@]}" \
  "https://api.github.com/repos/${REPO}/releases/tags/${_tag}")"

expected_pkgver="${_tag#v}"
expected_pkgver="${expected_pkgver//-/}"
[ "$pkgver" = "$expected_pkgver" ] || fail "pkgver $pkgver does not match tag $_tag (expected $expected_pkgver)"

[ "$_asset" = "openmouse-bridge-linux-x64-full.zip" ] ||
  fail "_asset is $_asset; only openmouse-bridge-linux-x64-full.zip is the full package"

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
if scripts/gen-udev-rules.sh "$installer" "$work/udev"; then
  for file in 69-openmouse-bridge.rules openmouse-bridge-is-mouse; do
    diff -u "$file" "$work/udev/$file" ||
      fail "$file is out of date with ${_tag}'s install-linux.sh (run scripts/gen-udev-rules.sh)"
  done
else
  fail "could not generate the udev rule from ${_tag}'s install-linux.sh"
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
