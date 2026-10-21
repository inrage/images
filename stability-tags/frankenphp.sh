#!/usr/bin/env bash

set -e

. ../update.sh

update_and_rebuild "inrage/frankenphp" "dunglas/frankenphp" "1-php8.4"
