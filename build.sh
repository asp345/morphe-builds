#!/usr/bin/env bash

set -euo pipefail
shopt -s nullglob

source common.sh

TEMP_DIR="temp"
BUILD_DIR="build"
HTMLQ_URL="https://github.com/mgdm/htmlq/releases/download/v0.4.0/htmlq-x86_64-linux.tar.gz"
HTMLQ_SHA256="dcf0419fe64ba99809ec49b78b1c5a2c72cec627ce8dc4deedb5c3b914035085"
USER_AGENT="Mozilla/5.0 (X11; Linux x86_64; rv:108.0) Gecko/20100101 Firefox/108.0"
GMSCORE_PATCH="GmsCore support"

for cmd in curl jq python3 tar sha256sum gh; do
	command -v "$cmd" >/dev/null || abort "'$cmd' is not installed"
done
java_isolated() { env -i PATH=/usr/bin:/bin HOME="$PWD/$TEMP_DIR" "$JAVA_BIN" --enable-native-access=ALL-UNNAMED "$@"; }

CONFIG_FILE=${1:-config.toml}
[ -f "$CONFIG_FILE" ] || abort "config file '$CONFIG_FILE' not found"
CONFIG=$(config_json "$CONFIG_FILE")
cfg() { jq -r --arg k "$1" '.[$k] // empty | strings' <<<"$CONFIG"; }
cfg_req() {
	local v
	v=$(cfg "$1")
	[ -n "$v" ] || abort "'$1' is not set in $CONFIG_FILE"
	echo "$v"
}
cfg_list() { jq -r --arg k "$1" '.[$k] // [] | .[]' <<<"$CONFIG"; }
for k in excluded-patches included-patches patcher-args; do
	jq -e --arg k "$k" '.[$k] // [] | type == "array" and all(type == "string")' <<<"$CONFIG" >/dev/null ||
		abort "'$k' must be an array of strings"
done

PATCHES_REPO=$(cfg_req patches-repo)
PATCHES_VERSION=$(cfg patches-version)
PATCHES_VERSION=${PATCHES_VERSION:-latest}
PATCHES_SIGNER_WORKFLOW=$(cfg_req patches-signer-workflow)
PATCHES_SOURCE_REF=$(cfg_req patches-source-ref)
CLI_URL=$(cfg_req cli-url)
CLI_SHA256=$(cfg_req cli-sha256)
VERSION=$(cfg version)
VERSION=${VERSION:-auto}
ARCH=$(cfg arch)
ARCH=${ARCH:-arm64-v8a}
BUILD_MODE=$(cfg build-mode)
BUILD_MODE=${BUILD_MODE:-both}
DPI=$(cfg dpi)
DPI=${DPI:-"nodpi anydpi"}
ARCHIVE_DLURL=$(cfg archive-dlurl)
APKMIRROR_DLURL=$(cfg apkmirror-dlurl)
mapfile -t EXCLUDED_PATCHES < <(cfg_list excluded-patches)
mapfile -t INCLUDED_PATCHES < <(cfg_list included-patches)
mapfile -t PATCHER_ARGS < <(cfg_list patcher-args)

case "$ARCH" in
arm64-v8a | arm-v7a | x86 | x86_64 | all) ;;
*) abort "invalid arch '$ARCH'" ;;
esac
case "$BUILD_MODE" in
apk) MODES=(apk) ;;
module) MODES=(module) ;;
both) MODES=(apk module) ;;
*) abort "invalid build-mode '$BUILD_MODE'" ;;
esac
[ -n "$ARCHIVE_DLURL" ] || [ -n "$APKMIRROR_DLURL" ] || abort "set archive-dlurl or apkmirror-dlurl"

req() {
	local url=$1 out=$2
	local args=(-sSfL --connect-timeout 10 --retry 2 -c "$TEMP_DIR/cookie.txt" -b "$TEMP_DIR/cookie.txt" -H "User-Agent: $USER_AGENT")
	if [ "$out" = - ]; then
		curl "${args[@]}" "$url"
	else
		curl "${args[@]}" "$url" -o "$out.part" && mv -f "$out.part" "$out"
	fi
}

get_htmlq() {
	local tgz="$TEMP_DIR/htmlq-x86_64-linux.tar.gz"
	if [ ! -f "$tgz" ]; then
		pr "Getting htmlq"
		req "$HTMLQ_URL" "$tgz" || abort "could not download htmlq"
	fi
	verify_sha256 "$tgz" "$HTMLQ_SHA256"
	tar -xzf "$tgz" -C "$TEMP_DIR" htmlq
	HTMLQ="$TEMP_DIR/htmlq"
}

get_cli() {
	CLI_JAR="$TEMP_DIR/cli-${CLI_SHA256}.jar"
	if [ ! -f "$CLI_JAR" ]; then
		pr "Getting CLI from '$CLI_URL'"
		req "$CLI_URL" "$CLI_JAR" || abort "could not download CLI"
	fi
	verify_sha256 "$CLI_JAR" "$CLI_SHA256"
}

get_patches_release() {
	local endpoint
	if [ "$PATCHES_VERSION" = latest ]; then
		endpoint="repos/${PATCHES_REPO}/releases/latest"
	else
		endpoint="repos/${PATCHES_REPO}/releases/tags/${PATCHES_VERSION}"
	fi
	PATCHES_RELEASE=$(gh api "$endpoint") || abort "could not get patches release from $PATCHES_REPO"
	PATCHES_TAG=$(jq -e -r .tag_name <<<"$PATCHES_RELEASE") || abort "patches release has no tag"
}

get_patches() {
	local asset_url asset_name
	[ "$(jq '[.assets[] | select(.name | endswith(".mpp"))] | length' <<<"$PATCHES_RELEASE")" = 1 ] ||
		abort "patches release $PATCHES_TAG must have exactly one .mpp asset"
	asset_url=$(jq -r '.assets[] | select(.name | endswith(".mpp")) | .browser_download_url' <<<"$PATCHES_RELEASE")
	asset_name=$(jq -r '.assets[] | select(.name | endswith(".mpp")) | .name' <<<"$PATCHES_RELEASE")
	mkdir -p "$TEMP_DIR/patches"
	PATCHES_FILE="$TEMP_DIR/patches/${PATCHES_TAG}-${asset_name}"
	if [ ! -f "$PATCHES_FILE" ]; then
		pr "Getting patches $PATCHES_TAG from $PATCHES_REPO"
		req "$asset_url" "$PATCHES_FILE" || abort "could not download patches"
	fi
	pr "Verifying build attestation of $PATCHES_FILE"
	gh attestation verify "$PATCHES_FILE" \
		--repo "$PATCHES_REPO" \
		--signer-workflow "$PATCHES_SIGNER_WORKFLOW" \
		--source-ref "$PATCHES_SOURCE_REF" \
		--deny-self-hosted-runners >&2 || abort "attestation verification failed for $PATCHES_FILE"
}

check_patch_names() {
	local names p
	names=$(java_isolated -jar "$CLI_JAR" list-patches --patches="$PATCHES_FILE" -f "$PKG_NAME" 2>&1 | sed -n 's/^Name: //p')
	[ -n "$names" ] || abort "could not list patches for $PKG_NAME"
	for p in "${EXCLUDED_PATCHES[@]}" "${INCLUDED_PATCHES[@]}" "$GMSCORE_PATCH"; do
		grep -qFx -- "$p" <<<"$names" || abort "patch '$p' does not exist in patches $PATCHES_TAG"
	done
}

resolve_version() {
	if [ "$VERSION" != auto ]; then
		echo "$VERSION"
		return
	fi
	local op
	op=$(java_isolated -jar "$CLI_JAR" list-versions --patches="$PATCHES_FILE" -f "$PKG_NAME" 2>&1) ||
		abort "list-versions failed: $op"
	sed -n '/Most common compatible versions:/,$p' <<<"$op" | awk 'NR > 1 && $1 ~ /^[0-9.]+$/ {print $1}' | sort -V | tail -1
}

dl_archive() {
	local version=$1 output=$2 listing file
	listing=$(req "$ARCHIVE_DLURL" -) || return 1
	for file in "${PKG_NAME}-${version}-${ARCH}.apk" "${PKG_NAME}-${version}-all.apk"; do
		if grep -qF "href=\"${file}\"" <<<"$listing"; then
			pr "Downloading ${ARCHIVE_DLURL}/${file}"
			req "${ARCHIVE_DLURL}/${file}" "$output"
			return
		fi
	done
	return 1
}

apkmirror_search() {
	local resp=$1 arch=$2 n node app_table dlurl="" appdpi
	local apparch=('universal' 'noarch' 'arm64-v8a + armeabi-v7a')
	if [ "$arch" != all ]; then apparch+=("$arch"); fi
	read -r -a appdpi <<<"$DPI"
	for ((n = 1; n < 40; n++)); do
		node=$($HTMLQ "div.table-row.headerFont:nth-last-child($n)" -r "span:nth-child(n+3)" <<<"$resp")
		[ -n "$node" ] || break
		[ -n "$($HTMLQ -t -w "div.table-cell:nth-child(1) > a:nth-child(1)" <<<"$node" | xargs)" ] || break
		app_table=$($HTMLQ --text --ignore-whitespace <<<"$node")
		[ "$(sed -n 3p <<<"$app_table")" = APK ] || continue
		dlurl=$($HTMLQ --base https://www.apkmirror.com --attribute href "div:nth-child(1) > a:nth-child(1)" <<<"$node")
		if printf '%s\n' "${appdpi[@]}" | grep -qFx -- "$(sed -n 6p <<<"$app_table")" &&
			printf '%s\n' "${apparch[@]}" | grep -qFx -- "$(sed -n 4p <<<"$app_table")"; then
			echo "$dlurl"
			return 0
		fi
	done
	if [ "$n" -eq 2 ] && [ -n "$dlurl" ]; then
		echo "$dlurl"
		return 0
	fi
	return 1
}

dl_apkmirror() {
	local version=$1 output=$2 arch=$ARCH app_page name url resp dlurl
	if [ "$arch" = arm-v7a ]; then arch=armeabi-v7a; fi
	app_page=$(req "$APKMIRROR_DLURL" -) || return 1
	name=$($HTMLQ "h1.marginZero" --text <<<"$app_page")
	name=${name,,} name=${name// /-} name=${name//[^a-z0-9-]/}
	resp=$(req "${APKMIRROR_DLURL}/${name}-${version//./-}-release/" -) || return 1
	if [ -n "$($HTMLQ "div.table-row.headerFont:nth-last-child(1)" -r "span:nth-child(n+3)" <<<"$resp")" ]; then
		if ! dlurl=$(apkmirror_search "$resp" "$arch"); then
			epr "no single APK variant of $version found on APKMirror"
			return 1
		fi
		resp=$(req "$dlurl" -) || return 1
	fi
	url=$($HTMLQ --base https://www.apkmirror.com --attribute href "a.btn" <<<"$resp" | head -1)
	[ -n "$url" ] || return 1
	url=$(req "$url" - | $HTMLQ --base https://www.apkmirror.com --attribute href "span > a[rel = nofollow]" | head -1)
	[ -n "$url" ] || return 1
	pr "Downloading $url"
	req "$url" "$output"
}

get_stock() {
	local version=$1
	STOCK_APK="$TEMP_DIR/${PKG_NAME}-${version}-${ARCH}.apk"
	STOCK_SOURCE=cache
	if [ ! -f "$STOCK_APK" ]; then
		if [ -n "$ARCHIVE_DLURL" ] && dl_archive "$version" "$STOCK_APK"; then
			STOCK_SOURCE=archive.org
		elif [ -n "$APKMIRROR_DLURL" ] && get_htmlq && dl_apkmirror "$version" "$STOCK_APK"; then
			STOCK_SOURCE=apkmirror
		else
			rm -f "$STOCK_APK.part"
			abort "could not download $PKG_NAME $version ($ARCH) as a single APK"
		fi
	fi
	STOCK_SIGNER=$(stock_signature "$STOCK_APK")
}

patch_youtube() {
	local mode=$1 out="$BUILD_DIR/youtube-$1-unsigned.apk" result="$TEMP_DIR/patch-result-$1.json" p
	local excluded=("${EXCLUDED_PATCHES[@]}")
	if [ "$mode" = module ]; then excluded+=("$GMSCORE_PATCH"); fi
	rm -f "$result"
	local args=(-jar "$CLI_JAR" patch "$STOCK_APK" -o "$out" --unsigned -t "$PWD/$TEMP_DIR/patch-tmp" -r "$PWD/$result")
	if [ "$ARCH" = arm-v7a ]; then
		args+=(--striplibs armeabi-v7a)
	elif [ "$ARCH" != all ]; then
		args+=(--striplibs "$ARCH")
	fi
	args+=(-p "$PATCHES_FILE")
	for p in "${INCLUDED_PATCHES[@]}"; do args+=(-e "$p"); done
	for p in "${excluded[@]}"; do args+=(-d "$p"); done
	args+=("${PATCHER_ARGS[@]}")

	pr "Patching ($mode): java ${args[*]}"
	java_isolated "${args[@]}" || abort "patching failed"
	[ -f "$out" ] || abort "patched apk was not created"
	rm -rf "$TEMP_DIR/patch-tmp"
	jq -e '.success == true and (.failedPatches | length) == 0' "$result" >/dev/null || abort "patching reported failures"
	for p in "${excluded[@]}"; do
		jq -e --arg p "$p" '.appliedPatches | index($p) == null' "$result" >/dev/null || abort "excluded patch '$p' was applied"
	done
	for p in "${INCLUDED_PATCHES[@]}"; do
		jq -e --arg p "$p" '.appliedPatches | index($p) != null' "$result" >/dev/null || abort "included patch '$p' was not applied"
	done
	pr "Built $out"
}

mkdir -p "$TEMP_DIR" "$BUILD_DIR"

if [ "${2-}" = --patches-tag ]; then
	get_patches_release
	echo "$PATCHES_TAG"
	exit 0
fi

rm -f "$BUILD_DIR"/*
get_cli
get_patches_release
get_patches
check_patch_names
YT_VERSION=$(resolve_version)
[[ $YT_VERSION =~ ^[0-9]+(\.[0-9]+)+$ ]] || abort "could not determine a YouTube version (got '$YT_VERSION')"
pr "Choosing YouTube $YT_VERSION"
get_stock "$YT_VERSION"

for mode in "${MODES[@]}"; do patch_youtube "$mode"; done
if [ "$BUILD_MODE" != apk ]; then cp -f "$STOCK_APK" "$BUILD_DIR/stock.apk"; fi

jq -n \
	--arg youtube_version "$YT_VERSION" \
	--arg arch "$ARCH" \
	--arg build_mode "$BUILD_MODE" \
	--arg patches_repo "$PATCHES_REPO" \
	--arg patches_tag "$PATCHES_TAG" \
	--arg patches_sha256 "$(sha256_of "$PATCHES_FILE")" \
	--arg cli_url "$CLI_URL" \
	--arg cli_sha256 "$CLI_SHA256" \
	--arg stock_source "$STOCK_SOURCE" \
	--arg stock_sha256 "$(sha256_of "$STOCK_APK")" \
	--arg stock_signer "$STOCK_SIGNER" \
	--argjson excluded_patches "$(jq -n '$ARGS.positional' --args "${EXCLUDED_PATCHES[@]}")" \
	--argjson included_patches "$(jq -n '$ARGS.positional' --args "${INCLUDED_PATCHES[@]}")" \
	--argjson applied_patches "$(for mode in "${MODES[@]}"; do jq --arg m "$mode" '{($m): .appliedPatches}' "$TEMP_DIR/patch-result-$mode.json"; done | jq -s add)" \
	'$ARGS.named' >"$BUILD_DIR/build-info.json"

pr "Built YouTube $YT_VERSION with patches $PATCHES_TAG ($BUILD_MODE)"
