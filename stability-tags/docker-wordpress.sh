#!/usr/bin/env bash

set -e

. ../update.sh

update_and_rebuild "inrage/docker-wordpress" "inrage/docker-php" "8.1 8.2 8.3 8.4"
