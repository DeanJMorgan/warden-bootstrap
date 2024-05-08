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

INSTALL_FLAGS=""

## rabbitmq
if [[ ${WARDEN_RABBITMQ} == 1 ]]; then
  INSTALL_FLAGS="${INSTALL_FLAGS} --amqp-host=rabbitmq
    --amqp-port=5672
    --amqp-user=guest 
    --amqp-password=guest "
fi

## redis
if [[ ${WARDEN_REDIS} == 1 ]]; then
  INSTALL_FLAGS="${INSTALL_FLAGS} --session-save=redis
    --session-save-redis-host=redis
    --session-save-redis-port=6379
    --session-save-redis-db=2
    --session-save-redis-max-concurrency=20
    --cache-backend=redis
    --cache-backend-redis-server=redis
    --cache-backend-redis-db=0
    --cache-backend-redis-port=6379
    --page-cache=redis
    --page-cache-redis-server=redis
    --page-cache-redis-db=1
    --page-cache-redis-port=6379 "
fi

## varnish
if [[ ${WARDEN_VARNISH} == 1 ]]; then
  INSTALL_FLAGS="${INSTALL_FLAGS} --http-cache-hosts=varnish:80 "
fi

INSTALL_FLAGS="${INSTALL_FLAGS} \
  --search-engine=opensearch \
  --opensearch-host=opensearch \
  --opensearch-port=9200 \
  --opensearch-index-prefix=magento2 \
  --opensearch-enable-auth=0 \
  --opensearch-timeout=15 \
  --cleanup-database \
  --backend-frontname=backend \
  --db-host=db \
  --db-name=magento \
  --db-user=magento \
  --db-password=magento"

:: Installing application
warden env exec -T php-fpm bin/magento setup:install $(echo ${INSTALL_FLAGS})