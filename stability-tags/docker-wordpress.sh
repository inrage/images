#!/usr/bin/env bash

set -e

. ../update.sh

_git_clone "inrage/docker-wordpress"

_check_and_update_base_images "8.1 8.2 8.3 8.4" "inrage/docker-php" digest
_check_and_update_base_images "8.4" "inrage/frankenphp" digest
_publish_base_image_updates
