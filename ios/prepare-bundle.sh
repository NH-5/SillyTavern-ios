#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bundle_dir="$root_dir/ios/Bundle/STServer"
export NPM_CONFIG_CACHE="${TMPDIR:-/tmp}/sillytavern-ios-npm-cache"

cd "$root_dir"
if ! npm ls webpack --depth=0 --omit=dev >/dev/null 2>&1; then
    npm ci --omit=dev --omit=optional --ignore-scripts --no-audit --no-fund
fi

# Copy tracked assets only. A developer's local public/ directory can contain
# chats, secrets and uploaded files that must never enter an app bundle.
rm -rf "$bundle_dir"
mkdir -p "$bundle_dir"
git ls-files -z -- src public default plugins | while IFS= read -r -d '' file; do
    mkdir -p "$bundle_dir/$(dirname "$file")"
    cp "$file" "$bundle_dir/$file"
done
cp package.json package-lock.json server.js webpack.config.js "$bundle_dir/"

# iOS cannot execute macOS native add-ons. Omit platform-specific optional
# packages and fail if a required add-on still enters the bundle.
cd "$bundle_dir"
npm ci --omit=dev --omit=optional --ignore-scripts --no-audit --no-fund
if find node_modules -name '*.node' -print -quit | grep -q .; then
    echo 'The iOS bundle contains a native Node add-on. Cross-compile it for iOS before packaging.' >&2
    exit 1
fi

cd "$root_dir"
node ios/build-frontend.mjs "$bundle_dir/public"
echo "Prepared iOS server bundle: $bundle_dir"
