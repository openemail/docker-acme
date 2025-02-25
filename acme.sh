#!/bin/bash
set -o pipefail
exec 5>&1

source /srv/functions.sh
# Thanks to https://github.com/cvmiller -> https://github.com/cvmiller/expand6
source /srv/expand6.sh

# Skipping IP check when we like to live dangerously
if [[ "${SKIP_IP_CHECK}" =~ ^([yY][eE][sS]|[yY])+$ ]]; then
  SKIP_IP_CHECK=y
fi

# Skipping HTTP check when we like to live dangerously
if [[ "${SKIP_HTTP_VERIFICATION}" =~ ^([yY][eE][sS]|[yY])+$ ]]; then
  SKIP_HTTP_VERIFICATION=y
fi

# Request certificate for OPENEMAIL_HOSTNAME only
if [[ "${ONLY_OPENEMAIL_HOSTNAME}" =~ ^([yY][eE][sS]|[yY])+$ ]]; then
  ONLY_OPENEMAIL_HOSTNAME=y
fi

# Request individual certificate for every domain
if [[ "${ENABLE_SSL_SNI}" =~ ^([yY][eE][sS]|[yY])+$ ]]; then
  ENABLE_SSL_SNI=y
fi

if [[ "${SKIP_LETS_ENCRYPT}" =~ ^([yY][eE][sS]|[yY])+$ ]]; then
  log_f "SKIP_LETS_ENCRYPT=y, skipping Let's Encrypt..."
  sleep 365d
  exec $(readlink -f "$0")
fi

log_f "Waiting for Docker API..." no_nl
until ping dockerapi -c1 > /dev/null; do
  sleep 1
done
log_f "OK" no_date

ACME_BASE=/var/lib/acme
SSL_EXAMPLE=/var/lib/ssl-example

mkdir -p ${ACME_BASE}/acme

# Migrate
[[ -f ${ACME_BASE}/acme/private/privkey.pem ]] && mv ${ACME_BASE}/acme/private/privkey.pem ${ACME_BASE}/acme/key.pem
[[ -f ${ACME_BASE}/acme/private/account.key ]] && mv ${ACME_BASE}/acme/private/account.key ${ACME_BASE}/acme/account.pem
if [[ -f ${ACME_BASE}/acme/key.pem && -f ${ACME_BASE}/acme/cert.pem ]]; then
  if verify_hash_match ${ACME_BASE}/acme/cert.pem ${ACME_BASE}/acme/key.pem; then
    log_f "Migrating to SNI folder structure..." no_nl
    CERT_DOMAIN=($(openssl x509 -noout -text -in ${ACME_BASE}/acme/cert.pem | grep "Subject:" | sed -e 's/\(Subject:\)\|\(CN = \)\|\(CN=\)//g' | sed -e 's/^[[:space:]]*//'))
    CERT_DOMAINS=(${CERT_DOMAIN} $(openssl x509 -noout -text -in ${ACME_BASE}/acme/cert.pem | grep "DNS:" | sed -e 's/\(DNS:\)\|,//g' | sed "s/${CERT_DOMAIN}//" | sed -e 's/^[[:space:]]*//'))
    mkdir -p ${ACME_BASE}/${CERT_DOMAIN}
    mv ${ACME_BASE}/acme/cert.pem ${ACME_BASE}/${CERT_DOMAIN}/cert.pem
    # key is only copied, not moved, because it is used by all other requests too
    cp ${ACME_BASE}/acme/key.pem ${ACME_BASE}/${CERT_DOMAIN}/key.pem
    chmod 600 ${ACME_BASE}/${CERT_DOMAIN}/key.pem
    echo -n ${CERT_DOMAINS[*]} > ${ACME_BASE}/${CERT_DOMAIN}/domains
    mv ${ACME_BASE}/acme/acme.csr ${ACME_BASE}/${CERT_DOMAIN}/acme.csr
    log_f "OK" no_date
  fi
fi

[[ ! -f ${ACME_BASE}/dhparams.pem ]] && cp ${SSL_EXAMPLE}/dhparams.pem ${ACME_BASE}/dhparams.pem

if [[ -f ${ACME_BASE}/cert.pem ]] && [[ -f ${ACME_BASE}/key.pem ]] && [[ $(stat -c%s ${ACME_BASE}/cert.pem) != 0 ]]; then
  ISSUER=$(openssl x509 -in ${ACME_BASE}/cert.pem -noout -issuer)
  if [[ ${ISSUER} != *"Let's Encrypt"* && ${ISSUER} != *"mailcow"* && ${ISSUER} != *"Fake LE Intermediate"* ]]; then
    log_f "Found certificate with issuer other than mailcow snake-oil CA and Let's Encrypt, skipping ACME client..."
    sleep 3650d
    exec $(readlink -f "$0")
  fi
else
  if [[ -f ${ACME_BASE}/${OPENEMAIL_HOSTNAME}/cert.pem ]] && [[ -f ${ACME_BASE}/${OPENEMAIL_HOSTNAME}/key.pem ]] && verify_hash_match ${ACME_BASE}/${OPENEMAIL_HOSTNAME}/cert.pem ${ACME_BASE}/${OPENEMAIL_HOSTNAME}/key.pem; then
    log_f "Restoring previous acme certificate and restarting script..."
    cp ${ACME_BASE}/${OPENEMAIL_HOSTNAME}/cert.pem ${ACME_BASE}/cert.pem
    cp ${ACME_BASE}/${OPENEMAIL_HOSTNAME}/key.pem ${ACME_BASE}/key.pem
    # Restarting with env var set to trigger a restart,
    exec env TRIGGER_RESTART=1 $(readlink -f "$0")
  else
    log_f "Restoring mailcow snake-oil certificates and restarting script..."
    cp ${SSL_EXAMPLE}/cert.pem ${ACME_BASE}/cert.pem
    cp ${SSL_EXAMPLE}/key.pem ${ACME_BASE}/key.pem
    exec env TRIGGER_RESTART=1 $(readlink -f "$0")
  fi
fi

chmod 600 ${ACME_BASE}/key.pem

log_f "Waiting for database... " no_nl
while ! mysqladmin status --socket=/var/run/mysqld/mysqld.sock -u${DBUSER} -p${DBPASS} --silent; do
  sleep 2
done
log_f "OK" no_date

log_f "Waiting for Nginx... " no_nl
until $(curl --output /dev/null --silent --head --fail http://nginx:8081); do
  sleep 2
done
log_f "OK" no_date

# Waiting for domain table
log_f "Waiting for domain table... " no_nl
while [[ -z ${DOMAIN_TABLE} ]]; do
  curl --silent http://nginx/ >/dev/null 2>&1
  DOMAIN_TABLE=$(mysql --socket=/var/run/mysqld/mysqld.sock -u ${DBUSER} -p${DBPASS} ${DBNAME} -e "SHOW TABLES LIKE 'domain'" -Bs)
  [[ -z ${DOMAIN_TABLE} ]] && sleep 10
done
log_f "OK" no_date

log_f "Initializing, please wait... "

while true; do

  # Re-using previous acme-openemail account and domain keys
  if [[ ! -f ${ACME_BASE}/acme/key.pem ]]; then
    log_f "Generating missing domain private rsa key..."
    openssl genrsa 4096 > ${ACME_BASE}/acme/key.pem
  else
    log_f "Using existing domain rsa key ${ACME_BASE}/acme/key.pem"
  fi
  if [[ ! -f ${ACME_BASE}/acme/account.pem ]]; then
    log_f "Generating missing Lets Encrypt account key..."
    openssl genrsa 4096 > ${ACME_BASE}/acme/account.pem
  else
    log_f "Using existing Lets Encrypt account key ${ACME_BASE}/acme/account.pem"
  fi

  chmod 600 ${ACME_BASE}/acme/key.pem
  chmod 600 ${ACME_BASE}/acme/account.pem

  unset EXISTING_CERTS
  declare -a EXISTING_CERTS
  for cert_dir in ${ACME_BASE}/*/ ; do
    if [[ ! -f ${cert_dir}domains ]] || [[ ! -f ${cert_dir}cert.pem ]] || [[ ! -f ${cert_dir}key.pem ]]; then
      continue
    fi
    EXISTING_CERTS+=("$(basename ${cert_dir})")
  done

  # Cleaning up and init validation arrays
  unset SQL_DOMAIN_ARR
  unset VALIDATED_CONFIG_DOMAINS
  unset ADDITIONAL_VALIDATED_SAN
  unset ADDITIONAL_WC_ARR
  unset ADDITIONAL_SAN_ARR
  unset CERT_ERRORS
  unset CERT_CHANGED
  unset CERT_AMOUNT_CHANGED
  unset VALIDATED_CERTIFICATES
  CERT_ERRORS=0
  CERT_CHANGED=0
  CERT_AMOUNT_CHANGED=0
  declare -a SQL_DOMAIN_ARR
  declare -a VALIDATED_CONFIG_DOMAINS
  declare -a ADDITIONAL_VALIDATED_SAN
  declare -a ADDITIONAL_WC_ARR
  declare -a ADDITIONAL_SAN_ARR
  declare -a VALIDATED_CERTIFICATES
  IFS=',' read -r -a TMP_ARR <<< "${ADDITIONAL_SAN}"
  for i in "${TMP_ARR[@]}" ; do
    if [[ "$i" =~ \.\*$ ]]; then
      ADDITIONAL_WC_ARR+=(${i::-2})
    else
      ADDITIONAL_SAN_ARR+=($i)
    fi
  done
  ADDITIONAL_WC_ARR+=('autodiscover' 'autoconfig')

  # Start IP detection
  log_f "Detecting IP addresses... " no_nl
  IPV4=$(get_ipv4)
  IPV6=$(get_ipv6)
  log_f "OK" no_date

  # Hard-fail on CAA errors for OPENEMAIL_HOSTNAME
  MH_PARENT_DOMAIN=$(echo ${OPENEMAIL_HOSTNAME} | cut -d. -f2-)
  MH_CAAS=( $(dig CAA ${MH_PARENT_DOMAIN} +short | sed -n 's/\d issue "\(.*\)"/\1/p') )
  if [[ ! -z ${MH_CAAS} ]]; then
    if [[ ${MH_CAAS[@]} =~ "letsencrypt.org" ]]; then
      log_f "Validated CAA for parent domain ${MH_PARENT_DOMAIN}"
    else
      log_f "Skipping ACME validation: Lets Encrypt disallowed for ${OPENEMAIL_HOSTNAME} by CAA record, retrying in 1h..."
      sleep 1h
      exec $(readlink -f "$0")
    fi
  fi

  #########################################
  # IP and webroot challenge verification #
  SQL_DOMAINS=$(mysql --socket=/var/run/mysqld/mysqld.sock -u ${DBUSER} -p${DBPASS} ${DBNAME} -e "SELECT domain FROM domain WHERE backupmx=0" -Bs)
  if [[ ! $? -eq 0 ]]; then
    log_f "Failed to read SQL domains, retrying in 1 minute..."
    sleep 1m
    exec $(readlink -f "$0")
  fi
  while read domains; do
    if [[ -z "${domains}" ]]; then
      # ignore empty lines
      continue
    fi
    SQL_DOMAIN_ARR+=("${domains}")
  done <<< "${SQL_DOMAINS}"

  if [[ ${ONLY_OPENEMAIL_HOSTNAME} != "y" ]]; then
  for SQL_DOMAIN in "${SQL_DOMAIN_ARR[@]}"; do
    unset VALIDATED_CONFIG_DOMAINS_SUBDOMAINS
    declare -a VALIDATED_CONFIG_DOMAINS_SUBDOMAINS
    for SUBDOMAIN in "${ADDITIONAL_WC_ARR[@]}"; do
      if [[  "${SUBDOMAIN}.${SQL_DOMAIN}" != "${OPENEMAIL_HOSTNAME}" ]]; then
        if check_domain "${SUBDOMAIN}.${SQL_DOMAIN}"; then
          VALIDATED_CONFIG_DOMAINS_SUBDOMAINS+=("${SUBDOMAIN}.${SQL_DOMAIN}")
        fi
      fi
    done
    VALIDATED_CONFIG_DOMAINS+=("${VALIDATED_CONFIG_DOMAINS_SUBDOMAINS[*]}")
  done
  fi

  if check_domain ${OPENEMAIL_HOSTNAME}; then
    VALIDATED_OPENEMAIL_HOSTNAME="${OPENEMAIL_HOSTNAME}"
  fi

  if [[ ${ONLY_OPENEMAIL_HOSTNAME} != "y" ]]; then
  for SAN in "${ADDITIONAL_SAN_ARR[@]}"; do
    # Skip on CAA errors for SAN
    SAN_PARENT_DOMAIN=$(echo ${SAN} | cut -d. -f2-)
    SAN_CAAS=( $(dig CAA ${SAN_PARENT_DOMAIN} +short | sed -n 's/\d issue "\(.*\)"/\1/p') )
    if [[ ! -z ${SAN_CAAS} ]]; then
      if [[ ${SAN_CAAS[@]} =~ "letsencrypt.org" ]]; then
        log_f "Validated CAA for parent domain ${SAN_PARENT_DOMAIN} of ${SAN}"
      else
        log_f "Skipping ACME validation for ${SAN}: Lets Encrypt disallowed for ${SAN} by CAA record"
        continue
      fi
    fi
    if [[ ${SAN} == ${OPENEMAIL_HOSTNAME} ]]; then
      continue
    fi
    if check_domain ${SAN}; then
      ADDITIONAL_VALIDATED_SAN+=("${SAN}")
    fi
  done
  fi

  # Unique domains for server certificate
  if [[ ${ENABLE_SSL_SNI} == "y" ]]; then
    # create certificate for server name and fqdn SANs only
    SERVER_SAN_VALIDATED=(${VALIDATED_OPENEMAIL_HOSTNAME} $(echo ${ADDITIONAL_VALIDATED_SAN[*]} | xargs -n1 | sort -u | xargs))
  else
    # create certificate for all domains, including all subdomains from other domains [*]
    SERVER_SAN_VALIDATED=(${VALIDATED_OPENEMAIL_HOSTNAME} $(echo ${VALIDATED_CONFIG_DOMAINS[*]} ${ADDITIONAL_VALIDATED_SAN[*]} | xargs -n1 | sort -u | xargs))
  fi
  if [[ ! -z ${SERVER_SAN_VALIDATED[*]} ]]; then
    CERT_NAME=${SERVER_SAN_VALIDATED[0]}
    VALIDATED_CERTIFICATES+=("${CERT_NAME}")

    # obtain server certificate if required
    DOMAINS=${SERVER_SAN_VALIDATED[@]} /srv/obtain-certificate.sh rsa
    RETURN="$?"
    if [[ "$RETURN" == "0" ]]; then # 0 = cert created successfully
      CERT_AMOUNT_CHANGED=1
      CERT_CHANGED=1
    elif [[ "$RETURN" == "1" ]]; then # 1 = cert renewed successfully
      CERT_CHANGED=1
    elif [[ "$RETURN" == "2" ]]; then # 2 = cert not due for renewal
      :
    else
      CERT_ERRORS=1
    fi
    # copy hostname certificate to default/server certificate
    cp ${ACME_BASE}/${CERT_NAME}/cert.pem ${ACME_BASE}/cert.pem
    cp ${ACME_BASE}/${CERT_NAME}/key.pem ${ACME_BASE}/key.pem
  fi

  # individual certificates for SNI [@]
  if [[ ${ENABLE_SSL_SNI} == "y" ]]; then
  for VALIDATED_DOMAINS in "${VALIDATED_CONFIG_DOMAINS[@]}"; do
    VALIDATED_DOMAINS_ARR=(${VALIDATED_DOMAINS})

    unset VALIDATED_DOMAINS_SORTED
    declare -a VALIDATED_DOMAINS_SORTED
    VALIDATED_DOMAINS_SORTED=(${VALIDATED_DOMAINS_ARR[0]} $(echo ${VALIDATED_DOMAINS_ARR[@]:1} | xargs -n1 | sort -u | xargs))

    # remove all domain names that are already inside the server certificate (SERVER_SAN_VALIDATED)
    for domain in "${SERVER_SAN_VALIDATED[@]}"; do
      for i in "${!VALIDATED_DOMAINS_SORTED[@]}"; do
        if [[ ${VALIDATED_DOMAINS_SORTED[i]} = $domain ]]; then
          unset 'VALIDATED_DOMAINS_SORTED[i]'
        fi
      done
    done

    if [[ ! -z ${VALIDATED_DOMAINS_SORTED[*]} ]]; then
      CERT_NAME=${VALIDATED_DOMAINS_SORTED[0]}
      VALIDATED_CERTIFICATES+=("${CERT_NAME}")
      # obtain certificate if required
      DOMAINS=${VALIDATED_DOMAINS_SORTED[@]} /srv/obtain-certificate.sh rsa
      RETURN="$?"
      if [[ "$RETURN" == "0" ]]; then # 0 = cert created successfully
        CERT_AMOUNT_CHANGED=1
        CERT_CHANGED=1
      elif [[ "$RETURN" == "1" ]]; then # 1 = cert renewed successfully
        CERT_CHANGED=1
      elif [[ "$RETURN" == "2" ]]; then # 2 = cert not due for renewal
        :
      else
        CERT_ERRORS=1
      fi
    fi
  done
  fi

  if [[ -z ${VALIDATED_CERTIFICATES[*]} ]]; then
    log_f "Cannot validate any hostnames, skipping Let's Encrypt for 1 hour."
    log_f "Use SKIP_LETS_ENCRYPT=y in openemail.conf to skip it permanently."
    redis-cli -h redis SET ACME_FAIL_TIME "$(date +%s)"
    sleep 1h
    exec $(readlink -f "$0")
  fi

  # find orphaned certificates if no errors occurred
  if [[ "${CERT_ERRORS}" == "0" ]]; then
    for EXISTING_CERT in "${EXISTING_CERTS[@]}"; do
      if [[ ! "`printf '_%s_\n' "${VALIDATED_CERTIFICATES[@]}"`" == *"_${EXISTING_CERT}_"* ]]; then
        DATE=$(date +%Y-%m-%d_%H_%M_%S)
        log_f "Found orphaned certificate: ${EXISTING_CERT} - archiving it at ${ACME_BASE}/backups/${EXISTING_CERT}/"
        BACKUP_DIR=${ACME_BASE}/backups/${EXISTING_CERT}/${DATE}
        # archive rsa cert and any other files
        mv ${ACME_BASE}/${EXISTING_CERT} ${BACKUP_DIR}
        CERT_CHANGED=1
        CERT_AMOUNT_CHANGED=1
      fi
    done
  fi

  # reload on new or changed certificates
  if [[ "${CERT_CHANGED}" == "1" ]]; then
    CERT_AMOUNT_CHANGED=${CERT_AMOUNT_CHANGED} /srv/reload-configurations.sh
  fi

  case "$CERT_ERRORS" in
    0) # all successful
      if [[ "${CERT_CHANGED}" == "1" ]]; then
        if [[ "${CERT_AMOUNT_CHANGED}" == "1" ]]; then
          log_f "Certificates successfully requested and renewed where required, sleeping one day"
        else
          log_f "Certificates were successfully renewed where required, sleeping for another day."
        fi
      else
        log_f "Certificates were successfully validated, no changes or renewals required, sleeping for another day."
      fi
      sleep 1d
      ;;
    *) # non-zero
      log_f "Some errors occurred, retrying in 30 minutes..."
      redis-cli -h redis SET ACME_FAIL_TIME "$(date +%s)"
      sleep 30m
      exec $(readlink -f "$0")
      ;;
  esac

done
