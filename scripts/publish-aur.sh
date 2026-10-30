#!/usr/bin/env bash
# PKGBUILD variables are imported with eval, which shellcheck cannot follow.
# shellcheck disable=SC2154
# Pushes the package files to ssh://aur@aur.archlinux.org/openmouse-bridge-bin.git.
#
# Env: AUR_SSH_PRIVATE_KEY (required), AUR_COMMIT_NAME / AUR_COMMIT_EMAIL
# (default: the author of this repository's HEAD commit).
# AUR_REMOTE overrides the clone/push URL (for testing against a local repo).
# Needs git, openssh and vercmp (pacman).
set -euo pipefail
cd "$(dirname "$0")/.."
repo_root="$PWD"

: "${AUR_SSH_PRIVATE_KEY:?AUR_SSH_PRIVATE_KEY is not set}"
pkgname="$(sed -n 's/^pkgname = //p' .SRCINFO)"
[ -n "$pkgname" ] || { echo "error: no pkgname in .SRCINFO" >&2; exit 1; }

eval "$(bash -c 'source ./PKGBUILD; declare -p pkgver pkgrel source install')"
version="${pkgver}-${pkgrel}"

# Only files the PKGBUILD references are published (the AUR rejects stray
# subdirectories, and this repo's CI scripts do not belong there).
files=(PKGBUILD .SRCINFO)
[ -z "${install:-}" ] || files+=("$install")
for entry in "${source[@]}"; do
  entry="${entry#*::}"
  [[ "$entry" == *://* ]] || files+=("$entry")
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
install -m 600 /dev/null "$work/key"
printf '%s\n' "$AUR_SSH_PRIVATE_KEY" >"$work/key"
export GIT_SSH_COMMAND="ssh -i $work/key -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$repo_root/.github/aur_known_hosts"

git clone "${AUR_REMOTE:-ssh://aur@aur.archlinux.org/${pkgname}.git}" "$work/aur"
cd "$work/aur"

if [ -f .SRCINFO ]; then
  published="$(sed -n 's/^\tpkgver = //p' .SRCINFO)-$(sed -n 's/^\tpkgrel = //p' .SRCINFO)"
  echo "AUR has ${published}, publishing ${version}"
  if [ "$(vercmp "$version" "$published")" -lt 0 ]; then
    echo "error: refusing to downgrade the AUR package from ${published} to ${version}" >&2
    exit 1
  fi
else
  echo "AUR package does not exist yet; creating it at ${version}"
fi

git ls-files -z | xargs -0r git rm -q --
for file in "${files[@]}"; do
  cp "$repo_root/$file" "./$file"
done
git add -- "${files[@]}"

if git diff --cached --quiet && git rev-parse -q --verify HEAD >/dev/null; then
  echo "AUR already matches this commit; nothing to publish"
  exit 0
fi

name="${AUR_COMMIT_NAME:-$(git -C "$repo_root" log -1 --format=%an)}"
email="${AUR_COMMIT_EMAIL:-$(git -C "$repo_root" log -1 --format=%ae)}"
source_commit="$(git -C "$repo_root" rev-parse HEAD)"
git -c user.name="$name" -c user.email="$email" commit -q \
  -m "Update to ${version}" \
  -m "Published from ${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-local}/commit/${source_commit}"
git log --stat -1
git push origin HEAD:master
echo "published ${pkgname} ${version} to the AUR"
