#!/usr/bin/env bash
[[ ! ${WARDEN_DIR} ]] && >&2 echo -e "\033[31mThis script is not intended to be run directly!\033[0m" && exit 1
set -euo pipefail

function :: {
  CYAN='\033[0;36m'
  NC='\033[0m'
  echo -e "### [$(date +%H:%M:%S)] ${CYAN}$@${NC}"
}

## load configuration needed for setup
WARDEN_ENV_PATH="$(locateEnvPath)" || exit $?
loadEnvConfig "${WARDEN_ENV_PATH}" || exit $?

assertDockerRunning

## change into the project directory
cd "${WARDEN_ENV_PATH}"

## Re-source .env to load in custom variables
source .env

## Default values
ADMIN_USER="admin"
ADMIN_PASS="adminpass12345"

while getopts u:p: flag
do
    case "${flag}" in
        u) ADMIN_USER=${OPTARG};;
        p) ADMIN_PASS=${OPTARG};;
    esac
done

:: Creating admin user

warden env exec -T php-fpm bin/magento admin:user:create \
    --admin-password="${ADMIN_PASS}" \
    --admin-user="${ADMIN_USER}" \
    --admin-firstname="Local" \
    --admin-lastname="Admin" \
    --admin-email="${ADMIN_USER}@example.com"