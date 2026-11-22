#!/bin/bash
# Build a macOS app that includes Python and Node, then wrap it in a DMG.
#
# The interpreters are relocatable builds copied into
# Lite XL.app/Contents/Resources/runtimes/. The prep plugin uses those
# binaries when they are present, so the recipient does not install Python
# or Node.
#
# Usage: scripts/package-dmg.sh [--skip-build] [--sign IDENTITY] [-o FILE]

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

build_dir="build-bundle"
out=""
sign_identity="-"
skip_build=false

python_release="20261110"
python_version="3.12.16"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build) skip_build=true; shift ;;
    --sign) sign_identity="$2"; shift 2 ;;
    -o|--output) out="$2"; shift 2 ;;
    -b|--builddir) build_dir="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: scripts/package-dmg.sh [--skip-build] [--sign IDENTITY] [-o FILE]"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This packages a macOS app. Run it on a Mac." >&2
  exit 1
fi

case "$(uname -m)" in
  arm64|aarch64)
    py_arch="aarch64"
    py_sha="2f11b8aa3726bdbd87dd9eb76568412faddf4f47e26913fa45d6a2e424972acd"
    node_arch="arm64"
    dmg_arch="arm64"
    ;;
  x86_64)
    py_arch="x86_64"
    py_sha="b78a4c479f1964ec484880bee567568266f68da102269fb93a05fe8716b45f91"
    node_arch="x64"
    dmg_arch="x86_64"
    ;;
  *)
    echo "Unsupported architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

if [[ -z "$out" ]]; then
  out="$root/dist/lite-coder-macos-${dmg_arch}.dmg"
fi

app="$root/$build_dir/Lite XL.app"
# build.sh removes the build directory, so the download cache lives beside it.
cache="$root/.build/runtime-cache"

if [[ "$skip_build" == false || ! -d "$app" ]]; then
  echo "Building $app"
  bash scripts/build.sh --forcefallback --bundle --lto -b "$build_dir"
fi

mkdir -p "$cache" "$(dirname "$out")"

if [[ ! -d "$app/Contents/MacOS" ]]; then
  echo "App bundle was not produced at: $app" >&2
  exit 1
fi

fetch() {
  local url="$1" dest="$2" sha="$3"
  if [[ -f "$dest" ]]; then
    if echo "$sha  $dest" | shasum -a 256 -c - >/dev/null 2>&1; then
      return
    fi
    rm -f "$dest"
  fi
  echo "Downloading $(basename "$dest")"
  curl -fL --retry 3 --retry-delay 2 -o "$dest" "$url"
  echo "$sha  $dest" | shasum -a 256 -c -
}

py_name="cpython-${python_version}+${python_release}-${py_arch}-apple-darwin-install_only_stripped.tar.gz"
fetch \
  "https://github.com/astral-sh/python-build-standalone/releases/download/${python_release}/${py_name}" \
  "$cache/$py_name" \
  "$py_sha"

node_sums="$cache/node-SHASUMS256.txt"
curl -fsSL -o "$node_sums" "https://nodejs.org/dist/latest-v22.x/SHASUMS256.txt"
node_line="$(grep "node-v.*-darwin-${node_arch}.tar.gz$" "$node_sums" | head -1)"
node_sha="$(printf '%s\n' "$node_line" | awk '{print $1}')"
node_file="$(printf '%s\n' "$node_line" | awk '{print $2}')"
if [[ -z "$node_file" || -z "$node_sha" ]]; then
  echo "Could not find a Node.js darwin-${node_arch} tarball." >&2
  exit 1
fi
fetch \
  "https://nodejs.org/dist/latest-v22.x/${node_file}" \
  "$cache/$node_file" \
  "$node_sha"

echo "Installing Python and Node into the app"
rm -rf "$app/Contents/Resources/runtimes"
mkdir -p "$app/Contents/Resources/runtimes"

py_stage="$cache/python-stage"
rm -rf "$py_stage"
mkdir -p "$py_stage"
tar -xzf "$cache/$py_name" -C "$py_stage"
if [[ -d "$py_stage/python/bin" ]]; then
  ditto "$py_stage/python" "$app/Contents/Resources/runtimes/python"
else
  echo "Python archive did not contain python/bin." >&2
  exit 1
fi

node_stage="$cache/node-stage"
rm -rf "$node_stage"
mkdir -p "$node_stage"
tar -xzf "$cache/$node_file" -C "$node_stage"
node_bin="$(find "$node_stage" -type f -path '*/bin/node' -print -quit)"
if [[ -z "$node_bin" ]]; then
  echo "Node archive did not contain bin/node." >&2
  exit 1
fi
mkdir -p "$app/Contents/Resources/runtimes/node/bin"
ditto "$node_bin" "$app/Contents/Resources/runtimes/node/bin/node"
chmod 755 "$app/Contents/Resources/runtimes/node/bin/node"

# Official node binaries link only the system libraries. Keep a private lib
# directory when a build points at a sibling library instead.
if otool -L "$app/Contents/Resources/runtimes/node/bin/node" | grep -q '@executable_path\|\.\./lib'; then
  node_root="$(cd "$(dirname "$node_bin")/.." && pwd)"
  if [[ -d "$node_root/lib" ]]; then
    ditto "$node_root/lib" "$app/Contents/Resources/runtimes/node/lib"
  fi
fi

py="$app/Contents/Resources/runtimes/python/bin/python3"
node="$app/Contents/Resources/runtimes/node/bin/node"
PYTHONDONTWRITEBYTECODE=1 "$py" -c 'import collections, heapq, json, sys; print(sys.version.split()[0])'
"$node" -e 'console.log(process.version)'

if otool -L "$app/Contents/MacOS/lite-xl" | grep -E '/opt/homebrew/|/usr/local/'; then
  echo "lite-xl is linked against a local library and will not run on another Mac." >&2
  exit 1
fi

if [[ "$dmg_arch" == "arm64" ]]; then
  plutil -replace LSMinimumSystemVersion -string "11.0" "$app/Contents/Info.plist"
fi

echo "Signing ($sign_identity)"
xattr -cr "$app"
# Sign nested interpreters before the bundle. An ad-hoc signature lets the
# app launch after the recipient approves it; it is not a notarized identity.
while IFS= read -r -d '' bin; do
  if file -b "$bin" | grep -q 'Mach-O'; then
    codesign --force --sign "$sign_identity" "$bin"
  fi
done < <(find "$app/Contents/Resources/runtimes" -type f \( -perm -111 -o -name '*.so' -o -name '*.dylib' \) -print0)
codesign --force --sign "$sign_identity" "$app"

echo "Creating $out"
rm -f "$out"
dmgbuild_bin=""
if command -v dmgbuild >/dev/null 2>&1; then
  dmgbuild_bin="dmgbuild"
else
  dmg_venv="$cache/dmg-venv"
  if [[ ! -x "$dmg_venv/bin/dmgbuild" ]]; then
    python3 -m venv "$dmg_venv"
    "$dmg_venv/bin/pip" install dmgbuild
  fi
  dmgbuild_bin="$dmg_venv/bin/dmgbuild"
fi
"$dmgbuild_bin" -s "$root/resources/macos/lite-xl-dmg.py" \
  -D "app_path=$app" \
  "Lite XL" "$out"

echo "Wrote $out"
