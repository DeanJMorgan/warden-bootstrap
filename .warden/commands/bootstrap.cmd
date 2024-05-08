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

## configure command defaults
WARDEN_WEB_ROOT="$(echo "${WARDEN_WEB_ROOT:-/}" | sed 's#^/#./#')"
REQUIRED_FILES=("${WARDEN_WEB_ROOT}/auth.json")
DB_DUMP="${DB_DUMP:-./backfill/magento-db.sql.gz}"
DB_IMPORT=1
CLEAN_INSTALL=
AUTO_PULL=1
META_PACKAGE="magento/project-community-edition"
META_VERSION=""
URL_FRONT="https://${TRAEFIK_SUBDOMAIN}.${TRAEFIK_DOMAIN}/"
URL_ADMIN="https://${TRAEFIK_SUBDOMAIN}.${TRAEFIK_DOMAIN}/backend/"

## argument parsing
## parse arguments
while (( "$#" )); do
    case "$1" in
        --clean-install)
            CLEAN_INSTALL=1
            DB_IMPORT=
            shift
            ;;
        --meta-package)
            shift
            META_PACKAGE="$1"
            shift
            ;;
        --meta-version)
            shift
            META_VERSION="$1"
            if
                ! test $(version "${META_VERSION}") -ge "$(version 2.3.4)" \
                && [[ ! "${META_VERSION}" =~ ^2\.[3-9]\.x$ ]]
            then
                fatal "Invalid --meta-version=${META_VERSION} specified (valid values are 2.3.4 or later and 2.[3-9].x)"
            fi
            shift
            ;;
        --skip-db-import)
            DB_IMPORT=
            shift
            ;;
        --db-dump)
            shift
            DB_DUMP="$1"
            shift
            ;;
        --no-pull)
            AUTO_PULL=
            shift
            ;;
        *)
            error "Unrecognized argument '$1'"
            exit -1
            ;;
    esac
done

## if no composer.json is present in web root imply --clean-install flag when not specified explicitly
if [[ ! ${CLEAN_INSTALL} ]] && [[ ! -f "${WARDEN_WEB_ROOT}/composer.json" ]]; then
  warning "Implying --clean-install since file ${WARDEN_WEB_ROOT}/composer.json not present"
  CLEAN_INSTALL=1
  DB_IMPORT=
fi

## include check for DB_DUMP file only when database import is expected
[[ ${DB_IMPORT} ]] && REQUIRED_FILES+=("${DB_DUMP}" "${WARDEN_WEB_ROOT}/app/etc/env.php.warden.php")

:: Verifying configuration
INIT_ERROR=

## attempt to install mutagen if not already present
if [[ $OSTYPE =~ ^darwin ]] && ! which mutagen 2>/dev/null >/dev/null && which brew 2>/dev/null >/dev/null; then
    warning "Mutagen could not be found; attempting install via brew."
    brew install havoc-io/mutagen/mutagen
fi

## check for presence of host machine dependencies
for DEP_NAME in warden mutagen docker-compose pv; do
  if [[ "${DEP_NAME}" = "mutagen" ]] && [[ ! $OSTYPE =~ ^darwin ]]; then
    continue
  fi

  if ! which "${DEP_NAME}" 2>/dev/null >/dev/null; then
    error "Command '${DEP_NAME}' not found. Please install."
    INIT_ERROR=1
  fi
done

## verify warden version constraint
WARDEN_VERSION=$(warden version 2>/dev/null) || true
WARDEN_REQUIRE=0.6.0
if ! test $(version ${WARDEN_VERSION}) -ge $(version ${WARDEN_REQUIRE}); then
  error "Warden ${WARDEN_REQUIRE} or greater is required (version ${WARDEN_VERSION} is installed)"
  INIT_ERROR=1
fi

## copy global Marketplace credentials into webroot to satisfy REQUIRED_FILES list; in ideal
## configuration the per-project auth.json will already exist with project specific keys
if [[ ! -f "${WARDEN_WEB_ROOT}/auth.json" ]] && [[ -f ~/.composer/auth.json ]]; then
  if docker run --rm -v ~/.composer/auth.json:/tmp/auth.json \
      composer config -g http-basic.repo.magento.com >/dev/null 2>&1
  then
    warning "Configuring ${WARDEN_WEB_ROOT}/auth.json with global credentials for repo.magento.com"
    echo "{\"http-basic\":{\"repo.magento.com\":$(
      docker run --rm -v ~/.composer/auth.json:/tmp/auth.json composer config -g http-basic.repo.magento.com
    )}}" > ${WARDEN_WEB_ROOT}/auth.json
  fi
fi

## verify mutagen version constraint
MUTAGEN_VERSION=$(mutagen version 2>/dev/null) || true
MUTAGEN_REQUIRE=0.11.4
if [[ $OSTYPE =~ ^darwin ]] && ! test $(version ${MUTAGEN_VERSION}) -ge $(version ${MUTAGEN_REQUIRE}); then
  error "Mutagen ${MUTAGEN_REQUIRE} or greater is required (version ${MUTAGEN_VERSION} is installed)"
  INIT_ERROR=1
fi

## check for presence of local configuration files to ensure they exist
for REQUIRED_FILE in ${REQUIRED_FILES[@]}; do
  if [[ ! -f "${REQUIRED_FILE}" ]]; then
    error "Missing local file: ${REQUIRED_FILE}"
    INIT_ERROR=1
  fi
done

## exit script if there are any missing dependencies or configuration files
[[ ${INIT_ERROR} ]] && exit 1

:: Starting Warden
warden svc up
if [[ ! -f ~/.warden/ssl/certs/${TRAEFIK_DOMAIN}.crt.pem ]]; then
    warden sign-certificate ${TRAEFIK_DOMAIN}
fi

:: Initializing environment
if [[ $AUTO_PULL ]]; then
  warden env pull --ignore-pull-failures || true
  warden env build --pull
else
  warden env build
fi
warden env up -d

## wait for mariadb to start listening for connections
warden shell -c "while ! nc -z db 3306 </dev/null; do sleep 2; done"

if [[ ${CLEAN_INSTALL} ]] && [[ ! -f "${WARDEN_WEB_ROOT}/composer.json" ]]; then
  :: Installing meta-package
  warden env exec -T php-fpm composer create-project --repository-url=https://repo.magento.com/ \
      "${META_PACKAGE}" /tmp/"${WARDEN_ENV_NAME}" "${META_VERSION}"
  warden shell -c "rsync -a /tmp/${WARDEN_ENV_NAME}/ /var/www/html/"
  warden shell -c "rm -rf /tmp/${WARDEN_ENV_NAME}/"
fi

## import database only if --skip-db-import is not specified
if [[ ${DB_IMPORT} ]]; then
  :: Importing database
  warden db connect -e 'drop database magento; create database magento;'
  pv "${DB_DUMP}" | gunzip -c | warden db import
elif [[ ${CLEAN_INSTALL} ]]; then
  
  warden install-magento

  :: Configuring application
  warden env exec -T php-fpm cp -n app/etc/env.php app/etc/env.php.warden.php
  warden env exec -T php-fpm ln -fsn env.php.warden.php app/etc/env.php
  warden env exec -T php-fpm bin/magento app:config:import

  warden env exec -T php-fpm bin/magento config:set -q --lock-env web/unsecure/base_url ${URL_FRONT}
  warden env exec -T php-fpm bin/magento config:set -q --lock-env web/secure/base_url ${URL_FRONT}

  warden env exec -T php-fpm bin/magento deploy:mode:set -s developer
  warden env exec -T php-fpm bin/magento cache:disable block_html full_page
  warden env exec -T php-fpm bin/magento app:config:dump themes scopes i18n

  :: Rebuilding indexes
  warden env exec -T php-fpm bin/magento indexer:reindex
fi

if [[ ! ${CLEAN_INSTALL} ]]; then
  :: Installing dependencies
  warden env exec -T php-fpm composer install

  :: Configuring application
  warden env exec -T php-fpm ln -fsn env.php.warden.php app/etc/env.php
  warden env exec -T php-fpm bin/magento cache:flush -q
  warden env exec -T php-fpm bin/magento app:config:import

  :: bin/magento setup:db-schema:upgrade
  warden env exec -T php-fpm php -d memory_limit=-1 bin/magento setup:db-schema:upgrade

  :: bin/magento setup:db-data:upgrade
  warden env exec -T php-fpm php -d memory_limit=-1 bin/magento setup:db-data:upgrade
fi

:: Flushing cache
warden env exec -T php-fpm bin/magento cache:flush
warden env exec -T php-fpm bin/magento cache:disable block_html full_page

:: Creating admin user
ADMIN_PASS=$(warden env exec -T php-fpm pwgen -n1 16)
ADMIN_USER=localadmin

warden env exec -T php-fpm bin/magento admin:user:create \
    --admin-password="${ADMIN_PASS}" \
    --admin-user="${ADMIN_USER}" \
    --admin-firstname="Local" \
    --admin-lastname="Admin" \
    --admin-email="${ADMIN_USER}@example.com"

:: Initialization complete
function print_install_info {
    FILL=$(printf "%0.s-" {1..128})
    C1_LEN=8
    let "C2_LEN=${#URL_ADMIN}>${#ADMIN_PASS}?${#URL_ADMIN}:${#ADMIN_PASS}"

    # note: in CentOS bash .* isn't supported (is on Darwin), but *.* is more cross-platform
    printf "+ %*.*s + %*.*s + \n" 0 $C1_LEN $FILL 0 $C2_LEN $FILL
    printf "+ %-*s + %-*s + \n" $C1_LEN FrontURL $C2_LEN "$URL_FRONT"
    printf "+ %*.*s + %*.*s + \n" 0 $C1_LEN $FILL 0 $C2_LEN $FILL
    printf "+ %-*s + %-*s + \n" $C1_LEN AdminURL $C2_LEN "$URL_ADMIN"
    printf "+ %*.*s + %*.*s + \n" 0 $C1_LEN $FILL 0 $C2_LEN $FILL
    printf "+ %-*s + %-*s + \n" $C1_LEN Username $C2_LEN "$ADMIN_USER"
    printf "+ %*.*s + %*.*s + \n" 0 $C1_LEN $FILL 0 $C2_LEN $FILL
    printf "+ %-*s + %-*s + \n" $C1_LEN Password $C2_LEN "$ADMIN_PASS"
    printf "+ %*.*s + %*.*s + \n" 0 $C1_LEN $FILL 0 $C2_LEN $FILL
}
print_install_info
