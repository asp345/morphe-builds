#!/usr/bin/env bash

set -euo pipefail

source common.sh

[ $# = 2 ] || abort "usage: KEYSTORE=<file> KEYSTORE_PASSWORD=<password> [KEY_ALIAS=<alias>] $0 <unsigned.apk> <signed.apk>"
[ -f "${KEYSTORE-}" ] || abort "KEYSTORE must point to a keystore file"
[ -n "${KEYSTORE_PASSWORD-}" ] || abort "KEYSTORE_PASSWORD is not set"
export KEYSTORE_PASSWORD

apksigner sign \
	--ks "$KEYSTORE" \
	--ks-pass env:KEYSTORE_PASSWORD \
	--key-pass env:KEYSTORE_PASSWORD \
	--ks-key-alias "${KEY_ALIAS:-release}" \
	--v4-signing-enabled false \
	--out "$2" "$1"
apksigner verify --print-certs "$2" | grep -E '^Signer #1 certificate (DN|SHA-256 digest)'
