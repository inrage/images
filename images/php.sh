#!/usr/bin/env bash

set -e

. ../update.sh

update_from_base_image "inrage/docker-php" "php"
