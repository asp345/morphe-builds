#!/usr/bin/env bash

PKG_NAME="com.google.android.youtube"
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

stock_signature() {
	local expected sig
	expected=$(awk -v p="$PKG_NAME" '$2 == p {print $1}' sig.txt)
	[ -n "$expected" ] || abort "no signature for $PKG_NAME in sig.txt"
	sig=$(apksigner verify --print-certs "$1" | grep '^Signer' | grep 'SHA-256' | tail -1 | awk '{print $NF}') ||
		abort "apksigner could not verify '$1'"
	[ "$sig" = "$expected" ] || abort "stock apk signature mismatch: expected $expected, got '$sig'"
	echo "$sig"
}

config_json() {
	python3 -I -c 'import json, sys, tomllib; print(json.dumps(tomllib.load(open(sys.argv[1], "rb"))))' "$1" ||
		abort "could not parse $1"
}
