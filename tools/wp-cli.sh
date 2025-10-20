#!/usr/bin/env bash

set -e

. ../update.sh

update_tool_version() {
  local repo="inrage/docker-wordpress"

  _git_clone "${repo}"

  echo "============================"
  echo "Checking WP-CLI version"
  echo "============================"

  latest_wpcli=$(curl -s "https://api.github.com/repos/wp-cli/wp-cli/releases/latest" | jq -r '.tag_name' | sed 's/^v//')
  current_wpcli=$(jq -r '.wpCliVersion' versions.json)

  if [[ -z "${latest_wpcli}" ]]; then
    echo >&2 "Failed to acquire latest WP-CLI version from GitHub"
    exit 1
  fi

  if [[ -z "${current_wpcli}" ]]; then
    echo >&2 "Failed to acquire current WP-CLI version from versions.json"
    exit 1
  fi

  echo "Current WP-CLI version: ${current_wpcli}"
  echo "Latest WP-CLI version: ${latest_wpcli}"

  if [[ "${latest_wpcli}" != "${current_wpcli}" ]]; then
    echo "WP-CLI ${current_wpcli} is outdated, updating to ${latest_wpcli}"

    jq --arg ver "${latest_wpcli}" '.wpCliVersion = $ver' versions.json > tmp.json && mv tmp.json versions.json

    _regenerate_images
    _git_commit ./ "chore: update WP-CLI to ${latest_wpcli}"
    git push origin
  else
    echo "WP-CLI ${current_wpcli} is already the latest version"
  fi
}

update_tool_version
