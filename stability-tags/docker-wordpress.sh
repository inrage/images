#!/usr/bin/env bash

set -e

. ../update.sh

_git_clone "inrage/docker-wordpress"

_check_and_update_timestamps "8.1 8.2 8.3 8.4" "inrage/docker-wordpress" "inrage/docker-php"
_check_and_update_timestamps "8.4" "inrage/docker-wordpress" "inrage/frankenphp"
