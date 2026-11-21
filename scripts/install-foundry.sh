#!/usr/bin/env bash
# Installs the pinned Foundry release (forge, cast, anvil) into a directory (default
# ~/.local/bin), after checking its SHA-256 against the value recorded here (the release's
# own .sha256 asset and GitHub's asset digest agree on each). CI's contracts job uses it;
# locally it is how the contracts gate gets its forge.
#
#   scripts/install-foundry.sh [directory]
set -euo pipefail
case "${1:-}" in -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;; esac
case "${1:-}" in -*) echo "install-foundry.sh: unknown option $1; the only argument is a directory (see --help)" >&2; exit 2 ;; esac

readonly VERSION="v1.10.0"
dest="${1:-$HOME/.local/bin}"

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)  asset="foundry_${VERSION}_linux_amd64.tar.gz";  sha="90729233bd9a683b872783ae2e3217fb56876fa2a3c37185f13e39dca8525041" ;;
  Linux-aarch64) asset="foundry_${VERSION}_linux_arm64.tar.gz";  sha="1ab8802cd11919914ee36ac57c6ca19b27a4b9b0a749f6fe2b9771f78fc83ec0" ;;
  Darwin-arm64)  asset="foundry_${VERSION}_darwin_arm64.tar.gz"; sha="884b2c0c1e5d73f903897a496e7516814fe68b27d2b7df1088e60e4a5ba9ef1a" ;;
  *) echo "error: no pinned Foundry build for $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
curl -sSfL --max-time 300 -o "$work/$asset" "https://github.com/foundry-rs/foundry/releases/download/$VERSION/$asset"
echo "$sha  $work/$asset" | shasum -a 256 -c - >/dev/null
tar -xzf "$work/$asset" -C "$work"
mkdir -p "$dest"
for tool in forge cast anvil; do
  install -m 0755 "$work/$tool" "$dest/$tool"
done
"$dest/forge" --version | head -n 1
