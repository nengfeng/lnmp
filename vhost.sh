#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp
#
#

export PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
clear
printf "
#######################################################################
#              Setting up virtual hosts on HTTP Server                #
#######################################################################
"
# Check if user is root
[ "$(id -u)" != "0" ] && { echo "${CFAILURE}Error: You must be root to run this script${CEND}"; exit 1; }

current_dir=$(dirname "$(readlink -f $0)")
pushd ${current_dir} > /dev/null
. ./options.conf
. ./include/color.sh
. ./include/common.sh
. ./include/check_dir.sh
. ./include/check_os.sh
. ./include/get_char.sh
. ./include/download.sh

Show_Help() {
  echo
  echo "Usage: $0  command ...[parameters]....
  --help, -h                  Show this help message
  --quiet, -q                 quiet operation
  --list, -l                  List Virtualhost
  --mphp_ver [83~85]          Use another PHP version (PATH: /usr/local/php${mphp_ver})
  --proxy                     Use proxy
  --add                       Add Virtualhost
  --delete, --del             Delete Virtualhost
  --httponly                  Use HTTP Only
  --selfsigned                Generate a self-signed SSL certificate
  --letsencrypt               Use Let's Encrypt to Create SSL Certificate and Key
  --dnsapi                    Use dns API to automatically issue Let's Encrypt Cert
  --customcert                Use your own SSL Certificate and Key files
  "
}

ARG_NUM=$#
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      Show_Help; exit 0
      ;;
    -q|--quiet)
      quiet_flag=y; shift 1
      ;;
    -l|--list)
      list_flag=y; shift 1
      ;;
    --mphp_ver)
      mphp_ver=$2; mphp_flag=y; shift 2
      [[ ! "${mphp_ver}" =~ ^8[3-5]$ ]] && { echo "${CWARNING}mphp_ver input error! Please only input number 83~85${CEND}"; unset mphp_ver mphp_flag; }
      ;;
    --proxy)
      proxy_flag=y; shift 1
      ;;
    --add)
      add_flag=y; shift 1
      ;;
    --delete|--del)
      delete_flag=y; shift 1
      ;;
    --httponly)
      sslquiet_flag=y
      httponly_flag=y
      Domain_Mode=1
      shift 1
      ;;
    --selfsigned)
      sslquiet_flag=y
      selfsigned_flag=y
      Domain_Mode=2
      shift 1
      ;;
    --letsencrypt)
      sslquiet_flag=y
      letsencrypt_flag=y
      Domain_Mode=3
      shift 1
      ;;
    --customcert)
      sslquiet_flag=y
      customcert_flag=y
      Domain_Mode=4
      shift 1
      ;;
    --dnsapi)
      sslquiet_flag=y
      dnsapi_flag=y
      letsencrypt_flag=y
      shift 1
      ;;
    --)
      shift
      ;;
    *)
      echo "${CWARNING}ERROR: unknown argument! ${CEND}" && Show_Help && exit 1
      ;;
  esac
done

Choose_ENV() {
  NGX_FLAG=php
}

Create_SSL() {
  if [[ "${Domain_Mode}" == 2 ]]; then
    printf "
You are about to be asked to enter information that will be incorporated
into your certificate request.
What you are about to enter is what is called a Distinguished Name or a DN.
There are quite a few fields but you can leave some blank
For some fields there will be a default value,
If you enter '.', the field will be left blank.
"
    echo
    while :; do
      read -e -p "Country Name (2 letter code) [CN]: " SELFSIGNEDSSL_C
      SELFSIGNEDSSL_C=${SELFSIGNEDSSL_C:-CN}
      [[ ${#SELFSIGNEDSSL_C} == 2 ]] && break
      echo "${CWARNING}input error, You must input 2 letter code country name${CEND}"
    done
    echo
    read -e -p "State or Province Name (full name) [Shanghai]: " SELFSIGNEDSSL_ST
    SELFSIGNEDSSL_ST=${SELFSIGNEDSSL_ST:-Shanghai}
    echo
    read -e -p "Locality Name (eg, city) [Shanghai]: " SELFSIGNEDSSL_L
    SELFSIGNEDSSL_L=${SELFSIGNEDSSL_L:-Shanghai}
    echo
    read -e -p "Organization Name (eg, company) [Example Inc.]: " SELFSIGNEDSSL_O
    SELFSIGNEDSSL_O=${SELFSIGNEDSSL_O:-"Example Inc."}
    echo
    read -e -p "Organizational Unit Name (eg, section) [IT Dept.]: " SELFSIGNEDSSL_OU
    SELFSIGNEDSSL_OU=${SELFSIGNEDSSL_OU:-"IT Dept."}

    openssl req -utf8 -new -newkey rsa:2048 -sha256 -nodes -out ${PATH_SSL}/${domain}.csr -keyout ${PATH_SSL}/${domain}.key -subj "/C=${SELFSIGNEDSSL_C}/ST=${SELFSIGNEDSSL_ST}/L=${SELFSIGNEDSSL_L}/O=${SELFSIGNEDSSL_O}/OU=${SELFSIGNEDSSL_OU}/CN=${domain}" > /dev/null 2>&1
    openssl x509 -req -days 36500 -sha256 -in ${PATH_SSL}/${domain}.csr -signkey ${PATH_SSL}/${domain}.key -out ${PATH_SSL}/${domain}.crt > /dev/null 2>&1
  elif [[ "${Domain_Mode}" == 3 || "${dnsapi_flag}" == y ]]; then
      while :; do echo
        echo 'Please select domain cert key length.'
        echo "${CMSG}Enter one of 2048, 3072, 4096, 8192 will issue a RSA cert.${CEND}"
        echo "${CMSG}Enter one of ec-256, ec-384, ec-521 will issue a ECC cert.${CEND}"
        echo
        read -e -p "Please enter your cert key length (default ec-256): " CERT_KEYLENGTH
        if [[[ "${CERT_KEYLENGTH}" == "" ]]]; then
          CERT_KEYLENGTH="ec-256"
          break
        elif [[ "${CERT_KEYLENGTH}" =~ ^2048$|^3072$|^4096$|^8192$|^ec-256$|^ec-384$|^ec-521$ ]]; then
          break
        else
          echo "${CWARNING}input error!${CEND}"
        fi
      done
    if [ ! -e ~/.acme.sh/ca/acme.zerossl.com/v2/DV90/account.key ]; then
      while :; do echo
        read -e -p "Please enter your email: " EMAIL
        echo
        if [[ "${EMAIL}" =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+\.[A-Za-z]{2,9}$ ]]; then
          break
        else
          echo "${CWARNING}input error!${CEND}"
        fi
      done
      ~/.acme.sh/acme.sh --register-account -m ${EMAIL}
    fi
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    if [[ "${moredomain}" == "*.${domain}" || "${dnsapi_flag}" == y ]]; then
      while :; do echo
        echo 'Please select DNS provider:'
        echo "${CMSG}dp${CEND},${CMSG}cx${CEND},${CMSG}ali${CEND},${CMSG}cf${CEND},${CMSG}aws${CEND},${CMSG}linode${CEND},${CMSG}he${CEND},${CMSG}namesilo${CEND},${CMSG}dgon${CEND},${CMSG}freedns${CEND},${CMSG}gd${CEND},${CMSG}namecom${CEND} and so on."
        read -e -p "Please enter your DNS provider: " DNS_PRO
        if [ -e ~/.acme.sh/dnsapi/dns_${DNS_PRO}.sh ]; then
          break
        else
          echo "${CWARNING}You DNS api mode is not supported${CEND}"
        fi
      done
      while :; do echo
        echo "Syntax: export Key1=Value1 ; export Key2=Value1"
        read -e -p "Please enter your dnsapi parameters: " DNS_PAR
        echo
        # Security: Validate input to prevent command injection
        # Block dangerous characters: | & $ ` ( ) { } < > \ newline
        if [[ "${DNS_PAR}" =~ [\|\&\$\`\(\)\{\}\<\>\\] ]] || [[ "${DNS_PAR}" == *$'\n'* ]]; then
          echo "${CWARNING}Invalid characters detected! Only alphanumeric, underscore, equals, and semicolons are allowed.${CEND}"
          continue
        fi
        # Validate format: must be export statements only
        # Split by ; and newline, validate each statement
        valid_format=1
        IFS=$';\n' read -ra EXPORT_PAIRS <<< "${DNS_PAR}"
        for pair in "${EXPORT_PAIRS[@]}"; do
          # Trim whitespace
          pair=$(echo "$pair" | xargs)
          [ -z "$pair" ] && continue
          # Check format: export VAR_NAME=VALUE (value must not contain $ or backticks)
          if ! [[ "$pair" =~ ^[[:space:]]*export[[:space:]]+[A-Za-z_][A-Za-z0-9_]*=[^\$\`]*$ ]]; then
            echo "${CWARNING}Invalid format: '$pair'. Expected: export VAR_NAME=VALUE${CEND}"
            valid_format=0
            break
          fi
        done
        if [ "$valid_format" -ne 1 ]; then
          continue
        fi
        # Execute the validated input (safe: all statements validated)
        eval "${DNS_PAR}"
        if [[ $? == 0 ]]; then
          break
        else
          echo "${CWARNING}Syntax error! PS: export Ali_Key=LTq ; export Ali_Secret=0q5E${CEND}"
        fi
      done
      [[ "${moredomainame_flag}" == y ]] && moredomainame_D="$(for D in ${moredomainame}; do echo -d ${D}; done)"
      ~/.acme.sh/acme.sh --force --issue -k ${CERT_KEYLENGTH} --dns dns_${DNS_PRO} -d ${domain} ${moredomainame_D}
    else
      if [[ "${nginx_ssl_flag}" == y ]]; then
        [ ! -d ${web_install_dir}/conf/vhost ] && mkdir ${web_install_dir}/conf/vhost
        if [ -n "$(ifconfig | grep inet6)" ]; then
          echo "server {  listen 80;  listen [::]:80;  server_name ${domain}${moredomainame};  root ${vhostdir};  access_log off; }" > ${web_install_dir}/conf/vhost/${domain}.conf
        else
          echo "server {  listen 80;  server_name ${domain}${moredomainame};  root ${vhostdir};  access_log off; }" > ${web_install_dir}/conf/vhost/${domain}.conf
        fi
        ${web_install_dir}/sbin/nginx -s reload
      fi
      auth_file="$(< /dev/urandom tr -dc A-Za-z0-9 | head -c8)".html
      auth_str=$(< /dev/urandom tr -dc A-Za-z0-9 | head -c16); echo ${auth_str} > ${vhostdir}/${auth_file}
      for D in ${domain} ${moredomainame}
      do
        curl_str=$(curl --connect-timeout 30 -4 -s $D/${auth_file} 2>&1)
        [ "${curl_str}" != "${auth_str}" ] && { echo; echo "${CFAILURE}Let's Encrypt Verify error! DNS problem: NXDOMAIN looking up A for ${D}${CEND}"; }
      done
      rm -f ${vhostdir}/${auth_file}
      [[ "${moredomainame_flag}" == y ]] && moredomainame_D="$(for D in ${moredomainame}; do echo -d ${D}; done)"
      ~/.acme.sh/acme.sh --force --issue -k ${CERT_KEYLENGTH} -w ${vhostdir} -d ${domain} ${moredomainame_D}
    fi
      [ -e "${PATH_SSL}/${domain}.crt" ] && rm -f ${PATH_SSL}/${domain}.{crt,key}
      Nginx_cmd="svc_restart nginx"
      Command="${Nginx_cmd}"
    if [ -s ~/.acme.sh/${domain}/fullchain.cer ] && [[ "${CERT_KEYLENGTH}" =~ ^2048$|^3072$|^4096$|^8192$ ]]; then
      ~/.acme.sh/acme.sh --force --install-cert -d ${domain} --fullchain-file ${PATH_SSL}/${domain}.crt --key-file ${PATH_SSL}/${domain}.key --reloadcmd "${Command}" > /dev/null
    elif [ -s ~/.acme.sh/${domain}_ecc/fullchain.cer ] && [[ "${CERT_KEYLENGTH}" =~ ^ec-256$|^ec-384$|^ec-521$ ]]; then
      ~/.acme.sh/acme.sh --force --install-cert --ecc -d ${domain} --fullchain-file ${PATH_SSL}/${domain}.crt --key-file ${PATH_SSL}/${domain}.key --reloadcmd "${Command}" > /dev/null
    else
      echo "${CFAILURE}Error: Create Let's Encrypt SSL Certificate failed! ${CEND}"
      [ -e "${web_install_dir}/conf/vhost/${domain}.conf" ] && rm -f ${web_install_dir}/conf/vhost/${domain}.conf
      exit 1
    fi
  elif [[ "${Domain_Mode}" == 4 ]]; then
    echo
    echo "Please provide the paths to your SSL certificate and key files."
    echo "You can purchase certificates from providers like DigiCert, Sectigo, TrustAsia, etc."
    echo
    while :; do
      read -e -p "Please enter SSL Certificate file path (.crt/.pem): " CUSTOM_CERT_PATH
      if [ -z "${CUSTOM_CERT_PATH}" ]; then
        echo "${CWARNING}Path cannot be empty${CEND}"
        continue
      fi
      if [ ! -f "${CUSTOM_CERT_PATH}" ]; then
        echo "${CFAILURE}File not found: ${CUSTOM_CERT_PATH}${CEND}"
        continue
      fi
      # Verify it's a valid certificate
      if ! openssl x509 -in "${CUSTOM_CERT_PATH}" -noout 2>/dev/null; then
        echo "${CFAILURE}Invalid certificate file${CEND}"
        continue
      fi
      break
    done
    while :; do
      read -e -p "Please enter SSL Private Key file path (.key): " CUSTOM_KEY_PATH
      if [ -z "${CUSTOM_KEY_PATH}" ]; then
        echo "${CWARNING}Path cannot be empty${CEND}"
        continue
      fi
      if [ ! -f "${CUSTOM_KEY_PATH}" ]; then
        echo "${CFAILURE}File not found: ${CUSTOM_KEY_PATH}${CEND}"
        continue
      fi
      # Verify it's a valid private key
      if ! openssl rsa -in "${CUSTOM_KEY_PATH}" -check -noout 2>/dev/null && ! openssl ec -in "${CUSTOM_KEY_PATH}" -check -noout 2>/dev/null; then
        echo "${CFAILURE}Invalid private key file${CEND}"
        continue
      fi
      break
    done
    # Verify cert and key match
    cert_modulus=$(openssl x509 -noout -modulus -in "${CUSTOM_CERT_PATH}" 2>/dev/null | md5sum)
    key_modulus=$(openssl rsa -noout -modulus -in "${CUSTOM_KEY_PATH}" 2>/dev/null | md5sum)
    if [ "${cert_modulus}" != "${key_modulus}" ]; then
      # Try ECC key
      if ! openssl ec -in "${CUSTOM_KEY_PATH}" -check -noout 2>/dev/null; then
        echo "${CFAILURE}Error: Certificate and key do not match!${CEND}"
        exit 1
      fi
    fi
    # Copy to SSL directory
    mkdir -p ${PATH_SSL}
    /bin/cp -f "${CUSTOM_CERT_PATH}" ${PATH_SSL}/${domain}.crt
    /bin/cp -f "${CUSTOM_KEY_PATH}" ${PATH_SSL}/${domain}.key
    chmod 600 ${PATH_SSL}/${domain}.key
    echo "${CGREEN}SSL certificate installed successfully!${CEND}"
  fi
}

Print_SSL() {
  if [[ "${Domain_Mode}" == 2 ]]; then
    echo "$(printf "%-30s" "Self-signed SSL Certificate:")${CMSG}${PATH_SSL}/${domain}.crt${CEND}"
    echo "$(printf "%-30s" "SSL Private Key:")${CMSG}${PATH_SSL}/${domain}.key${CEND}"
    echo "$(printf "%-30s" "SSL CSR File:")${CMSG}${PATH_SSL}/${domain}.csr${CEND}"
  elif [[ "${Domain_Mode}" == 3 || "${dnsapi_flag}" == y ]]; then
    echo "$(printf "%-30s" "Let's Encrypt SSL Certificate:")${CMSG}${PATH_SSL}/${domain}.crt${CEND}"
    echo "$(printf "%-30s" "SSL Private Key:")${CMSG}${PATH_SSL}/${domain}.key${CEND}"
  elif [[ "${Domain_Mode}" == 4 ]]; then
    echo "$(printf "%-30s" "Custom SSL Certificate:")${CMSG}${PATH_SSL}/${domain}.crt${CEND}"
    echo "$(printf "%-30s" "SSL Private Key:")${CMSG}${PATH_SSL}/${domain}.key${CEND}"
  fi
}

Input_Add_proxy() {
  while :; do echo
    read -e -p "Please input the correct proxy_pass: " Proxy_Pass
    if [ -z "$(echo "$Proxy_Pass" | grep -E '^http://|https://')" ]; then
      echo "${CFAILURE}input error! Please only input example https://192.168.1.1:8080${CEND}"
    else
      echo "proxy_pass=${Proxy_Pass}"
      break
    fi
  done
}

Input_Add_domain() {
  if [ "${sslquiet_flag}" != 'y' ]; then
    while :;do
      printf "
What Are You Doing?
\t${CMSG}1${CEND}. Use HTTP Only
\t${CMSG}2${CEND}. Generate a self-signed SSL Certificate
\t${CMSG}3${CEND}. Use Let's Encrypt to Create SSL Certificate and Key
\t${CMSG}4${CEND}. Use your own SSL Certificate and Key files
\t${CMSG}q${CEND}. Exit
"
      read -e -p "Please input the correct option: " Domain_Mode
      if [[ ! "${Domain_Mode}" =~ ^[1-4,q]$ ]]; then
        echo "${CFAILURE}input error! Please only input 1~4 and q${CEND}"
      else
        break
      fi
    done
  fi

  #Multiple_PHP
  if [ "$(ls /dev/shm/php*-cgi.sock 2> /dev/null | wc -l)" -ge 2 ]; then
    if [ "${mphp_flag}" != 'y' ]; then
      PHP_detail_ver=$(${php_install_dir}/bin/php-config --version)
      PHP_main_ver=${PHP_detail_ver%.*}
      while :; do echo
        echo 'Please select a version of the PHP:'
        printf "%b" "\t${CMSG} 0${CEND}. PHP ${PHP_main_ver} (default)\n"
        [ -e "/dev/shm/php83-cgi.sock" ] && printf "%b" "\t${CMSG} 1${CEND}. PHP 8.3\n"
        [ -e "/dev/shm/php84-cgi.sock" ] && printf "%b" "\t${CMSG} 2${CEND}. PHP 8.4\n"
        [ -e "/dev/shm/php85-cgi.sock" ] && printf "%b" "\t${CMSG} 3${CEND}. PHP 8.5\n"
        read -e -p "Please input a number:(Default 0 press Enter) " php_option
        php_option=${php_option:-0}
        if [[ ! ${php_option} =~ ^[0-3]$ ]]; then
          echo "${CWARNING}input error! Please only input number 0~3${CEND}"
        else
          break
        fi
      done
    fi
    [[ "${php_option}" == 1 ]] && mphp_ver=83
    [[ "${php_option}" == 2 ]] && mphp_ver=84
    [[ "${php_option}" == 3 ]] && mphp_ver=85
    [ ! -e "/dev/shm/php${mphp_ver}-cgi.sock" ] && unset mphp_ver
  fi

  NGX_CONF=$(printf "%b" "location ~ [^/]\.php(/|$) {\n    #fastcgi_pass remote_php_ip:9000;\n    fastcgi_pass unix:/dev/shm/php${mphp_ver}-cgi.sock;\n    fastcgi_index index.php;\n    include fastcgi.conf;\n  }\n")

  if [[ "${Domain_Mode}" == 3 || "${dnsapi_flag}" == y ]] && [ ! -e ~/.acme.sh/acme.sh ]; then
    pushd ${current_dir}/src > /dev/null
    init_mirror
    # acme.sh 仅在 GitHub 官方源，无国内镜像
    local acme_url="https://github.com/acmesh-official/acme.sh/archive/refs/heads/master.tar.gz"
    src_url="${acme_url}"
    [ ! -e acme.sh-master.tar.gz ] && Download_src
    tar xzf acme.sh-master.tar.gz
    pushd acme.sh-master > /dev/null
    ./acme.sh --install > /dev/null 2>&1
    popd > /dev/null
    popd > /dev/null
  fi
  [ -e ~/.acme.sh/account.conf ] && sed -i '/^CERT_HOME=/d' ~/.acme.sh/account.conf
  if [[ "${Domain_Mode}" =~ ^[2-4]$ ]] || [[ "${dnsapi_flag}" == y ]]; then
    if [ -e "${web_install_dir}/sbin/nginx" ]; then
      nginx_ssl_flag=y
      PATH_SSL=${web_install_dir}/conf/ssl
      [ ! -d "${PATH_SSL}" ] && mkdir ${PATH_SSL}
    fi
  elif [[ "${Domain_Mode}" == q ]]; then
    exit 1
  fi

  while :; do echo
    read -e -p "Please input domain(example: www.example.com): " domain
    if [ -z "$(echo ${domain} | grep '.*\..*')" ]; then
      echo "${CWARNING}Your ${domain} is invalid! ${CEND}"
    else
      break
    fi
  done

  if [ -e "${web_install_dir}/conf/vhost/${domain}.conf" ]; then
    printf "%b" "${domain} in the Nginx/Tengine/OpenResty already exist! \nYou can delete ${CMSG}${web_install_dir}/conf/vhost/${domain}.conf${CEND} and re-create\n"
    exit
  else
    echo "domain=${domain}"
  fi
  if [[ -z ${proxy_flag} || "${proxy_flag}" != 'y' ]]; then
    while :; do echo
      echo "Please input the directory for the domain:${domain} :"
      read -e -p "(Default directory: ${wwwroot_dir}/${domain}): " vhostdir
      if [[ -n "${vhostdir}" && -z "$(echo ${vhostdir} | grep '^/')" ]]; then
        echo "${CWARNING}input error! Press Enter to continue...${CEND}"
      else
        if [ -z "${vhostdir}" ]; then
          vhostdir="${wwwroot_dir}/${domain}"
          echo "Virtual Host Directory=${CMSG}${vhostdir}${CEND}"
        fi
        echo
        echo "Create Virtul Host directory......"
        mkdir -p ${vhostdir}
        echo "set permissions of Virtual Host directory......"
        chown -R ${run_user}:${run_group} ${vhostdir}
        break
      fi
    done
  fi

  while :; do echo
    read -e -p "Do you want to add more domain name? [y/n]: " moredomainame_flag
    if [[ ! ${moredomainame_flag} =~ ^[y,n]$ ]]; then
      echo "${CWARNING}input error! Please only input 'y' or 'n'${CEND}"
    else
      break
    fi
  done

  if [[ "${moredomainame_flag}" == y ]]; then
    while :; do echo
      read -e -p "Type domainname or IP(example: example.com other.example.com): " moredomain
      if [ -z "$(echo ${moredomain} | grep '.*\..*')" ]; then
        echo "${CWARNING}Your ${domain} is invalid! ${CEND}"
      else
        [[ "${moredomain}" == "${domain}" ]] && echo "${CWARNING}Domain name already exists! ${CEND}" && continue
        echo domain list="$moredomain"
        moredomainame=" $moredomain"
        break
      fi
    done

    if [ -e "${web_install_dir}/sbin/nginx" ]; then
      while :; do echo
        read -e -p "Do you want to redirect from ${moredomain} to ${domain}? [y/n]: " redirect_flag
        if [[ ! ${redirect_flag} =~ ^[y,n]$ ]]; then
          echo "${CWARNING}input error! Please only input 'y' or 'n'${CEND}"
        else
          break
        fi
      done
      [[ "${redirect_flag}" == y ]] && Nginx_redirect="if (\$host != ${domain}) {  return 301 \$scheme://${domain}\$request_uri;  }"
    fi
  fi

  if [[ "${nginx_ssl_flag}" == y ]]; then
    while :; do echo
      read -e -p "Do you want to redirect all HTTP requests to HTTPS? [y/n]: " https_flag
      if [[ ! ${https_flag} =~ ^[y,n]$ ]]; then
        echo "${CWARNING}input error! Please only input 'y' or 'n'${CEND}"
      else
        break
      fi
    done

    Create_SSL
    if [ -n "$(ifconfig | grep inet6)" ]; then
      Nginx_conf=$(printf "%b" "listen 80;\n  listen [::]:80;\n  listen 443 ssl;\n  listen [::]:443 ssl;\n  http2 on;\n  ssl_certificate ${PATH_SSL}/${domain}.crt;\n  ssl_certificate_key ${PATH_SSL}/${domain}.key;\n  ssl_protocols TLSv1.2 TLSv1.3;\n  ssl_ecdh_curve X25519:prime256v1:secp384r1:secp521r1;\n  ssl_ciphers ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256;\n  ssl_conf_command Ciphersuites TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256;\n  ssl_conf_command Options PrioritizeChaCha;\n  ssl_prefer_server_ciphers on;\n  ssl_session_timeout 10m;\n  ssl_session_cache shared:SSL:10m;\n  ssl_buffer_size 2k;\n  add_header Strict-Transport-Security \"max-age=15768000; includeSubDomains; preload\";\n  ssl_stapling on;\n  ssl_stapling_verify on;\n\n")
    else
      Nginx_conf=$(printf "%b" "listen 80;\n  listen 443 ssl;\n  http2 on;\n  ssl_certificate ${PATH_SSL}/${domain}.crt;\n  ssl_certificate_key ${PATH_SSL}/${domain}.key;\n  ssl_protocols TLSv1.2 TLSv1.3;\n  ssl_ecdh_curve X25519:prime256v1:secp384r1:secp521r1;\n  ssl_ciphers ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256;\n  ssl_conf_command Ciphersuites TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256;\n  ssl_conf_command Options PrioritizeChaCha;\n  ssl_prefer_server_ciphers on;\n  ssl_session_timeout 10m;\n  ssl_session_cache shared:SSL:10m;\n  ssl_buffer_size 2k;\n  add_header Strict-Transport-Security \"max-age=15768000; includeSubDomains; preload\";\n  ssl_stapling on;\n  ssl_stapling_verify on;\n\n")
    fi
    [[ "${https_flag}" == y ]] && sed -i "s@^  listen 80;@&\n  return 301 https://\$host\$request_uri;@" ${web_install_dir}/conf/vhost/${domain}.conf
  fi
}

Nginx_anti_hotlinking() {
  while :; do echo
    read -e -p "Do you want to add hotlink protection? [y/n]: " anti_hotlinking_flag
    if [[ ! ${anti_hotlinking_flag} =~ ^[y,n]$ ]]; then
      echo "${CWARNING}input error! Please only input 'y' or 'n'${CEND}"
    else
      break
    fi
  done

  if [ -n "$(echo ${domain} | grep '.*\..*\..*')" ]; then
    domain_allow="*.${domain#*.} ${domain}"
  else
    domain_allow="*.${domain} ${domain}"
  fi

  if [[ "${anti_hotlinking_flag}" == y ]]; then
    if [[ "${moredomainame_flag}" == y && "${moredomain}" != "*.${domain}" ]]; then
      domain_allow_all=${domain_allow}${moredomainame}
    else
      domain_allow_all=${domain_allow}
    fi
    domain_allow_all=$(echo ${domain_allow_all} | tr ' ' '\n' | awk '!a[$1]++' | xargs)
    anti_hotlinking=$(printf "%b" "location ~ .*\.(wma|wmv|asf|mp3|mmf|zip|rar|jpg|gif|png|swf|flv|mp4)$ {\n    valid_referers none blocked ${domain_allow_all};\n    if (\$invalid_referer) {\n        return 403;\n    }\n  }\n")
  fi
}

Nginx_rewrite() {
  [ ! -d "${web_install_dir}/conf/rewrite" ] && mkdir ${web_install_dir}/conf/rewrite
  while :; do echo
    read -e -p "Allow Rewrite rule? [y/n]: " rewrite_flag
    if [[ ! "${rewrite_flag}" =~ ^[y,n]$ ]]; then
      echo "${CWARNING}input error! Please only input 'y' or 'n'${CEND}"
    else
      break
    fi
  done
  if [[ "${rewrite_flag}" == n ]]; then
    rewrite="none"
    touch "${web_install_dir}/conf/rewrite/${rewrite}.conf"
  else
    echo
    echo "Please input the rewrite of programme :"
    echo "${CMSG}wordpress${CEND},${CMSG}opencart${CEND},${CMSG}magento2${CEND},${CMSG}drupal${CEND},${CMSG}joomla${CEND},${CMSG}codeigniter${CEND},${CMSG}laravel${CEND}"
    echo "${CMSG}thinkphp${CEND},${CMSG}pathinfo${CEND},${CMSG}discuz${CEND},${CMSG}typecho${CEND},${CMSG}ecshop${CEND},${CMSG}nextcloud${CEND},${CMSG}zblog${CEND},${CMSG}whmcs${CEND} rewrite was exist."
    read -e -p "(Default rewrite: other): " rewrite
    if [[ "${rewrite}" == "" ]]; then
      rewrite="other"
    fi
    echo "You choose rewrite=${CMSG}$rewrite${CEND}"
    [[ "${NGX_FLAG}" == php && "${rewrite}" == "joomla" ]] && NGX_CONF=$(printf "%b" "location ~ \\.php\$ {\n    #fastcgi_pass remote_php_ip:9000;\n    fastcgi_pass unix:/dev/shm/php${mphp_ver}-cgi.sock;\n    fastcgi_index index.php;\n    include fastcgi.conf;\n  }\n")
    [[ "${NGX_FLAG}" == php ]] && [[ "${rewrite}" =~ ^codeigniter$|^thinkphp$|^pathinfo$ ]] && NGX_CONF=$(printf "%b" "location ~ [^/]\.php(/|\$) {\n    #fastcgi_pass remote_php_ip:9000;\n    fastcgi_pass unix:/dev/shm/php${mphp_ver}-cgi.sock;\n    fastcgi_index index.php;\n    include fastcgi.conf;\n    fastcgi_split_path_info ^(.+?\.php)(/.*)\$;\n    set \$path_info \$fastcgi_path_info;\n    fastcgi_param PATH_INFO \$path_info;\n    try_files \$fastcgi_script_name =404;    \n  }\n")
    [[ "${NGX_FLAG}" == php && "${rewrite}" == "typecho" ]] && NGX_CONF=$(printf "%b" "location ~ .*\.php(\/.*)*\$ {\n    #fastcgi_pass remote_php_ip:9000;\n    fastcgi_pass unix:/dev/shm/php${mphp_ver}-cgi.sock;\n    fastcgi_index index.php;\n    include fastcgi.conf;\n    set \$path_info \"\";\n    set \$real_script_name \$fastcgi_script_name;\n    if (\$fastcgi_script_name ~ \"^(.+?\.php)(/.+)\$\") {\n      set \$real_script_name \$1;\n      set \$path_info \$2;\n    }\n    fastcgi_param SCRIPT_FILENAME \$document_root\$real_script_name;\n    fastcgi_param SCRIPT_NAME \$real_script_name;\n    fastcgi_param PATH_INFO \$path_info;\n  }\n")
    if [[ ! "${rewrite}" =~ ^magento2$|^pathinfo$ ]]; then
      if [ -e "config/${rewrite}.conf" ]; then
        /bin/cp config/${rewrite}.conf ${web_install_dir}/conf/rewrite/${rewrite}.conf
        # Replace PHP socket for configs that contain fastcgi_pass
        sed -i "s@/dev/shm/php-cgi.sock@/dev/shm/php${mphp_ver}-cgi.sock@g" ${web_install_dir}/conf/rewrite/${rewrite}.conf
      else
        touch "${web_install_dir}/conf/rewrite/${rewrite}.conf"
      fi
    fi
  fi
}

Nginx_log() {
  while :; do echo
    read -e -p "Allow Nginx/Tengine/OpenResty access_log? [y/n]: " access_flag
    if [[ ! "${access_flag}" =~ ^[y,n]$ ]]; then
      echo "${CWARNING}input error! Please only input 'y' or 'n'${CEND}"
    else
      break
    fi
  done
  if [[ "${access_flag}" == n ]]; then
    Nginx_log="access_log off;"
  else
    Nginx_log="access_log ${wwwlogs_dir}/${domain}_nginx.log combined;"
    echo "You access log file=${CMSG}${wwwlogs_dir}/${domain}_nginx.log${CEND}"
  fi
}

Create_nginx_phpfpm_conf() {
  [ ! -d ${web_install_dir}/conf/vhost ] && mkdir ${web_install_dir}/conf/vhost
  cat > ${web_install_dir}/conf/vhost/${domain}.conf << EOF
server {
  ${Nginx_conf}
  server_name ${domain}${moredomainame};
  ${Nginx_log}
  index index.html index.htm index.php;
  root ${vhostdir};
  ${Nginx_redirect}
  include ${web_install_dir}/conf/rewrite/${rewrite}.conf;
  #error_page 404 /404.html;
  #error_page 502 /502.html;
  ${anti_hotlinking}
  ${NGX_CONF}

  location ~ .*\.(gif|jpg|jpeg|png|bmp|swf|flv|mp4|ico)$ {
    expires 30d;
    access_log off;
  }
  location ~ .*\.(js|css)?$ {
    expires 7d;
    access_log off;
  }
  location ~ /(\.user\.ini|\.ht|\.git|\.svn|\.project|LICENSE|README\.md) {
    deny all;
  }
  location /.well-known {
    allow all;
  }
}
EOF

  [[ "${rewrite}" == pathinfo ]] && sed -i '/pathinfo.conf;$/d' ${web_install_dir}/conf/vhost/${domain}.conf
  if [[ "${rewrite}" == 'magento2' && -e "config/${rewrite}.conf" ]]; then
    /bin/cp config/${rewrite}.conf ${web_install_dir}/conf/vhost/${domain}.conf
    sed -i "s@/dev/shm/php-cgi.sock@/dev/shm/php${mphp_ver}-cgi.sock@g" ${web_install_dir}/conf/vhost/${domain}.conf
    sed -i "s@^  set \$MAGE_ROOT.*;@  set \$MAGE_ROOT ${vhostdir};@" ${web_install_dir}/conf/vhost/${domain}.conf
    sed -i "s@^  server_name.*;@  server_name ${domain}${moredomainame};@" ${web_install_dir}/conf/vhost/${domain}.conf
    sed -i "s@^  server_name.*;@&\n  ${Nginx_log}@" ${web_install_dir}/conf/vhost/${domain}.conf
    if [[ "${anti_hotlinking_flag}" == y ]]; then
      sed -i "s@^  root.*;@&\n  }@" ${web_install_dir}/conf/vhost/${domain}.conf
      sed -i "s@^  root.*;@&\n    }@" ${web_install_dir}/conf/vhost/${domain}.conf
      sed -i "s@^  root.*;@&\n      return 403;@" ${web_install_dir}/conf/vhost/${domain}.conf
      sed -i "s@^  root.*;@&\n      return 403;@" ${web_install_dir}/conf/vhost/${domain}.conf
      sed -i "s@^  root.*;@&\n    if (\$invalid_referer) {@" ${web_install_dir}/conf/vhost/${domain}.conf
      sed -i "s@^  root.*;@&\n    valid_referers none blocked ${domain_allow_all};@" ${web_install_dir}/conf/vhost/${domain}.conf
      sed -i "s@^  root.*;@&\n  location ~ .*\.(wma|wmv|asf|mp3|mmf|zip|rar|jpg|gif|png|swf|flv|mp4)\$ {@" ${web_install_dir}/conf/vhost/${domain}.conf
    fi

    [[ "${redirect_flag}" == y ]] && sed -i "s@^  root.*;@&\n  if (\$host != ${domain}) {  return 301 \$scheme://${domain}\$request_uri;  }@" ${web_install_dir}/conf/vhost/${domain}.conf

    if [[ "${nginx_ssl_flag}" == y ]]; then
      sed -i "s@^  listen 80;@&\n  listen 443 ssl;@" ${web_install_dir}/conf/vhost/${domain}.conf
      sed -i "s@^  server_name.*;@&\n  add_header Strict-Transport-Security \"max-age=15768000; includeSubDomains; preload\";@" ${web_install_dir}/conf/vhost/${domain}.conf
      sed -i "s@^  add_header Strict-Transport.*@&\n  ssl_stapling on;@" ${web_install_dir}/conf/vhost/${domain}.conf
      sed -i "s@^  ssl_stapling on;@&\n  ssl_stapling_verify on;@" ${web_install_dir}/conf/vhost/${domain}.conf
      sed -i "s@^  server_name.*;@&\n  ssl_buffer_size 2k;@" ${web_install_dir}/conf/vhost/${domain}.conf
      sed -i "s@^  server_name.*;@&\n  ssl_session_cache shared:SSL:10m;@" ${web_install_dir}/conf/vhost/${domain}.conf
      sed -i "s@^  server_name.*;@&\n  ssl_session_timeout 10m;@" ${web_install_dir}/conf/vhost/${domain}.conf
      sed -i "s@^  server_name.*;@&\n  ssl_prefer_server_ciphers on;@" ${web_install_dir}/conf/vhost/${domain}.conf
      sed -i "s@^  server_name.*;@&\n  ssl_conf_command Options PrioritizeChaCha;@" ${web_install_dir}/conf/vhost/${domain}.conf
      sed -i "s@^  server_name.*;@&\n  ssl_conf_command Ciphersuites TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256;@" ${web_install_dir}/conf/vhost/${domain}.conf
      sed -i "s@^  server_name.*;@&\n  ssl_ciphers ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256;@" ${web_install_dir}/conf/vhost/${domain}.conf
      sed -i "s@^  server_name.*;@&\n  ssl_ecdh_curve X25519:prime256v1:secp384r1:secp521r1;@" ${web_install_dir}/conf/vhost/${domain}.conf
      sed -i "s@^  server_name.*;@&\n  ssl_protocols TLSv1.2 TLSv1.3;@" ${web_install_dir}/conf/vhost/${domain}.conf
      sed -i "s@^  server_name.*;@&\n  ssl_certificate_key ${PATH_SSL}/${domain}.key;@" ${web_install_dir}/conf/vhost/${domain}.conf
      sed -i "s@^  server_name.*;@&\n  ssl_certificate ${PATH_SSL}/${domain}.crt;@" ${web_install_dir}/conf/vhost/${domain}.conf
    fi
  fi

  [[ "${https_flag}" == y ]] && sed -i "s@^  root.*;@&\n  if (\$ssl_protocol = \"\") { return 301 https://\$host\$request_uri; }@" ${web_install_dir}/conf/vhost/${domain}.conf

  echo
  ${web_install_dir}/sbin/nginx -t
  if [[ $? == 0 ]]; then
    echo "Reload Nginx......"
    ${web_install_dir}/sbin/nginx -s reload
  else
    rm -f ${web_install_dir}/conf/vhost/${domain}.conf
    echo "Create virtualhost ... [${CFAILURE}FAILED${CEND}]"
    exit 1
  fi

  printf "
#######################################################################
#######################################################################
"
  echo "$(printf "%-30s" "Your domain:")${CMSG}${domain}${CEND}"
  echo "$(printf "%-30s" "Virtualhost conf:")${CMSG}${web_install_dir}/conf/vhost/${domain}.conf${CEND}"
  echo "$(printf "%-30s" "Directory of:")${CMSG}${vhostdir}${CEND}"
  [[ "${rewrite_flag}" == y && "${rewrite}" != magento2 && "${rewrite}" != pathinfo ]] && echo "$(printf "%-30s" "Rewrite rule:")${CMSG}${web_install_dir}/conf/rewrite/${rewrite}.conf${CEND}"
  Print_SSL
}

Create_nginx_proxy_conf() {
  [ ! -d ${web_install_dir}/conf/vhost ] && mkdir ${web_install_dir}/conf/vhost
  cat > ${web_install_dir}/conf/vhost/${domain}.conf << EOF
server {
  ${Nginx_conf}
  server_name ${domain}${moredomainame};
  ${Nginx_log}
  index index.html index.htm index.php;
  root /dev/null;
  ${Nginx_redirect}
  location / {
    proxy_pass ${Proxy_Pass};
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header Host \$http_host;
    proxy_set_header X-NginX-Proxy true;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_max_temp_file_size 0;
  }

  #error_page 404 /404.html;
  #error_page 502 /502.html;
  ${anti_hotlinking}

  location ~ .*\.(gif|jpg|jpeg|png|bmp|swf|flv|mp4|ico)$ {
    expires 30d;
    access_log off;
  }
  location ~ .*\.(js|css)?$ {
    expires 7d;
    access_log off;
  }
  location ~ /(\.user\.ini|\.ht|\.git|\.svn|\.project|LICENSE|README\.md) {
    deny all;
  }
  location /.well-known {
    allow all;
  }
}
EOF

  [[ "${redirect_flag}" == y ]] && sed -i "s@^  root.*;@&\n  if (\$host != ${domain}) {  return 301 \$scheme://${domain}\$request_uri;  }@" ${web_install_dir}/conf/vhost/${domain}.conf

  if [[ "${anti_hotlinking_flag}" == y ]]; then
      sed -i "s@^  root.*;@&\n  }@" ${web_install_dir}/conf/vhost/${domain}.conf
      sed -i "s@^  root.*;@&\n    }@" ${web_install_dir}/conf/vhost/${domain}.conf
      sed -i "s@^  root.*;@&\n      return 403;@" ${web_install_dir}/conf/vhost/${domain}.conf
      sed -i "s@^  root.*;@&\n      return 403;@" ${web_install_dir}/conf/vhost/${domain}.conf
      sed -i "s@^  root.*;@&\n    if (\$invalid_referer) {@" ${web_install_dir}/conf/vhost/${domain}.conf
      sed -i "s@^  root.*;@&\n    valid_referers none blocked ${domain_allow_all};@" ${web_install_dir}/conf/vhost/${domain}.conf
      sed -i "s@^  root.*;@&\n  location ~ .*\.(wma|wmv|asf|mp3|mmf|zip|rar|jpg|gif|png|swf|flv|mp4)\$ {@" ${web_install_dir}/conf/vhost/${domain}.conf
    fi

  [[ "${https_flag}" == y ]] && sed -i "s@^  root.*;@&\n  if (\$ssl_protocol = \"\") { return 301 https://\$host\$request_uri; }@" ${web_install_dir}/conf/vhost/${domain}.conf

  echo
  ${web_install_dir}/sbin/nginx -t
  if [[ $? == 0 ]]; then
    echo "Reload Nginx......"
    ${web_install_dir}/sbin/nginx -s reload
  else
    rm -f ${web_install_dir}/conf/vhost/${domain}.conf
    echo "Create virtualhost ... [${CFAILURE}FAILED${CEND}]"
    exit 1
  fi

  printf "
#######################################################################
#######################################################################
"
  echo "$(printf "%-30s" "Your domain:")${CMSG}${domain}${CEND}"
  echo "$(printf "%-30s" "Virtualhost conf:")${CMSG}${web_install_dir}/conf/vhost/${domain}.conf${CEND}"
  #echo "$(printf "%-30s" "Directory of:")${CMSG}${vhostdir}${CEND}"
  [[ "${rewrite_flag}" == y && "${rewrite}" != magento2 && "${rewrite}" != pathinfo ]] && echo "$(printf "%-30s" "Rewrite rule:")${CMSG}${web_install_dir}/conf/rewrite/${rewrite}.conf${CEND}"
  Print_SSL
}

Add_Vhost() {
  if [ -e "${web_install_dir}/sbin/nginx" ]; then
    Choose_ENV
    Input_Add_domain
    Nginx_anti_hotlinking
    if [[ "${proxy_flag}" == "y" ]]; then
        Input_Add_proxy
        Create_nginx_proxy_conf
      else
        Nginx_rewrite
        Nginx_log
        Create_nginx_phpfpm_conf
    fi
  else
    echo "Error! ${CFAILURE}Web server${CEND} not found!"
  fi
}

Del_NGX_Vhost() {
  if [ -e "${web_install_dir}/sbin/nginx" ]; then
    [ -d "${web_install_dir}/conf/vhost" ] && Domain_List=$(ls ${web_install_dir}/conf/vhost | sed "s@.conf@@g")
    if [ -n "${Domain_List}" ]; then
      echo
      echo "Virtualhost list:"
      echo ${CMSG}${Domain_List}${CEND}
        while :; do echo
          read -e -p "Please input a domain you want to delete: " domain
          if [ -z "$(echo ${domain} | grep '.*\..*')" ]; then
            echo "${CWARNING}Your ${domain} is invalid! ${CEND}"
          else
            if [ -e "${web_install_dir}/conf/vhost/${domain}.conf" ]; then
              Directory=$(grep '^  root' ${web_install_dir}/conf/vhost/${domain}.conf | head -1 | awk -F'[ ;]' '{print $(NF-1)}')
              /bin/mv ${web_install_dir}/conf/vhost/${domain}.conf ${web_install_dir}/conf/vhost/${domain}.conf.bak
              if ${web_install_dir}/sbin/nginx -t; then
                rm -f ${web_install_dir}/conf/vhost/${domain}.conf.bak
                [ -e "${web_install_dir}/conf/rewrite/${domain}.conf" ] && rm -f ${web_install_dir}/conf/rewrite/${domain}.conf
                [ -e "${web_install_dir}/conf/ssl/${domain}.crt" ] && rm -f ${web_install_dir}/conf/ssl/${domain}.{crt,key,csr}
                ${web_install_dir}/sbin/nginx -s reload
              else
                /bin/mv ${web_install_dir}/conf/vhost/${domain}.conf.bak ${web_install_dir}/conf/vhost/${domain}.conf
                echo "${CFAILURE}Nginx config test failed! Virtualhost not deleted.${CEND}"
                break
              fi
              while :; do echo
                read -e -p "Do you want to delete Virtul Host directory? [y/n]: " Del_Vhost_wwwroot_flag
                if [[ ! ${Del_Vhost_wwwroot_flag} =~ ^[y,n]$ ]]; then
                  echo "${CWARNING}input error! Please only input 'y' or 'n'${CEND}"
                else
                  break
                fi
              done
              if [[ "${Del_Vhost_wwwroot_flag}" == y ]]; then
		if [ "${quiet_flag}" != 'y' ]; then
                  echo "Press Ctrl+c to cancel or Press any key to continue..."
                  char=$(get_char)
		fi
                rm -rf ${Directory}
              fi
              echo
              [ -d ~/.acme.sh/${domain} ] && ~/.acme.sh/acme.sh --force --remove -d ${domain} > /dev/null 2>&1
              [ -d ~/.acme.sh/${domain}_ecc ] && ~/.acme.sh/acme.sh --force --remove --ecc -d ${domain} > /dev/null 2>&1
              echo "${CMSG}Domain: ${domain} has been deleted.${CEND}"
              echo
            else
              echo "${CWARNING}Virtualhost: ${domain} was not exist! ${CEND}"
            fi
            break
          fi
        done
    else
      echo "${CWARNING}Virtualhost was not exist! ${CEND}"
    fi
  fi
}

List_Vhost() {
  if [ ! -e "${web_install_dir}/sbin/nginx" ]; then
    echo "${CWARNING}Web server not found! ${CEND}"
    return
  fi
  [ -d "${web_install_dir}/conf/vhost" ] && Domain_List=$(ls ${web_install_dir}/conf/vhost | sed "s@.conf@@g")
  if [ -n "${Domain_List}" ]; then
    echo
    echo "Virtualhost list:"
    for D in ${Domain_List}; do echo ${CMSG}${D}${CEND}; done
  else
    echo "${CWARNING}Virtualhost was not exist! ${CEND}"
  fi
}

if [[ ${ARG_NUM} == 0 ]]; then
  Add_Vhost
else
  [[ "${add_flag}" == y || "${proxy_flag}" == y || "${sslquiet_flag}" == y ]] && Add_Vhost
  [[ "${list_flag}" == y ]] && List_Vhost
  [[ "${delete_flag}" == y ]] && Del_NGX_Vhost
fi
