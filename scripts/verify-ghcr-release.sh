#!/usr/bin/env bash
# Check a published release image on GHCR, not the release workflow's exit code.
#
#   scripts/verify-ghcr-release.sh <version>      for example 3.0.1 (a leading v is dropped)
#
# Passes when `latest`, `<version>` and `<major.minor>` all resolve to the same image index and
# that index lists linux/amd64 and linux/arm64 (the platforms .github/workflows/release.yml
# builds). It pulls with an anonymous token, so a pass also proves the package is public.
set -euo pipefail

image=simonbrunou/cinder
index_types='application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json'

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <version>   (for example 3.0.1)" >&2
  exit 2
fi
version=${1#v}
if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "FAIL: '$1' is not a MAJOR.MINOR.PATCH version" >&2
  exit 2
fi
minor=${version%.*}

token=$(curl -fsS --max-time 30 \
  "https://ghcr.io/token?scope=repository:${image}:pull&service=ghcr.io" | jq -r '.token // empty') ||
  token=""
if [[ -z $token ]]; then
  echo "FAIL: GHCR gave no anonymous pull token for ${image} (is the package public?)" >&2
  exit 1
fi

want=""
for tag in "$version" "$minor" latest; do
  headers=$(curl -sSI --max-time 30 -H "Authorization: Bearer ${token}" -H "Accept: ${index_types}" \
    "https://ghcr.io/v2/${image}/manifests/${tag}" | tr -d '\r')
  code=$(awk 'NR == 1 { print $2 }' <<<"$headers")
  if [[ $code == 404 ]]; then
    echo "FAIL: ghcr.io/${image}:${tag} does not exist" >&2
    exit 1
  elif [[ $code != 200 ]]; then
    echo "FAIL: GHCR answered ${code:-nothing} for ghcr.io/${image}:${tag}" >&2
    exit 1
  fi
  got=$(awk 'tolower($1) == "docker-content-digest:" { print $2 }' <<<"$headers")
  if [[ -z $got ]]; then
    echo "FAIL: GHCR sent no digest for ghcr.io/${image}:${tag}" >&2
    exit 1
  fi
  echo "${tag}: ${got}"
  if [[ -z $want ]]; then
    want=$got
  elif [[ $got != "$want" ]]; then
    echo "FAIL: ${tag} is ${got}, but ${version} is ${want}" >&2
    exit 1
  fi
done

platforms=$(curl -fsS --max-time 30 -H "Authorization: Bearer ${token}" -H "Accept: ${index_types}" \
  "https://ghcr.io/v2/${image}/manifests/${version}" |
  jq -r '[.manifests[]? | .platform | select(.os != "unknown") | "\(.os)/\(.architecture)"] | sort | join(" ")')
for platform in linux/amd64 linux/arm64; do
  if [[ " ${platforms} " != *" ${platform} "* ]]; then
    echo "FAIL: the ${version} index lists '${platforms}', not ${platform}" >&2
    exit 1
  fi
done

echo "OK: ${version}, ${minor} and latest are ${want} (${platforms})"
