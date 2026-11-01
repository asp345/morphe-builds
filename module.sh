#!/usr/bin/env bash

set -euo pipefail

source common.sh

MODULE_ID="youtube-morphe"

[ $# = 6 ] || abort "usage: ANDROID_NDK=<ndk> [UPDATE_JSON=<url>] $0 <patched.apk> <stock.apk> <youtube-version> <patches-tag> <version-code> <out.zip>"
CLANG="${ANDROID_NDK-}/toolchains/llvm/prebuilt/linux-x86_64/bin/clang"
[ -x "$CLANG" ] || abort "ANDROID_NDK must point to an Android NDK"
patched=$1 stock=$2 yt_version=$3 patches_tag=$4 version_code=$5 out=$6
[[ $yt_version =~ ^[0-9]+(\.[0-9]+)+$ ]] || abort "invalid youtube version '$yt_version'"
[[ $version_code =~ ^[0-9]+$ ]] || abort "invalid version code '$version_code'"
stock_signature "$stock" >/dev/null

arch=$(python3 -I -c 'import sys, tomllib; print(tomllib.load(open(sys.argv[1], "rb")).get("arch", "arm64-v8a"))' config.toml)
case "$arch" in
arm64-v8a) module_arch=arm64 helper_archs=(arm64) ;;
arm-v7a) module_arch=arm helper_archs=() ;;
x86) module_arch=x86 helper_archs=() ;;
x86_64) module_arch=x64 helper_archs=(x64) ;;
all) module_arch="" helper_archs=(arm64 x64) ;;
*) abort "invalid arch '$arch'" ;;
esac

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp -a module/. "$tmp"
for a in "${helper_archs[@]}"; do
	case "$a" in
	arm64) target=aarch64-linux-android29 ;;
	x64) target=x86_64-linux-android29 ;;
	esac
	mkdir -p "$tmp/bin/$a"
	"$CLANG" --target="$target" -O2 -Wall -Wextra -Werror -s -o "$tmp/bin/$a/ksu_profile" ksu_profile/ksu_profile.c
done
cp -f "$patched" "$tmp/base.apk"
mkdir "$tmp/stock"
cp -f "$stock" "$tmp/stock/base.apk"
printf 'PKG_NAME=%s\nPKG_VER=%s\nMODULE_ARCH=%s\n' "$PKG_NAME" "$yt_version" "$module_arch" >"$tmp/config"
{
	echo "id=$MODULE_ID"
	echo "name=YouTube Morphe"
	echo "version=v$yt_version (patches $patches_tag)"
	echo "versionCode=$version_code"
	echo "author=asp345"
	echo "description=YouTube $yt_version patched with Morphe patches $patches_tag, mounted over the stock app"
	if [ -n "${UPDATE_JSON-}" ]; then echo "updateJson=$UPDATE_JSON"; fi
} >"$tmp/module.prop"

python3 -I - "$tmp" "$out" <<'EOF'
import os, sys, zipfile
src, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for root, dirs, files in os.walk(src):
        dirs.sort()
        for name in sorted(files):
            path = os.path.join(root, name)
            z.write(path, os.path.relpath(path, src))
EOF
echo "$out"
