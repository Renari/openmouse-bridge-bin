# openmouse-bridge-bin

AUR packaging for [OpenMouse Bridge](https://github.com/OpenMouse-Project/OpenMouse-Bridge),
built from upstream's prebuilt `linux-x64` release.

## How releases flow

1. **Detect.** `Check for upstream release` (`.github/workflows/update.yml`) runs every
   6 hours. It looks at upstream's latest **stable** release (pre-releases and
   drafts are skipped). If that release is newer than the PKGBUILD, `scripts/update.sh`:
   - downloads the release archive and requires its SHA-256 to match both upstream's
     `.sha256` file and the digest GitHub recorded for the asset;
   - prefers `openmouse-bridge-linux-x64-full.zip` (since 1.0.0-beta.21; the plain
     `linux-x64.zip` is then just a stub for old self-updaters);
   - verifies the bundled node-hid against npm (see below);
   - regenerates the udev rule from that tag's `install-linux.sh` vendor list;
   - bumps `_tag`, `_asset`, `_nodehid`, `pkgver`, resets `pkgrel=1`, updates the sums and
     `.SRCINFO`.

   It then opens (or refreshes) a single PR from `bot/upstream-update`, with the
   upstream release notes included, and dispatches CI on it.
2. **Test.** `CI` (`.github/workflows/ci.yml`) runs on every PR:
   - **Lint and verify sources:** shellcheck, actionlint, namcap on the PKGBUILD,
     a check that `.SRCINFO` is up to date, and a re-check of every checksum, the udev
     vendor list and node-hid against upstream and npm (`scripts/verify-upstream.sh`).
   - **Build package:** `makepkg` as an unprivileged user in a clean
     `archlinux:base-devel` container, then namcap on the built package.
   - **Install and run package:** a fresh container installs the package and runs
     `scripts/test-package.sh`. It runs `pacman -Qkk`, checks file layout and
     permissions, and confirms `ldd` and the `dlopen` libraries resolve. It checks
     the bundled Node.js and loads both node-hid backends, then runs upstream's
     helper unit tests. It validates the desktop entry and udev rule. It starts
     Bridge headless and with its tray (Xvfb + D-Bus), and queries its local API
     on `127.0.0.1:17846`. Finally it uninstalls the package and checks nothing
     is left behind.
3. **Publish.** Merging to `master` runs `Deploy to AUR` (`.github/workflows/deploy.yml`).
   It re-runs the full CI on the merged commit, then `scripts/publish-aur.sh`
   pushes only the files the PKGBUILD references to
   `ssh://aur@aur.archlinux.org/openmouse-bridge-bin.git`. It refuses to downgrade
   and does nothing if the AUR already matches. AUR host keys are pinned in
   `.github/aur_known_hosts`.

For packaging-only changes, bump `pkgrel`, then run
`updpkgsums && makepkg --printsrcinfo > .SRCINFO` and open a PR as usual.
To package a specific tag, run the update workflow manually and enter it in the
`tag` input.

## Packaging notes

- Installs to `/usr/lib/openmouse-bridge`, with `/usr/bin/openmouse-bridge` as a symlink.
- **In-app updater:** Bridge's self-updater cannot write to pacman-managed files, but
  it would still download each new upstream release before failing. `prepare()`
  rewrites the release URL compiled into the binary (same length, padded with
  spaces) to `_updateurl`, the API URL of the packaged tag, so Bridge always
  reports "Up to date"; users update by rebuilding the package from the AUR.
  The build fails if upstream changes that URL; CI checks `_repoid` and that
  `_updateurl` returns the packaged release.
- **node-hid hidraw prebuild:** upstream's release workflow deletes node-hid's
  `HID_hidraw-linux-x64` prebuild. node-hid loads that backend by default on
  Linux, so without it the Node HID helper fails (`Failed to find binding for
  HID_hidraw`). The PKGBUILD restores it from the npm tarball of the same node-hid
  version. CI checks that tarball against npm's sha512 integrity and confirms the
  libusb prebuild upstream *did* ship is byte-identical to the tarball's. If
  upstream starts shipping the hidraw prebuild again, `package()` leaves theirs
  in place.
- **udev rule:** `/usr/lib/udev/rules.d/69-openmouse-bridge.rules` grants hidraw
  access to the logged-in seat user (`uaccess`). Upstream's installer adds
  `MODE="0666"`, which makes these devices, keyboards included, readable by every
  local user and service; this package leaves that out. `uinput` is loaded at boot
  via `/usr/lib/modules-load.d/openmouse-bridge.conf`.
