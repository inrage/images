#!/usr/bin/env bash

set -e

if [[ -n "${DEBUG}" ]]; then
  set -x
fi

git config --global user.email "${GIT_USER_EMAIL}"
git config --global user.name "${GIT_USER_NAME}"
git config --global --replace-all credential.https://github.com.helper ''
git config --global --add credential.https://github.com.helper \
  '!f() { set +x; if [ "$1" = get ]; then printf "username=x-access-token\npassword=%s\n" "$GITHUB_TOKEN"; fi; }; f'

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

  git clone "https://github.com/${slug}" "/tmp/${slug#*/}"
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
      if ! docker manifest inspect "php:${latest_ver}-fpm" 2>/dev/null \
        | jq -e '.manifests[]? | select(.platform.os == "linux" and .platform.architecture == "amd64")' >/dev/null; then
        echo "php:${latest_ver}-fpm is not yet published for linux/amd64, skipping"
        continue
      fi

      echo "${name^} ${version} is outdated, updating to ${latest_ver}"

      # Replace tag with sed in versions.json
      _update_referencial "${version}" "${latest_ver}"
      _regenerate_images

      _git_commit ./ "Update ${upstream} ${check_ver} to ${latest_ver}"
    else
      echo "Version ${version} is already the latest version"
    fi
  done
}

find_versions() {
  if [[ -f "./versions.json" ]]; then
    jq -r '.latest.phpVersions[] | select(.sury == null) | .tag' versions.json | tr '\n' ' '
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

_get_docker_image_digest() {
  local repo="${1}"
  local tag="${2}"
  local metadata

  if [[ ! "${repo}" =~ / ]]; then
    repo="library/${repo}"
  fi

  metadata=$(curl --fail --silent --show-error --location --connect-timeout 10 --max-time 60 \
    "https://hub.docker.com/v2/repositories/${repo}/tags/${tag}") || return

  jq -er '[.images[] | select(.os == "linux" and .architecture == "amd64") | .digest] | unique |
    if length == 1 and (.[0] | type == "string" and test("^sha256:[a-f0-9]{64}$"))
    then .[0] else error("Expected one linux/amd64 image digest") end' <<< "${metadata}"
}

_check_and_update_base_images() {
  local versions="${1}"
  local base_image="${2}"
  local identity="${3}"
  local base_name="${base_image##*/}"
  local filename=".${base_name##*-}"
  local version current latest temporary
  local -a arr_versions

  case "${identity}" in
    digest|timestamp) ;;
    *) echo "Unsupported image identity: ${identity}" >&2; return 1 ;;
  esac

  IFS=' ' read -r -a arr_versions <<< "${versions}"

  for version in "${arr_versions[@]}"; do
    current=$(awk -F '#' -v version="${version}" '$1 == version { print $2 }' "${filename}")
    if [[ -z "${current}" || "${current}" == *$'\n'* ]]; then
      echo "Expected one current identity for ${base_image}:${version}" >&2
      return 1
    fi
    if [[ "${identity}" == digest && ! "${current}" =~ ^sha256:[a-f0-9]{64}$ ]]; then
      echo "Initialize the verified digest baseline for ${base_image}:${version} before polling" >&2
      return 1
    fi

    latest=$("_get_docker_image_${identity}" "${base_image}" "${version}") || return
    if [[ -z "${latest}" || "${latest}" == null || "${latest}" == *$'\n'* ]]; then
      echo "Failed to acquire ${identity} for ${base_image}:${version}" >&2
      return 1
    fi

    if [[ "${current}" != "${latest}" ]]; then
      echo "Base image changed: ${base_image}:${version}"
      temporary=$(mktemp "${filename}.XXXXXX")
      awk -F '#' -v OFS='#' -v version="${version}" -v latest="${latest}" \
        '$1 == version { $2 = latest } { print }' "${filename}" > "${temporary}"
      mv "${temporary}" "${filename}"
    else
      echo "Base image unchanged: ${base_image}:${version}"
    fi
  done
}

_publish_base_image_updates() {
  if git diff --quiet; then
    echo "No base image changes to publish."
    return
  fi

  _git_commit ./ "chore(deps): rebuild against updated base image"
  git push origin
}

update_and_rebuild() {
  local image="${1}"
  local base_image="${2}"
  local versions="${3}"

  _git_clone "${image}"

  _check_and_update_base_images "${versions}" "${base_image}" timestamp
  _publish_base_image_updates
}
