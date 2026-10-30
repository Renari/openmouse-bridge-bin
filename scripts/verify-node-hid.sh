#!/usr/bin/env bash
# Fetches the node-hid npm tarball matching an OpenMouse Bridge release zip and
# proves it is the right one before the PKGBUILD borrows its hidraw prebuild:
#   - the tarball matches the npm registry's sha512 integrity value
#   - the libusb prebuild upstream did ship is byte-identical to the tarball's
#
#   scripts/verify-node-hid.sh RELEASE_ZIP DEST_DIR
#
# Prints the bundled node-hid version; leaves DEST_DIR/node-hid-VERSION.tgz.
set -euo pipefail

zip="${1:?usage: verify-node-hid.sh RELEASE_ZIP DEST_DIR}"
dest="${2:?usage: verify-node-hid.sh RELEASE_ZIP DEST_DIR}"
module=native-hid/node_modules/node-hid

version="$(bsdtar -xOf "$zip" "$module/package.json" | jq -r '.version')"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: bad node-hid version '$version'" >&2; exit 1; }
tarball="$dest/node-hid-${version}.tgz"

integrity="$(curl -fsSL --retry 3 "https://registry.npmjs.org/node-hid/${version}" | jq -r '.dist.integrity')"
[[ "$integrity" == sha512-* ]] || { echo "error: npm gave no sha512 integrity for node-hid ${version}" >&2; exit 1; }
[ -f "$tarball" ] ||
  curl -fsSL --retry 3 "https://registry.npmjs.org/node-hid/-/node-hid-${version}.tgz" -o "$tarball"
actual="sha512-$(openssl dgst -sha512 -binary "$tarball" | base64 -w0)"
[ "$actual" = "$integrity" ] ||
  { echo "error: node-hid-${version}.tgz does not match npm integrity $integrity" >&2; exit 1; }

shipped="$(bsdtar -xOf "$zip" "$module/prebuilds/HID-linux-x64/node-napi-v4.node" | sha256sum | cut -d' ' -f1)"
npm="$(bsdtar -xOf "$tarball" package/prebuilds/HID-linux-x64/node-napi-v4.node | sha256sum | cut -d' ' -f1)"
[ "$shipped" = "$npm" ] ||
  { echo "error: the release's node-hid prebuild differs from npm's node-hid ${version}" >&2; exit 1; }
bsdtar -tf "$tarball" package/prebuilds/HID_hidraw-linux-x64/node-napi-v4.node >/dev/null ||
  { echo "error: node-hid ${version} has no HID_hidraw-linux-x64 prebuild" >&2; exit 1; }

echo "node-hid ${version}: npm integrity ok, shipped prebuild matches" >&2
printf '%s\n' "$version"
