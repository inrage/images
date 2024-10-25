#!/usr/bin/env bash

set -e

if [[ -n "${DEBUG}" ]]; then
  set -x
fi

git config --global user.email "${GIT_USER_EMAIL}"
git config --global user.name "${GIT_USER_NAME}"

_git_commit() {
  local dir="${1}"
  local msg="${2}"

  cd "${dir}"
  git update-index -q --refresh

  if [[ "$(git diff-index --name-only HEAD --)" ]]; then
    git commit -am "${msg}"
  else
    echo 'Nothing to commit'
  fi
}

_release_tag() {
  local message="${1}"
  local minor_update="${2}"
  local tag

  IFS="." read -r -a sem_ver <<<$(git describe --abbrev=0 --tags)

  # Minor version changed.
  if [[ -n "${minor_update}" ]]; then
    ((++sem_ver[1]))
    sem_ver[2]=0
  # Patch version changed.
  else
    ((++sem_ver[2]))
  fi

  tag=$(_join_ws "." "${sem_ver[@]}")

  git tag -m "${message}" "${tag}"
  git push origin "${tag}"
}

_git_clone() {
  local slug="${1}"

  git clone "https://${GITHUB_MACHINE_USER}:${GITHUB_MACHINE_USER_API_TOKEN}@github.com/${slug}" "/tmp/${slug#*/}"
  cd "/tmp/${slug#*/}"
}

_get_image_tags() {
  local slug="${1%:*}"
  local filter="${2}"
  local search="${3:-''}"

  local namespace=${slug%/*}
  local repo=${slug#*/}
  if [[ "${namespace}" == "${slug}" ]]; then
    namespace="library"
  fi

  local url="https://hub.docker.com/v2/namespaces/${namespace}/repositories/${repo}/tags?name=${search}"

  for page in {1..10}; do
    res=$(wget -q "${url}&page=${page}&page_size=100" -O - | jq -r '.results[].name' | grep -oP "${filter}" | sort -rV | head -n1)
    if [[ -n "${res}" ]]; then
      echo "${res}"
      exit 0
    fi
  done

  echo "Failed to find tags in ${slug} with filter ${filter}"
  exit 1
}

_update_referencial() {
  local version="${1}"
  local latest_ver="${2}"
  # Replace tag with sed in versions.json
  sed -i 's/"tag": "'${version}'"/"tag": "'${latest_ver}'"/' versions.json
}

_regenerate_images() {
  ./apply-templates.sh
}

_update_versions() {
  local versions="${1}"
  local upstream="${2%:*}"
  local name="${3}"

  local updated=()

  IFS=' ' read -r -a arr_versions <<<"${versions}"

  echo "============================"
  echo "Checking for version updates"
  echo "============================"

  for version in "${arr_versions[@]}"; do
    echo "Checking version: ${version}"

    local suffix="(?=\-apache$)"

    # from version X.X.X to X.X
    local check_ver=$(echo "${version}" | cut -d. -f1,2)
    latest_ver=$(_get_image_tags "php" "^(${check_ver//\./\\.}\.[0-9\.]+)${suffix}" "apache")

    if [[ -z "${latest_ver}" ]]; then
      echo >&2 "Couldn't find latest version of ${version}."
      exit 1
    fi

    if [[ $(compare_semver "${latest_ver}" "${version}") == 0 ]]; then
      echo "${name^} ${version} is outdated, updating to ${latest_ver}"

      # Replace tag with sed in versions.json
      _update_referencial "${version}" "${latest_ver}"
      _regenerate_images

      _git_commit ./ "Update ${upstream} ${check_ver} to ${latest_ver}"
      updated+=("${latest_ver}")
    else
      echo "Version ${version} is already the latest version"
    fi
  done

  if [[ "${#updated[@]}" != 0 ]]; then
    git push origin
  fi
}

find_versions() {
  if [[ -f "./versions.json" ]]; then
    jq -r '.latest.phpVersions[] | "\(.tag)"' versions.json | tr '\n' ' '
  else
    echo "versions.json not found"
    exit 1
  fi
}

update_from_base_image() {
  local image="${1}"
  local base_image="${2}"

  _git_clone "${image}"

  versions=$(find_versions)

  _update_versions "${versions}" "${base_image}" "${image#*/}"
}

_get_docker_image_timestamp() {
  local repo="${1}"
  local tag="${2}"

  if [[ ! "${repo}" =~ / ]]; then
    repo="library/${repo}"
  fi

  local url="https://hub.docker.com/v2/repositories/${repo}/tags/${tag}/"

  curl -L -s "https://hub.docker.com/v2/repositories/${repo}/tags/${tag}" | jq -r '.last_updated'
}

_check_and_update_timestamps() {
  local versions="${1}"
  local base_image="${2}"
  local base_filename="${3}"

  local updated

  IFS=' ' read -r -a arr_versions <<<"${versions}"

  echo "=============================="
  echo "Checking for timestamp updates"
  echo "=============================="

  for version in "${arr_versions[@]}"; do

    local new_version_timestamp
    local cur_timestamp

    echo "Checking version: ${base_filename} ${version}"
    new_version_timestamp=$(_get_docker_image_timestamp "${base_filename}" "${version}")

    if [[ -z "${new_version_timestamp}" ]]; then
      echo >&2 "Failed to acquire latest timestamp from Docker"
      exit 1
    fi

    local filename=".${base_filename##*-}"

    cur_timestamp=$(cat "${filename}" | grep "^${version}" | grep -oP "(?<=#)(.+)$")

    if [[ -z "${cur_timestamp}" ]]; then
      echo >&2 "Failed to acquire current timestamp"
      exit 1
    fi

    if [[ "${cur_timestamp}" != "${new_version_timestamp}" ]]; then
      echo "Timestamp for ${version} (${cur_timestamp}) is outdated, updating to ${new_version_timestamp}"
      sed -i "s/${version}#${cur_timestamp}/${version}#${new_version_timestamp}/" "${filename}"
      updated=1
    fi

  done

  if [[ -n "${updated}" ]]; then
    echo "Committing changes..."
    _git_commit ./ "chore(deps): rebuild against updated base image"

    git push origin
  else
    echo "No changes detected in timestamps."
  fi
}

update_and_rebuild() {
  local image="${1}"
  local base_image="${2}"
  local versions="${3}"

  _git_clone "${image}"

  _check_and_update_timestamps "${versions}" "${image}" "${base_image}"
}
