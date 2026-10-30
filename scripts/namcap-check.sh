#!/usr/bin/env bash
# Runs namcap and fails on any error except the ones listed below.
#
#   scripts/namcap-check.sh PKGBUILD|PACKAGE [namcap args...]
set -euo pipefail

# Upstream declares MIT in Cargo.toml but ships no LICENSE file to install.
allowed='require license files below /usr/share/licenses/[^ ]+ or switching to common license identifiers\. Found 1/2 required license files'

log="$(namcap "$@")"
printf '%s\n' "$log"
errors="$(grep ' E: ' <<<"$log" | grep -Ev "$allowed" || true)"
if [ -n "$errors" ]; then
  printf '::error::namcap reported errors:\n%s\n' "$errors"
  exit 1
fi
