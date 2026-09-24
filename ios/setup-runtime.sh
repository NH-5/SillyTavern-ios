#!/usr/bin/env bash
set -euo pipefail

ios_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
version="24.21.0-0"
expected_sha256="11ce3f366dc5f5f2f58a35186b257edc4fa365f2aeb1c0fe963c35728495b492"
target="$ios_dir/Vendor/NodeMobile.xcframework"
if [[ -d "$target" ]]; then
    echo "NodeMobile runtime already present: $target"
    exit 0
fi

archive="$(mktemp -t nodejs-mobile-ios).zip"
extract_dir="$(mktemp -d -t nodejs-mobile-ios)"
trap 'rm -f "$archive"; rm -rf "$extract_dir"' EXIT
url="https://github.com/fogtape/nodejs-mobile/releases/download/v${version}/nodejs-mobile-ios-${version}.zip"
if ! curl --fail --location --retry 3 --output "$archive" "$url"; then
    if ! command -v gh >/dev/null 2>&1; then
        echo 'Download failed. Install GitHub CLI or download the pinned release manually.' >&2
        exit 1
    fi
    gh release download "v${version}" -R fogtape/nodejs-mobile \
        --pattern "nodejs-mobile-ios-${version}.zip" --dir "$extract_dir"
    mv "$extract_dir/nodejs-mobile-ios-${version}.zip" "$archive"
fi
actual_sha256="$(shasum -a 256 "$archive" | cut -d ' ' -f 1)"
if [[ "$actual_sha256" != "$expected_sha256" ]]; then
    echo 'NodeMobile archive checksum mismatch.' >&2
    exit 1
fi
unzip -q "$archive" -d "$extract_dir"
framework="$(find "$extract_dir" -type d -name NodeMobile.xcframework -print -quit)"
if [[ -z "$framework" ]]; then
    echo 'NodeMobile.xcframework was not found in the downloaded archive.' >&2
    exit 1
fi
mkdir -p "$ios_dir/Vendor"
cp -R "$framework" "$target"
echo "Installed NodeMobile $version: $target"
