#!/usr/bin/env bash

set -euo pipefail

source common.sh

CONFIG_FILE=${1:-config.toml}
CONFIG=$(config_json "$CONFIG_FILE")
repo=$(jq -r '."cli-repo" // empty' <<<"$CONFIG")
current_url=$(jq -r '."cli-url" // empty' <<<"$CONFIG")
[[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || abort "invalid cli-repo '$repo'"

release=$(gh api "repos/$repo/releases/latest") || abort "could not get latest release of $repo"
tag=$(jq -r .tag_name <<<"$release")
[[ $tag =~ ^v[0-9]+(\.[0-9]+)+$ ]] || abort "unexpected tag '$tag' in $repo"
[ "$(jq '[.assets[] | select(.name | endswith("-all.jar"))] | length' <<<"$release")" = 1 ] ||
	abort "$repo $tag must have exactly one -all.jar asset"
url=$(jq -r '.assets[] | select(.name | endswith("-all.jar")) | .browser_download_url' <<<"$release")
digest=$(jq -r '.assets[] | select(.name | endswith("-all.jar")) | .digest // empty' <<<"$release")
[[ $url =~ ^https://github\.com/${repo}/releases/download/${tag}/[A-Za-z0-9_.-]+-all\.jar$ ]] || abort "unexpected asset url '$url'"
[[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || abort "asset of $repo $tag has no sha256 digest"

if [ "$url" = "$current_url" ]; then
	pr "CLI is up to date ($tag)"
	exit 0
fi

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
curl -sSfL --connect-timeout 10 --retry 2 "$url" -o "$tmp" || abort "could not download $url"
verify_sha256 "$tmp" "${digest#sha256:}"

sed -i -E \
	-e "s|^cli-url = \".*\"$|cli-url = \"$url\"|" \
	-e "s|^cli-sha256 = \".*\"$|cli-sha256 = \"${digest#sha256:}\"|" \
	"$CONFIG_FILE"
[ "$(config_json "$CONFIG_FILE" | jq -r '."cli-url"')" = "$url" ] || abort "could not update cli-url in $CONFIG_FILE"
pr "CLI bumped to $tag"
echo "$tag"
