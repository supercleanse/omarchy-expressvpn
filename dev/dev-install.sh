#!/usr/bin/env bash
# Install this working copy into the Omarchy shell for local development.
#
# The shell's QML engine caches compiled components by file URL, so editing a
# file in place, or re-copying it to the same path, can leave the old code
# running. This script copies the plugin into a fresh runtime-<stamp>/ folder
# inside ~/.config/omarchy/plugins/supercleanse.expressvpn/, points the
# installed manifest at it, removes the previous runtime folder, and lets the
# shell's plugin watcher reload it. Run it again after every change.
#
# The repository itself stays a plain, clone-installable plugin (manifest.json
# and Widget.qml at the root) for `omarchy plugin add`.
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
id=$(jq -r '.id' "$repo/manifest.json")
target="${OMARCHY_PLUGINS_DIR:-$HOME/.config/omarchy/plugins}/$id"

if [[ -d $target/.git ]]; then
  echo "dev-install: $target is a git checkout (installed with omarchy plugin add)." >&2
  echo "dev-install: remove it first (omarchy plugin remove $id) to use a dev copy." >&2
  exit 1
fi

omarchy-plugin-validate "$repo"

stamp=$(date +%Y%m%d-%H%M%S)
runtime="runtime-$stamp"
mkdir -p "$target/$runtime"
for f in Widget.qml Model.js login.sh; do
  install -m 0644 "$repo/$f" "$target/$runtime/$f"
done
chmod 0755 "$target/$runtime/login.sh"
install -m 0644 "$repo/README.md" "$repo/LICENSE" "$target/"

jq --arg rt "$runtime" '.entryPoints |= with_entries(.value = ($rt + "/" + .value))' \
  "$repo/manifest.json" > "$target/manifest.json.tmp"
mv "$target/manifest.json.tmp" "$target/manifest.json"

find "$target" -mindepth 1 -maxdepth 1 -type d -name 'runtime-*' ! -name "$runtime" -exec rm -rf {} +

omarchy-plugin-validate "$target"
echo "dev-install: $id -> $target/$runtime"
