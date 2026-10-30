#!/usr/bin/env bash
# Installs a built package into this (throwaway, Arch) system and exercises it.
# Run as root inside a clean container:
#
#   scripts/test-package.sh openmouse-bridge-bin-*.pkg.tar.zst
#
# Needs: xorg-server-xvfb, dbus, desktop-file-utils, curl, jq (installed by CI).
set -euo pipefail

pkgfile="${1:?usage: test-package.sh PACKAGE_FILE}"
pkgname=openmouse-bridge-bin
app=/usr/lib/openmouse-bridge
port=17846
tester=bridgetest
failures=0

section() { printf '\n::group::%s\n' "$*"; }
endsection() { echo "::endgroup::"; }
pass() { printf 'ok   %s\n' "$*"; }
fail() { printf '::error::FAIL %s\n' "$*"; failures=$((failures + 1)); }
check() {
  local name="$1"
  shift
  if "$@"; then pass "$name"; else fail "$name"; fi
}

section "Install"
# The Arch container image skips docs/locales via NoExtract, which -Qkk would
# then report as missing files.
sed -i '/^NoExtract/d' /etc/pacman.conf
pacman -U --noconfirm "$pkgfile"
check "pacman -Qkk reports no altered or missing files" pacman -Qkk "$pkgname"
endsection

section "Package contents"
for path in \
  "$app/openmouse-bridge" \
  "$app/native-hid/node/bin/node" \
  "$app/native-hid/bridge-server.mjs" \
  "$app/native-hid/src/apply.mjs" \
  "$app/native-hid/src/button-listener.mjs" \
  "$app/native-hid/node_modules/node-hid/prebuilds/HID-linux-x64/node-napi-v4.node" \
  "$app/openmouse-app-icon.png" \
  "$app/DM-Sans-OFL.txt" \
  /usr/share/applications/io.openmouse.bridge.desktop \
  /usr/share/icons/hicolor/512x512/apps/io.openmouse.bridge.png \
  /usr/lib/udev/rules.d/69-openmouse-bridge.rules \
  /usr/lib/modules-load.d/openmouse-bridge.conf \
  /usr/share/doc/$pkgname/README.md \
  /usr/share/licenses/$pkgname/DM-Sans-OFL.txt; do
  check "exists: $path" test -e "$path"
done
check "/usr/bin/openmouse-bridge resolves to $app/openmouse-bridge" \
  test "$(readlink -f /usr/bin/openmouse-bridge)" = "$app/openmouse-bridge"
check "openmouse-bridge is executable" test -x "$app/openmouse-bridge"
check "bundled node is executable" test -x "$app/native-hid/node/bin/node"
check "everything under $app is root-owned" \
  test -z "$(find "$app" ! -user root -print -quit)"
check "nothing under $app is world-writable" \
  test -z "$(find "$app" -perm -o+w ! -type l -print -quit)"
check "update check no longer points at upstream's latest release" \
  bash -c "! LC_ALL=C grep -qaF 'OpenMouse-Bridge/releases/latest' '$app/openmouse-bridge'"
check "update check points at the packaged release" \
  bash -c "LC_ALL=C grep -qaE 'https://api\.github\.com/repositories/[0-9]+/releases/tags/v[^ ]+ *' '$app/openmouse-bridge'"
endsection

section "Shared libraries"
for elf in \
  "$app/openmouse-bridge" \
  "$app/native-hid/node/bin/node" \
  "$app/native-hid/node_modules/node-hid/prebuilds/HID-linux-x64/node-napi-v4.node"; do
  missing="$(ldd "$elf" | awk '/not found/ { print $1 }')"
  check "ldd resolves every library of ${elf#"$app"/}${missing:+ (missing: $missing)}" test -z "$missing"
done
# Loaded with dlopen at runtime, so ldd cannot see them.
for lib in libayatana-appindicator3.so.1 libGL.so.1 libEGL.so.1 libwayland-client.so.0 libxkbcommon.so.0 libxkbcommon-x11.so.0; do
  check "runtime dlopen target present: $lib" bash -c "ldconfig -p | grep -q '$lib'"
done
endsection

section "Bundled Node.js helper"
node="$app/native-hid/node/bin/node"
node_version="$("$node" --version)"
echo "bundled node: $node_version"
check "bundled node meets native-hid's engines.node (>=20)" \
  test "$(sed -E 's/^v([0-9]+).*/\1/' <<<"$node_version")" -ge 20
# Bridge treats a tiny node binary as an unfinished "stub" install and would
# try to download the real one at startup.
check "bundled node is a real runtime, not the updater stub" \
  test "$(stat -c %s "$node")" -gt 10000000
syntax_ok=true
while IFS= read -r -d '' module; do
  "$node" --check "$module" || { echo "syntax error: $module"; syntax_ok=false; }
done < <(find "$app/native-hid" -maxdepth 2 -name '*.mjs' -not -path '*/node_modules/*' -print0)
check "every helper module parses" $syntax_ok
# node-hid picks its hidraw backend by default on Linux; the helper uses that.
for driver in hidraw libusb; do
  check "node-hid $driver backend loads and enumerates devices" \
    bash -c "cd '$app/native-hid' && '$node' --input-type=module -e \"
      const HID = (await import('node-hid')).default;
      if ('$driver' !== 'hidraw') HID.setDriverType('$driver');
      const devices = HID.devices();
      if (!Array.isArray(devices)) throw new Error('devices() did not return an array');
      console.log('node-hid $driver ok,', devices.length, 'devices visible');
    \""
done
check "every runtime dependency in package.json resolves" \
  bash -c "cd '$app/native-hid' && '$node' --input-type=module -e \"
    import { readFileSync } from 'node:fs';
    const pkg = JSON.parse(readFileSync('package.json', 'utf8'));
    for (const name of Object.keys(pkg.dependencies ?? {})) {
      await import(name);
      console.log('resolved', name);
    }
  \""
# Upstream ships its helper unit tests; run them against the installed tree
# from a scratch copy so nothing writes into the installed tree.
scratch="$(mktemp -d)"
cp -a "$app/native-hid" "$scratch/"
mapfile -t helper_tests < <(find "$scratch/native-hid/src" -name '*.test.mjs' | sort)
if [ "${#helper_tests[@]}" -gt 0 ]; then
  check "upstream native-hid unit tests pass (${#helper_tests[@]} files)" \
    bash -c "cd '$scratch/native-hid' && '$node' --test $(printf "'%s' " "${helper_tests[@]}")"
else
  echo "no upstream helper tests shipped in this release"
fi
rm -rf "$scratch"
endsection

section "Desktop integration"
check "desktop entry validates" desktop-file-validate /usr/share/applications/io.openmouse.bridge.desktop
check "desktop entry Exec is on PATH" \
  bash -c "command -v \"\$(sed -n 's/^Exec=//p' /usr/share/applications/io.openmouse.bridge.desktop | cut -d' ' -f1)\""
check "udev rule validates" udevadm verify --resolve-names=never /usr/lib/udev/rules.d/69-openmouse-bridge.rules
check "udev rule never grants world access" \
  bash -c "! grep -E 'MODE=\"0?[0-7][0-7][1-7]\"' /usr/lib/udev/rules.d/69-openmouse-bridge.rules"
check "udev rule covers at least one hidraw vendor" \
  grep -q 'SUBSYSTEM=="hidraw", ATTRS{idVendor}==' /usr/lib/udev/rules.d/69-openmouse-bridge.rules
check "uinput is loaded at boot" grep -qx uinput /usr/lib/modules-load.d/openmouse-bridge.conf
endsection

# Runs Bridge as an unprivileged user with a fresh HOME, waits for its local
# API, and checks it stays up. Extra arguments are passed to Bridge.
smoke() {
  local label="$1" wrapper
  read -r -a wrapper <<<"$2"
  shift 2
  local home log pid status=""
  home="$(mktemp -d)"
  chown "$tester" "$home"
  log="$home/bridge.log"
  runuser -u "$tester" -- env -i HOME="$home" PATH=/usr/bin RUST_LOG=info \
    XDG_RUNTIME_DIR="$home" \
    "${wrapper[@]}" /usr/bin/openmouse-bridge "$@" >"$log" 2>&1 &
  pid=$!
  for _ in $(seq 60); do
    status="$(curl -fsS "http://127.0.0.1:${port}/v1/status" 2>/dev/null)" && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.5
  done
  if [ -n "$status" ] && jq -e 'type == "object"' >/dev/null <<<"$status"; then
    pass "$label: /v1/status answers with JSON"
    echo "$status" | jq -c . | head -c 2000; echo
  else
    fail "$label: /v1/status never answered"
  fi
  sleep 5
  check "$label: still running after 5s" kill -0 "$pid"
  check "$label: no panic in log" bash -c "! grep -qi 'panicked' '$log'"
  pkill -TERM -P "$pid" 2>/dev/null || true
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  echo "--- $label log ---"
  head -c 20000 "$log"
  echo "--- end $label log ---"
  rm -rf "$home"
}

section "Runtime smoke tests"
id "$tester" &>/dev/null || useradd -m "$tester"
smoke "headless" "" --headless
smoke "tray (Xvfb + D-Bus)" "xvfb-run -a dbus-run-session --"
endsection

section "Removal"
pacman -R --noconfirm "$pkgname"
check "$app removed" test ! -e "$app"
check "/usr/bin/openmouse-bridge removed" test ! -e /usr/bin/openmouse-bridge
check "udev rule removed" test ! -e /usr/lib/udev/rules.d/69-openmouse-bridge.rules
endsection

if [ "$failures" -gt 0 ]; then
  echo "::error::$failures check(s) failed"
  exit 1
fi
echo "all package checks passed"
