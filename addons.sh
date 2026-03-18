#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp
#
#

export PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
clear
printf "
#######################################################################
#                    Install/Uninstall Extensions                     #
#######################################################################
"
# Check if user is root
# shellcheck disable=SC2046
[ "$(id -u)" != "0" ] && { echo "${CFAILURE}Error: You must be root to run this script${CEND}"; exit 1; }

current_dir=$(dirname "$(readlink -f $0)")
# shellcheck disable=SC2164
pushd ${current_dir} > /dev/null

. ./versions.txt
. ./options.conf
. ./include/common.sh
. ./include/ip_detect.sh
. ./include/color.sh
. ./include/check_os.sh
. ./include/download.sh
. ./include/get_char.sh

. ./include/composer.sh

. ./include/fail2ban.sh

. ./include/ngx_lua_waf.sh

# get the out ip country
OUTIP_STATE=$(ip_state)

# shellcheck disable=SC2154
Show_Help() {
  echo
  echo "Usage: $0  command ...
  --help, -h                  Show this help message
  --install, -i               Install
  --uninstall, -u             Uninstall
  --composer                  Composer
  --fail2ban                  Fail2ban
  --ngx_lua_waf               Ngx_lua_waf
  "
}

ARG_NUM=$#

# Parse command-line arguments (pure bash, no eval)
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      Show_Help; exit 0
      ;;
    -i|--install)
      install_flag=y; shift 1
      ;;
    -u|--uninstall)
      uninstall_flag=y; shift 1
      ;;
    --composer)
      composer_flag=y; shift 1
      ;;
    --fail2ban)
      fail2ban_flag=y; shift 1
      ;;
    --ngx_lua_waf)
      ngx_lua_waf_flag=y; shift 1
      ;;
    --)
      shift
      ;;
    *)
      echo "${CWARNING}ERROR: unknown argument: $1 ${CEND}" && Show_Help && exit 1
      ;;
  esac
done

ACTION_FUN() {
  unset install_flag uninstall_flag
  while :; do
    echo
    echo "Please select an action:"
    printf "%b" "\t${CMSG}1${CEND}. install\n"
    printf "%b" "\t${CMSG}2${CEND}. uninstall\n"
    read -e -p "Please input a number:(Default 1 press Enter) " ACTION
    ACTION=${ACTION:-1}
    if [[ ! "${ACTION}" =~ ^[1-2]$ ]]; then
      echo "${CWARNING}input error! Please only input number 1~2${CEND}"
    else
      [[ "${ACTION}" == 1 ]] && install_flag=y
      [[ "${ACTION}" == 2 ]] && uninstall_flag=y
      break
    fi
  done
}

Menu() {
  while :;do
    printf "
What Are You Doing?
\t${CMSG}1${CEND}. Install/Uninstall PHP Composer
\t${CMSG}2${CEND}. Install/Uninstall fail2ban
\t${CMSG}3${CEND}. Install/Uninstall ngx_lua_waf
\t${CMSG}q${CEND}. Exit
"
    read -e -p "Please input the correct option: " Number
    if [[ ! "${Number}" =~ ^[1-3q]$ ]]; then
      echo "${CFAILURE}input error! Please only input 1~3 and q${CEND}"
    else
      case "${Number}" in
        1)
          ACTION_FUN
          if [ "${install_flag}" = 'y' ]; then
            Install_composer
          elif [ "${uninstall_flag}" = 'y' ]; then
            Uninstall_composer
          fi
          ;;
        2)
          ACTION_FUN
          if [ "${install_flag}" = 'y' ]; then
            Install_fail2ban
          elif [ "${uninstall_flag}" = 'y' ]; then
            Uninstall_fail2ban
          fi
          ;;
        3)
          ACTION_FUN
          if [ "${install_flag}" = 'y' ]; then
            # shellcheck disable=SC2154
            [ -e "${nginx_install_dir}/sbin/nginx" ] && Nginx_lua_waf
            # shellcheck disable=SC2154
            [ -e "${tengine_install_dir}/sbin/nginx" ] && Tengine_lua_waf
            # shellcheck disable=SC2154
            [ -e "${openresty_install_dir}/nginx/sbin/nginx" ] && echo "${CMSG}OpenResty has built-in Lua support${CEND}"
            enable_lua_waf
          elif [ "${uninstall_flag}" = 'y' ]; then
            disable_lua_waf
          fi
          ;;
        q)
          exit
          ;;
        *)
          echo "${CWARNING}Invalid option!${CEND}"
          ;;
      esac
    fi
  done
}

if [[ ${ARG_NUM} == 0 ]]; then
  Menu
else
  if [[ "${composer_flag}" == y ]]; then
    if [ "${install_flag}" = 'y' ]; then
      Install_composer
    elif [ "${uninstall_flag}" = 'y' ]; then
      Uninstall_composer
    fi
  fi
  if [[ "${fail2ban_flag}" == y ]]; then
    if [ "${install_flag}" = 'y' ]; then
      Install_fail2ban
    elif [ "${uninstall_flag}" = 'y' ]; then
      Uninstall_fail2ban
    fi
  fi
  if [[ "${ngx_lua_waf_flag}" == y ]]; then
    if [ "${install_flag}" = 'y' ]; then
      [ -e "${nginx_install_dir}/sbin/nginx" ] && Nginx_lua_waf
      [ -e "${tengine_install_dir}/sbin/nginx" ] && Tengine_lua_waf
      [ -e "${openresty_install_dir}/nginx/sbin/nginx" ] && echo "${CMSG}OpenResty has built-in Lua support${CEND}"
      enable_lua_waf
    elif [ "${uninstall_flag}" = 'y' ]; then
      disable_lua_waf
    fi
  fi
fi
