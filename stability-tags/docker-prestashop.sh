#!/usr/bin/env bash

set -e

. ../update.sh

check_prestashop_updates() {
  local repo="inrage/docker-prestashop"

  _git_clone "${repo}"

  _check_debian_timestamp
  _check_sury_versions
}

_check_debian_timestamp() {
  echo "=============================="
  echo "Checking Debian base timestamp"
  echo "=============================="

  local new_timestamp
  new_timestamp=$(_get_docker_image_timestamp "library/debian" "bookworm-slim")

  if [[ -z "${new_timestamp}" ]]; then
    echo >&2 "Failed to get debian:bookworm-slim timestamp"
    exit 1
  fi

  local cur_timestamp
  cur_timestamp=$(grep -oP '(?<=#)(.+)$' .debian)

  if [[ -z "${cur_timestamp}" ]]; then
    echo >&2 "Failed to read current timestamp from .debian"
    exit 1
  fi

  echo "Current: ${cur_timestamp}"
  echo "Latest:  ${new_timestamp}"

  if [[ "${cur_timestamp}" != "${new_timestamp}" ]]; then
    echo "Debian base image updated, triggering rebuild"
    sed -i "s|bookworm-slim#${cur_timestamp}|bookworm-slim#${new_timestamp}|" .debian
    _git_commit ./ "chore(deps): rebuild against updated debian base image"
    git push origin
  else
    echo "Debian base image is up to date"
  fi
}

_check_sury_versions() {
  echo "=============================="
  echo "Checking PHP versions from Sury"
  echo "=============================="

  local updated

  for phpVersion in $(jq -r '.phpVersions[]' versions.json); do
    local current_php
    current_php=$(jq -r ".versions[\"${phpVersion}\"].php" versions.json)

    echo "Checking PHP ${phpVersion} (current: ${current_php})"

    local latest_php
    latest_php=$(docker run --rm --entrypoint bash "inrage/docker-prestashop:${phpVersion}" \
      -c "apt-get update -qq > /dev/null 2>&1 && apt-cache policy php${phpVersion} \
      | grep Candidate | awk '{print \$2}' | cut -d'-' -f1 | cut -d'+' -f1")

    if [[ -z "${latest_php}" ]]; then
      echo >&2 "Failed to get PHP ${phpVersion} version from Sury"
      continue
    fi

    local latest_apache
    latest_apache=$(docker run --rm --entrypoint bash "inrage/docker-prestashop:${phpVersion}" \
      -c "apt-get update -qq > /dev/null 2>&1 && apt-cache policy apache2 \
      | grep Candidate | awk '{print \$2}' | cut -d'-' -f1 | cut -d'+' -f1")

    echo "PHP ${phpVersion}: installed=${current_php} available=${latest_php} apache=${latest_apache}"

    if [[ "${current_php}" != "${latest_php}" ]]; then
      echo "Updating PHP ${phpVersion}: ${current_php} -> ${latest_php}"
      jq --arg v "${phpVersion}" --arg php "${latest_php}" \
        '.versions[$v].php = $php' versions.json > tmp.json && mv tmp.json versions.json
      updated=1
    fi

    if [[ -n "${latest_apache}" ]]; then
      local current_apache
      current_apache=$(jq -r ".versions[\"${phpVersion}\"].apache" versions.json)
      if [[ "${current_apache}" != "${latest_apache}" ]]; then
        echo "Updating Apache for ${phpVersion}: ${current_apache} -> ${latest_apache}"
        jq --arg v "${phpVersion}" --arg apache "${latest_apache}" \
          '.versions[$v].apache = $apache' versions.json > tmp.json && mv tmp.json versions.json
        updated=1
      fi
    fi
  done

  if [[ -n "${updated}" ]]; then
    echo "Regenerating README..."
    ./update-readme.sh
    _git_commit ./ "chore(deps): update PHP/Apache versions from Sury"
    git push origin
  else
    echo "All PHP/Apache versions are up to date"
  fi
}

check_prestashop_updates
