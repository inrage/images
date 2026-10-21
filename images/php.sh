#!/usr/bin/env bash

set -e

. ../update.sh

_update_sury_versions() {
  local index="/tmp/sury-trixie-packages"
  local updated=()

  echo "==============================="
  echo "Checking Sury package revisions"
  echo "==============================="

  if ! wget -q -O - "https://packages.sury.org/php/dists/trixie/main/binary-amd64/Packages.gz" | gunzip -c >"${index}" || [[ ! -s "${index}" ]]; then
    echo >&2 "Failed to fetch Sury package index"
    exit 1
  fi

  for folder in $(jq -r '.latest.phpVersions[] | select(.sury != null) | .folder' versions.json); do
    local current
    local latest

    current=$(jq -r --arg f "${folder}" '.latest.phpVersions[] | select(.folder == $f) | .sury' versions.json)
    latest=$(awk -v pkg="php${folder}-cli" '$1=="Package:"{p=($2==pkg)} p&&$1=="Version:"{print $2; exit}' "${index}")

    echo "Checking PHP ${folder} Sury package: ${current}"

    if [[ -z "${latest}" ]]; then
      echo >&2 "Couldn't find php${folder}-cli in the Sury index"
      exit 1
    fi

    if [[ "${current}" != "${latest}" ]]; then
      echo "PHP ${folder} Sury package is outdated, updating to ${latest}"
      sed -i "s|\"sury\": \"${current//./\\.}\"|\"sury\": \"${latest}\"|" versions.json
      _regenerate_images
      _git_commit ./ "Update PHP ${folder} Sury package to ${latest}"
      updated+=("${latest}")
    else
      echo "PHP ${folder} Sury package is already the latest version"
    fi
  done

  if [[ "${#updated[@]}" != 0 ]]; then
    git push origin
  fi
}

update_from_base_image "inrage/docker-php" "php"

_update_sury_versions
