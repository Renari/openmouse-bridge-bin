# openmouse-bridge-bin

AUR packaging for [OpenMouse Bridge](https://github.com/OpenMouse-Project/OpenMouse-Bridge),
built from upstream's prebuilt `linux-x64` release.

## How releases flow

1. **Detect.** `Check for upstream release` (`.github/workflows/update.yml`) runs every
   6 hours. It looks at upstream's latest **stable** release (pre-releases and
   drafts are skipped). If that release is newer than the PKGBUILD, `scripts/update.sh`:
   - downloads the release archive and requires its SHA-256 to match both upstream's
     `.sha256` file and the digest GitHub recorded for the asset;
   - packages `openmouse-bridge-linux-x64-full.zip` (the plain `linux-x64.zip` is
     only a stub for old self-updaters);
   - verifies the bundled node-hid against npm (see below);
   - regenerates the udev rule and its helper from that tag's `install-linux.sh`;
   - bumps `_tag`, `_nodehid`, `pkgver`, resets `pkgrel=1`, updates the sums and
     `.SRCINFO`.

   It then opens (or refreshes) a single PR from `bot/upstream-update`, with the
   upstream release notes included, and dispatches CI on it.
2. **Test.** `CI` (`.github/workflows/ci.yml`) runs on every PR:
   - **Lint and verify sources:** shellcheck, actionlint, namcap on the PKGBUILD,
     a check that `.SRCINFO` is up to date, and a re-check of every checksum, the udev
     rule and helper, and node-hid against upstream and npm (`scripts/verify-upstream.sh`).
   - **Build package:** `makepkg` as an unprivileged user in a clean
     `archlinux:base-devel` container, then namcap on the built package.
   - **Install and run package:** a fresh container installs the package and runs
     `scripts/test-package.sh`. It runs `pacman -Qkk`, checks file layout and
     permissions, and confirms `ldd` and the `dlopen` libraries resolve. It checks
     the bundled Node.js and loads both node-hid backends, then runs upstream's
     helper unit tests. It validates the desktop entry, udev rule and helper. It
     starts Bridge headless and with its panel (Xvfb + D-Bus, rendered by Mesa's
     llvmpipe), and queries its local API on `127.0.0.1:17846`. Finally it uninstalls the package and checks nothing
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
- **In-app updater:** since 1.0.0 Bridge only installs updates itself when it runs
  as an AppImage (`$APPIMAGE` set). This package is not one, so Bridge checks
  upstream's `latest.json` and, when a newer release exists, only shows it with a
  link to the release page; it downloads and replaces nothing. Users update by
  upgrading the AUR package.
- **Panel rendering and fonts:** the panel draws through wgpu: Vulkan when
  `vulkan-icd-loader` and a Vulkan driver are present, otherwise OpenGL through
  libEGL. Its text needs one of Noto Sans, DejaVu Sans, Cantarell, Adwaita Sans,
  Ubuntu, Helvetica, Segoe UI or Arial, or the panel panics on start; the package
  depends on `noto-fonts` so one is always there.
- **node-hid hidraw prebuild:** upstream's release workflow deletes node-hid's
  `HID_hidraw-linux-x64` prebuild. node-hid loads that backend by default on
  Linux, so without it the Node HID helper fails (`Failed to find binding for
  HID_hidraw`). The PKGBUILD restores it from the npm tarball of the same node-hid
  version. CI checks that tarball against npm's sha512 integrity and confirms the
  libusb prebuild upstream *did* ship is byte-identical to the tarball's. If
  upstream starts shipping the hidraw prebuild again, `package()` leaves theirs
  in place.
- **udev rule:** `/usr/lib/udev/rules.d/69-openmouse-bridge.rules` grants the
  logged-in seat user (`uaccess`) access to every hidraw node of a USB device with
  a mouse interface (a mouse, or the receiver it pairs with; keyboards and tablets
  that also expose a mouse interface match too). The rule runs
  `/usr/lib/udev/openmouse-bridge-is-mouse`, upstream's helper that reads the USB
  interfaces and report descriptors. Both come from the heredocs in upstream's
  `install-linux.sh` (`scripts/gen-udev-rules.sh`), moved from `/etc/udev` to
  `/usr/lib/udev`. Upstream falls back to `MODE="0666"` on systems without logind;
  this package always uses `uaccess`. Bridge's own "Fix permissions" button only
  appears when a mouse cannot be opened, and would write
  `/etc/udev/rules.d/69-openmouse-bridge.rules`, which overrides this package's
  rule. `uinput` is loaded at boot via `/usr/lib/modules-load.d/openmouse-bridge.conf`.
