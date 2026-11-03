#!/usr/bin/env bash

APKSIGNER="bin/apksigner.jar"
APKSIGNER_SHA256="eefdd6aed9db9fb849e4c98a50d8741e19d1b674ba6547220bcb9c3ed152123a"

pr() { echo >&2 -e "\033[0;32m[+] ${1}\033[0m"; }
epr() { echo >&2 -e "\033[0;31m[-] ${1}\033[0m"; }
abort() {
	epr "ABORT: ${1}"
	exit 1
}

JAVA_BIN=$(command -v java) || abort "'java' is not installed"
if [ -n "${JAVA_HOME_21_X64-}" ]; then JAVA_BIN="$JAVA_HOME_21_X64/bin/java"; fi

sha256_of() { sha256sum "$1" | cut -d' ' -f1; }
verify_sha256() {
	local actual
	actual=$(sha256_of "$1")
	[ "$actual" = "$2" ] || abort "sha256 mismatch for '$1': expected $2, got $actual"
}

apksigner() {
	verify_sha256 "$APKSIGNER" "$APKSIGNER_SHA256"
	"$JAVA_BIN" -jar "$APKSIGNER" "$@"
}

config_json() {
	python3 -I -c 'import json, sys, tomllib; print(json.dumps(tomllib.load(open(sys.argv[1], "rb"))))' "$1" ||
		abort "could not parse $1"
}

app_cfg() {
	config_json config.toml | jq -r --arg a "$1" --arg k "$2" --arg d "${3-}" '.[$a][$k] // $d | strings'
}

apk_signer() {
	apksigner verify --print-certs "$1" | grep '^Signer' | grep 'SHA-256' | tail -1 | awk '{print $NF}'
}

stock_signature() {
	local file=$1 pkg=$2 expected sig apk dir
	expected=$(awk -v p="$pkg" '$2 == p {print $1}' sig.txt)
	if [ "${file##*.}" = apkm ]; then
		dir=$(mktemp -d)
		python3 -I -c 'import os, sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
for n in z.namelist():
    if n.endswith(".apk"):
        open(os.path.join(sys.argv[2], os.path.basename(n)), "wb").write(z.read(n))' "$file" "$dir" ||
			abort "could not read bundle '$file'"
		set -- "$dir"/*.apk
		[ $# -gt 0 ] || abort "no apks in bundle '$file'"
	else
		set -- "$file"
	fi
	for apk in "$@"; do
		sig=$(apk_signer "$apk") || abort "apksigner could not verify '$apk'"
		if [ -z "$expected" ]; then
			apksigner verify --print-certs "$apk" | grep '^Signer' >&2
			abort "no signature for $pkg in sig.txt (stock signer: $sig)"
		fi
		[ "$sig" = "$expected" ] || abort "stock signature mismatch in '${apk##*/}': expected $expected, got '$sig'"
	done
	[ -z "${dir-}" ] || rm -rf "$dir"
	echo "$sig"
}
