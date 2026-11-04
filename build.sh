#!/usr/bin/env bash

set -euo pipefail
shopt -s nullglob

source common.sh

TEMP_DIR="temp"
HTMLQ_URL="https://github.com/mgdm/htmlq/releases/download/v0.4.0/htmlq-x86_64-linux.tar.gz"
HTMLQ_SHA256="4f63c8d9d835aa1f18f472da2eb5fc88295ede6aebcc7949fd428403707fc74a"
USER_AGENT="Mozilla/5.0 (X11; Linux x86_64; rv:108.0) Gecko/20100101 Firefox/108.0"
GMSCORE_PATCH="GmsCore support"
VERSION_RE='^[0-9][0-9A-Za-z._-]*$'

for cmd in curl jq python3 tar sha256sum gh; do
	command -v "$cmd" >/dev/null || abort "'$cmd' is not installed"
done

APKMIRROR_VARIANTS=$(cat <<'EOF'
import html, re, sys

page = sys.stdin.read()
rx_row = re.compile(r'<div class="table-row(?: headerFont)?[^"]*"[^>]*>', re.S)
rx_cell = re.compile(r'<div class="table-cell[^"]*"[^>]*>', re.S)
rx_text = re.compile(r'<[^>]+>', re.S)
rx_dpi = re.compile(r'[0-9a-z-]+dpi')
rx_link = re.compile(r'href="(/apk/[^"]*-android-apk-download/)')

starts = [match.start() for match in rx_row.finditer(page)]
for index, start in enumerate(starts, 1):
    end = starts[index] if index < len(starts) else len(page)
    row = page[start:end]
    cells = rx_cell.split(row)[1:]
    if len(cells) < 4:
        continue
    texts = [re.sub(r'\\s+', ' ', html.unescape(rx_text.sub(' ', cell))).strip() for cell in cells]
    dpi = rx_dpi.search(texts[3])
    if dpi is None:
        continue
    kind = 'BUNDLE' if ' BUNDLE ' in ' ' + texts[0] + ' ' else 'APK'
    link = rx_link.search(row)
    print('	'.join([str(index), kind, texts[1], dpi.group(0), link.group(1) if link else '']))
EOF
)
java_isolated() { env -i PATH=/usr/bin:/bin HOME="$PWD/$TEMP_DIR" "$JAVA_BIN" --enable-native-access=ALL-UNNAMED "$@"; }

CONFIG=$(config_json config.toml)
if [ "${1-}" = --apps ]; then
	jq -r 'to_entries[] | select(.value | type == "object") | .key' <<<"$CONFIG"
	exit 0
fi
[ $# -ge 1 ] || abort "usage: $0 --apps | <app> [--patches-tag]"
APP=$1
jq -e --arg a "$APP" '.[$a] | type == "object"' <<<"$CONFIG" >/dev/null || abort "no [$APP] table in config.toml"

cfg() { jq -r --arg k "$1" '.[$k] // empty | strings' <<<"$CONFIG"; }
app() { jq -r --arg a "$APP" --arg k "$1" '.[$a][$k] // empty | strings' <<<"$CONFIG"; }
app_req() {
	local v
	v=$(app "$1")
	[ -n "$v" ] || abort "'$1' is not set in [$APP]"
	echo "$v"
}
app_list() { jq -r --arg a "$APP" --arg k "$1" '.[$a][$k] // [] | .[]' <<<"$CONFIG"; }
for k in excluded-patches included-patches patcher-args; do
	jq -e --arg a "$APP" --arg k "$k" '.[$a][$k] // [] | type == "array" and all(type == "string")' <<<"$CONFIG" >/dev/null ||
		abort "'$k' in [$APP] must be an array of strings"
done

PKG_NAME=$(app_req package)
PATCHES_REPO=$(app_req patches-repo)
CLI_URL=$(cfg cli-url)
CLI_SHA256=$(cfg cli-sha256)
VERSION=$(app version)
VERSION=${VERSION:-auto}
ARCH=$(app arch)
ARCH=${ARCH:-arm64-v8a}
BUILD_MODE=$(app build-mode)
BUILD_MODE=${BUILD_MODE:-apk}
DPI=$(app dpi)
DPI=${DPI:-"nodpi anydpi 120-640dpi"}
ARCHIVE_DLURL=$(app archive-dlurl)
APKMIRROR_DLURL=$(app apkmirror-dlurl)
mapfile -t EXCLUDED_PATCHES < <(app_list excluded-patches)
mapfile -t INCLUDED_PATCHES < <(app_list included-patches)
mapfile -t PATCHER_ARGS < <(app_list patcher-args)
BUILD_DIR="build/$APP"

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
[ -n "$ARCHIVE_DLURL" ] || [ -n "$APKMIRROR_DLURL" ] || abort "set archive-dlurl or apkmirror-dlurl in [$APP]"

req() {
	local url=$1 out=$2 status
	local args=(-sSfL --connect-timeout 10 --retry 2 -c "$TEMP_DIR/cookie.txt" -b "$TEMP_DIR/cookie.txt" -H "User-Agent: $USER_AGENT")
	if [ "$out" = - ]; then
		curl "${args[@]}" "$url"
	else
		status=$(curl "${args[@]}" "$url" -o "$out.part" -w '%{http_code}')
		if [ "$status" = 200 ] && [ -s "$out.part" ]; then
			mv -f "$out.part" "$out"
			return 0
		fi
		rm -f "$out.part"
		epr "HTTP ${status:-0} from $url"
		return 1
	fi
}

req_package() {
	local url=$1 out=$2 status
	local args=(-sSfL --connect-timeout 10 --retry 2 -c "$TEMP_DIR/cookie.txt" -b "$TEMP_DIR/cookie.txt" -H "User-Agent: $USER_AGENT")
	status=$(curl "${args[@]}" "$url" -o "$out.part" -w '%{http_code}')
	if [ "$status" = 200 ] && [ "$(head -c 2 "$out.part")" = PK ]; then
		mv -f "$out.part" "$out"
		return 0
	fi
	epr "no package at $url (HTTP ${status:-0}): $(head -c 60 "$out.part" | tr -d '\0\n')"
	rm -f "$out.part"
	return 1
}

verify_package() {
	local f=$1 magic
	case "$f" in
	*.apk | *.apkm | *.apks | *.xapk) ;;
	*) return ;;
	esac
	magic=$(head -c 2 "$f")
	[ "$magic" = PK ] || abort "'$f' is not a package (starts with '$(head -c 60 "$f" | tr -d '\0\n')')"
}

get_cf_clearance() {
	local chrome=${CHROME:-google-chrome} major clearance
	command -v node >/dev/null || abort "'node' is not installed"
	command -v Xvfb >/dev/null || abort "'Xvfb' is not installed"
	command -v xdotool >/dev/null || abort "'xdotool' is not installed"
	major=$("$chrome" --version | grep -oE '[0-9]+\.' | head -1) || abort "'$chrome' is not a Chrome binary"
	USER_AGENT="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/${major}0.0.0 Safari/537.36"
	pr "Passing the Cloudflare challenge of $1 with $chrome"
	clearance=$(node cf-clearance.mjs "$chrome" "$1" "$USER_AGENT") || return 1
	printf '.apkmirror.com\tTRUE\t/\tTRUE\t0\tcf_clearance\t%s\n' "$clearance" >>"$TEMP_DIR/cookie.txt"
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
	PATCHES_RELEASE=$(gh api "repos/${PATCHES_REPO}/releases?per_page=100" --jq '[.[] | select(.prerelease == false)] | .[0]') ||
		abort "could not get releases of $PATCHES_REPO"
	PATCHES_TAG=$(jq -e -r .tag_name <<<"$PATCHES_RELEASE") || abort "$PATCHES_REPO has no stable release"
}

get_patches() {
	local asset_url
	[ "$(jq '[.assets[] | select(.name | endswith(".mpp"))] | length' <<<"$PATCHES_RELEASE")" = 1 ] ||
		abort "$PATCHES_REPO $PATCHES_TAG must have exactly one .mpp asset"
	asset_url=$(jq -r '.assets[] | select(.name | endswith(".mpp")) | .browser_download_url' <<<"$PATCHES_RELEASE")
	mkdir -p "$TEMP_DIR/patches"
	PATCHES_FILE="$TEMP_DIR/patches/${PATCHES_REPO//\//_}-${PATCHES_TAG}.mpp"
	if [ ! -f "$PATCHES_FILE" ]; then
		pr "Getting patches $PATCHES_TAG from $PATCHES_REPO"
		req "$asset_url" "$PATCHES_FILE" || abort "could not download patches"
	fi
}

check_patch_names() {
	local p
	PATCH_NAMES=$(java_isolated -jar "$CLI_JAR" list-patches --patches="$PATCHES_FILE" -f "$PKG_NAME" 2>&1 | sed -n 's/^Name: //p')
	[ -n "$PATCH_NAMES" ] || abort "could not list patches for $PKG_NAME"
	for p in "${EXCLUDED_PATCHES[@]}" "${INCLUDED_PATCHES[@]}"; do
		grep -qFx -- "$p" <<<"$PATCH_NAMES" || abort "patch '$p' does not exist in $PATCHES_REPO $PATCHES_TAG"
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
	sed -n '/Most common compatible versions:/,$p' <<<"$op" | awk -v re="$VERSION_RE" 'NR > 1 && $1 ~ re {print $1}' | sort_versions | tail -1
}

dl_archive() {
	local version=$1 base=$2 listing file
	listing=$(req "$ARCHIVE_DLURL" -) || return 1
	for file in "${PKG_NAME}-${version}-${ARCH}.apk" "${PKG_NAME}-${version}-all.apk"; do
		if grep -qF "href=\"${file}\"" <<<"$listing"; then
			pr "Downloading ${ARCHIVE_DLURL}/${file}"
			STOCK_APK="$base.apk"
			req_package "${ARCHIVE_DLURL}/${file}" "$STOCK_APK"
			return
		fi
	done
	return 1
}

apkmirror_variants() {
	python3 -c "$APKMIRROR_VARIANTS" <<<"$1"
}

sort_versions() { sort -V -u; }

apkmirror_search() {
	local resp=$1 arch=$2 type=$3 n kind arch_cell dpi_cell link apparch appdpi
	apparch=('universal' 'noarch' 'arm64-v8a + armeabi-v7a')
	if [ "$arch" != all ]; then apparch+=("$arch"); fi
	read -r -a appdpi <<<"$DPI"
	while IFS=$'\t' read -r n kind arch_cell dpi_cell link; do
		[ "$kind" = "$type" ] || continue
		if [ -z "$APP_VERSION_CODE" ]; then
			printf '%s\n' "${appdpi[@]}" | grep -qxF -- "$dpi_cell" || continue
		fi
		printf '%s\n' "${apparch[@]}" | grep -qxF -- "$arch_cell" || continue
		echo "$link"
		return 0
	done < <(apkmirror_variants "$resp")
	return 1
}

dl_apkmirror() {
	local version=$1 base=$2 arch=$ARCH ext=apk name url resp dlurl type
	if [ "$arch" = arm-v7a ]; then arch=armeabi-v7a; fi
	req "$APKMIRROR_DLURL/" - >/dev/null 2>&1 || get_cf_clearance "$APKMIRROR_DLURL" || return 1
	name=$($HTMLQ "h1.marginZero" --text <<<"$(req "$APKMIRROR_DLURL/" -)") || return 1
	name=${name,,} name=${name// /-} name=${name//[^a-z0-9-]/}
	resp=$(req "${APKMIRROR_DLURL}/${name}-${version//./-}-release/" -) || return 1
	if [ -n "$(apkmirror_variants "$resp")" ]; then
		dlurl=""
		for type in APK BUNDLE; do
			if dlurl=$(apkmirror_search "$resp" "$arch" "$type"); then
				[ "$type" = BUNDLE ] && ext=apkm
				break
			fi
			type=""
		done
		[ -n "$type" ] || { epr "no $arch variant of $version${APP_VERSION_CODE:+ ($APP_VERSION_CODE)} on APKMirror"; return 1; }
		resp=$(req "https://www.apkmirror.com${dlurl}" -) || return 1
	fi
	url=$($HTMLQ --base https://www.apkmirror.com --attribute href 'a.btn[href]' <<<"$resp" | grep -E '/download/\?key=' | head -1)
	[ -n "$url" ] || return 1
	pr "Downloading $url"
	STOCK_APK="$base.$ext"
	# Fetching the presigned R2 URL directly drops the cf_clearance cookie, which makes Cloudflare
	# answer the file request with a challenge page, so the file goes through the redirect.
	req_package "$(req "$url" - | $HTMLQ --base https://www.apkmirror.com --attribute href 'span > a[rel = nofollow]' | head -1)" "$STOCK_APK"
}

get_stock() {
	local version=$1 f
	local base="$TEMP_DIR/${PKG_NAME}-${version}-${ARCH}"
	STOCK_APK=""
	for f in "$base.apk" "$base.apkm"; do
		if [ -f "$f" ]; then STOCK_APK=$f STOCK_SOURCE=cache; fi
	done
	if [ -z "$STOCK_APK" ]; then
		if [ -n "$ARCHIVE_DLURL" ] && dl_archive "$version" "$base"; then
			STOCK_SOURCE=archive.org
		elif [ -n "$APKMIRROR_DLURL" ] && get_htmlq && dl_apkmirror "$version" "$base"; then
			STOCK_SOURCE=apkmirror
		else
			rm -f "$base".*.part
			abort "could not download $PKG_NAME $version ($ARCH)"
		fi
	fi
	verify_package "$STOCK_APK"
	STOCK_SIGNER=$(stock_signature "$STOCK_APK" "$PKG_NAME")
}

patch_app() {
	local mode=$1 out="$BUILD_DIR/$1-unsigned.apk" result="$TEMP_DIR/patch-result-$1.json" p
	local excluded=("${EXCLUDED_PATCHES[@]}")
	if [ "$mode" = module ] && grep -qFx -- "$GMSCORE_PATCH" <<<"$PATCH_NAMES"; then excluded+=("$GMSCORE_PATCH"); fi
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

	pr "Patching $APP ($mode): java ${args[*]}"
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
	jq 'del(.outputPath)' "$result" >"$BUILD_DIR/patch-result-$mode.json"
	pr "Built $out"
}

mkdir -p "$TEMP_DIR"

if [ "${2-}" = --patches-tag ]; then
	get_patches_release
	echo "$PATCHES_TAG"
	exit 0
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
get_cli
get_patches_release
get_patches
check_patch_names
version_line=$(resolve_version)
APP_VERSION=${version_line%% *}
[[ $APP_VERSION =~ $VERSION_RE ]] || abort "could not determine a $APP version (got '$APP_VERSION')"
case "$ARCH" in
arm64-v8a) abi_key=ARM64_V8A ;;
arm-v7a) abi_key=ARMEABI_V7A ;;
x86) abi_key=X86 ;;
x86_64) abi_key=X86_64 ;;
all) abi_key="" ;;
esac
APP_VERSION_CODE=""
if [ -n "$abi_key" ]; then APP_VERSION_CODE=$(sed -nE "s/.*[[ ,]${abi_key}=([0-9]+).*/\1/p" <<<"$version_line"); fi
pr "Choosing $APP $APP_VERSION${APP_VERSION_CODE:+ (version code $APP_VERSION_CODE)}"
get_stock "$APP_VERSION"
if [ "$BUILD_MODE" != apk ] && [ "${STOCK_APK##*.}" != apk ]; then abort "module needs a single stock apk, got '$STOCK_APK'"; fi

for mode in "${MODES[@]}"; do patch_app "$mode"; done
if [ "$BUILD_MODE" != apk ]; then cp -f "$STOCK_APK" "$BUILD_DIR/stock.apk"; fi

jq -n \
	--arg app "$APP" \
	--arg version "$APP_VERSION" \
	--arg patches_repo "$PATCHES_REPO" \
	--arg patches_tag "$PATCHES_TAG" \
	--arg patches_sha256 "$(sha256_of "$PATCHES_FILE")" \
	--arg cli_url "$CLI_URL" \
	--arg cli_sha256 "$CLI_SHA256" \
	--arg stock_source "$STOCK_SOURCE" \
	--arg stock_sha256 "$(sha256_of "$STOCK_APK")" \
	--arg stock_signer "$STOCK_SIGNER" \
	'$ARGS.named' >"$BUILD_DIR/build-info.json"

pr "Built $APP $APP_VERSION with $PATCHES_REPO $PATCHES_TAG ($BUILD_MODE)"
