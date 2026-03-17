#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp
#
#

export PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
clear
printf "
#######################################################################
#                     Setup the backup parameters                     #
#######################################################################
"
# Check if user is root
[ "$(id -u)" != "0" ] && { echo "${CFAILURE}Error: You must be root to run this script${CEND}"; exit 1; }

current_dir=$(dirname "$(readlink -f $0)")
pushd ${current_dir} > /dev/null
. ./options.conf
. ./versions.txt
. ./include/ip_detect.sh
. ./include/color.sh
. ./include/check_os.sh
. ./include/check_dir.sh
. ./include/download.sh

while :; do echo
  echo 'Please select your backup destination:'
  printf "%b" "\t${CMSG}1${CEND}. Localhost\n"
  printf "%b" "\t${CMSG}2${CEND}. Remote host\n"
  printf "%b" "\t${CMSG}3${CEND}. Aliyun OSS\n"
  printf "%b" "\t${CMSG}4${CEND}. Qcloud COS\n"
  printf "%b" "\t${CMSG}5${CEND}. UPYUN\n"
  printf "%b" "\t${CMSG}6${CEND}. QINIU\n"
  printf "%b" "\t${CMSG}7${CEND}. Amazon S3\n"
  printf "%b" "\t${CMSG}8${CEND}. Dropbox\n"
  read -e -p "Please input numbers:(Default 1 press Enter) " desc_bk
  desc_bk=${desc_bk:-'1'}
  array_desc=(${desc_bk})
  array_all=(1 2 3 4 5 6 7 8)
  for v in ${array_desc[@]}
  do
    [ -z "$(echo ${array_all[@]} | grep -w ${v})" ] && desc_flag=1
  done
  if [[ "${1}" == 1 ]]; then
    unset desc_flag
    echo; echo "${CWARNING}input error! Please only input number 1~8${CEND}"; echo
    continue
  else
    sed -i 's@^backup_destination=.*@backup_destination=@' ./options.conf
    break
  fi
done

[ -n "$(echo ${desc_bk} | grep -w 1)" ] && sed -i 's@^backup_destination=.*@backup_destination=local@' ./options.conf
[ -n "$(echo ${desc_bk} | grep -w 2)" ] && sed -i 's@^backup_destination=.*@&,remote@' ./options.conf
[ -n "$(echo ${desc_bk} | grep -w 3)" ] && sed -i 's@^backup_destination=.*@&,oss@' ./options.conf
[ -n "$(echo ${desc_bk} | grep -w 4)" ] && sed -i 's@^backup_destination=.*@&,cos@' ./options.conf
[ -n "$(echo ${desc_bk} | grep -w 5)" ] && sed -i 's@^backup_destination=.*@&,upyun@' ./options.conf
[ -n "$(echo ${desc_bk} | grep -w 6)" ] && sed -i 's@^backup_destination=.*@&,qiniu@' ./options.conf
[ -n "$(echo ${desc_bk} | grep -w 7)" ] && sed -i 's@^backup_destination=.*@&,s3@' ./options.conf
[ -n "$(echo ${desc_bk} | grep -w 8)" ] && sed -i 's@^backup_destination=.*@&,dropbox@' ./options.conf
sed -i 's@^backup_destination=,@backup_destination=@' ./options.conf

while :; do echo
  echo 'Please select your backup content:'
  printf "%b" "\t${CMSG}1${CEND}. Only Database\n"
  printf "%b" "\t${CMSG}2${CEND}. Only Website\n"
  printf "%b" "\t${CMSG}3${CEND}. Database and Website\n"
  read -e -p "Please input a number:(Default 1 press Enter) " content_bk
  content_bk=${content_bk:-1}
  if [[ ! ${content_bk} =~ ^[1-3]$ ]]; then
    echo "${CWARNING}input error! Please only input number 1~3${CEND}"
  else
    break
  fi
done

[[ "${1}" == 1 ]] && sed -i 's@^backup_content=.*@backup_content=db@' ./options.conf
[[ "${1}" == 2 ]] && sed -i 's@^backup_content=.*@backup_content=web@' ./options.conf
[[ "${1}" == 3 ]] && sed -i 's@^backup_content=.*@backup_content=db,web@' ./options.conf

if [ -n "$(echo ${desc_bk} | grep -Ew '1|2')" ]; then
  while :; do echo
    echo "Please enter the directory for save the backup file: "
    read -e -p "(Default directory: ${backup_dir}): " new_backup_dir
    new_backup_dir=${new_backup_dir:-${backup_dir}}
    if [ -z "$(echo ${new_backup_dir}| grep '^/')" ]; then
      echo "${CWARNING}input error! ${CEND}"
    else
      break
    fi
  done
  sed -i "s@^backup_dir=.*@backup_dir=${new_backup_dir}@" ./options.conf
fi

while :; do echo
  echo "Please enter a valid backup number of days: "
  read -e -p "(Default days: 5): " expired_days
  expired_days=${expired_days:-5}
  [ -n "$(echo ${expired_days} | sed -n "/^[0-9]\+$/p")" ] && break || echo "${CWARNING}input error! Please only enter numbers! ${CEND}"
done
sed -i "s@^expired_days=.*@expired_days=${expired_days}@" ./options.conf

if [ "${content_bk}" != '2' ]; then
  databases=$(${db_install_dir}/bin/mysql -uroot -p"${dbrootpwd}" -e "show databases\G" | grep Database | awk '{print $2}' | grep -Evw "(performance_schema|information_schema|mysql|sys)")
  while :; do echo
    echo "Please enter one or more name for database, separate multiple database names with commas: "
    read -e -p "(Default database: $(echo $databases | tr ' ' ',')) " db_name
    db_name=$(echo ${db_name} | tr -d ' ')
    [ -z "${db_name}" ] && db_name="$(echo $databases | tr ' ' ',')"
    D_tmp=0
    for D in $(echo ${db_name} | tr ',' ' ')
    do
      [ -z "$(echo $databases | grep -w $D)" ] && { echo "${CWARNING}$D was not exist! ${CEND}" ; D_tmp=1; }
    done
    [ "$D_tmp" != '1' ] && break
  done
  sed -i "s@^db_name=.*@db_name=${db_name}@" ./options.conf
fi

if [ "${content_bk}" != '1' ]; then
  websites=$(ls ${wwwroot_dir})
  while :; do echo
    echo "Please enter one or more name for website, separate multiple website names with commas: "
    read -e -p "(Default website: $(echo $websites | tr ' ' ',')) " website_name
    website_name=$(echo ${website_name} | tr -d ' ')
    [ -z "${website_name}" ] && website_name="$(echo $websites | tr ' ' ',')"
    W_tmp=0
    for W in $(echo ${website_name} | tr ',' ' ')
    do
      [ ! -e "${wwwroot_dir}/$W" ] && { echo "${CWARNING}${wwwroot_dir}/$W not exist! ${CEND}" ; W_tmp=1; }
    done
    [ "$W_tmp" != '1' ] && break
  done
  sed -i "s@^website_name=.*@website_name=${website_name}@" ./options.conf
fi

echo
echo "You have to backup the content:"
[ "${content_bk}" != '2' ] && echo "Database: ${CMSG}${db_name}${CEND}"
[ "${content_bk}" != '1' ] && echo "Website: ${CMSG}${website_name}${CEND}"

if [ -n "$(echo ${desc_bk} | grep -w 2)" ]; then
  > tools/iplist.txt
  while :; do echo
    read -e -p "Please enter the remote host address: " remote_address
    [[ -z "${remote_address}" || "${remote_address}" == 127.0.0.1 ]] && continue
    echo
    read -e -p "Please enter the remote host port(Default: 22) : " remote_port
    remote_port=${remote_port:-22}
    echo
    read -e -p "Please enter the remote host user(Default: root) : " remote_user
    remote_user=${remote_user:-root}
    echo
    read -e -p "Please enter the remote host password: " remote_password
    IPcode=$(echo "ibase=16;$(echo "${remote_address}" | xxd -ps -u)"|bc|tr -d '\\'|tr -d '\n')
    Portcode=$(echo "ibase=16;$(echo "${remote_port}" | xxd -ps -u)"|bc|tr -d '\\'|tr -d '\n')
    PWcode=$(echo "ibase=16;$(echo "$remote_password" | xxd -ps -u)"|bc|tr -d '\\'|tr -d '\n')
    [ -e "~/.ssh/known_hosts" ] && grep ${remote_address} ~/.ssh/known_hosts | sed -i "/${remote_address}/d" ~/.ssh/known_hosts
    ./tools/mssh.exp ${IPcode}P ${remote_user} ${PWcode}P ${Portcode}P true 10
    if [ $? -eq 0 ]; then
      [ -z "$(grep ${remote_address} tools/iplist.txt)" ] && echo "${remote_address} ${remote_port} ${remote_user} $remote_password" >> tools/iplist.txt || echo "${CWARNING}${remote_address} has been added! ${CEND}"
      while :; do
        read -e -p "Do you want to add more host ? [y/n]: " morehost_flag
        if [[ ! ${morehost_flag} =~ ^[y,n]$ ]]; then
          echo "${CWARNING}input error! Please only input 'y' or 'n'${CEND}"
        else
          break
        fi
      done
      [[ "${1}" == n ]] && break
    fi
  done
fi

if [ -n "$(echo ${desc_bk} | grep -w 3)" ]; then
  if [ ! -e "/usr/local/bin/ossutil" ]; then
    curl -sSL https://gosspublic.alicdn.com/ossutil/install.sh > /tmp/ossutil_install.sh && chmod +x /tmp/ossutil_install.sh && sudo /tmp/ossutil_install.sh
  fi
  while :; do echo
    echo 'Please select your backup aliyun datacenter:'
    printf "%b" "\t ${CMSG}1${CEND}. cn-hangzhou-华东1 (杭州)          ${CMSG}2${CEND}. cn-shanghai-华东2 (上海)\n"
    printf "%b" "\t ${CMSG}3${CEND}. cn-nanjing-华东5 (南京)           ${CMSG}4${CEND}. cn-fuzhou-华东6 (福州)\n"
    printf "%b" "\t ${CMSG}5${CEND}. cn-wuhan-华中1 (武汉)             ${CMSG}6${CEND}. cn-qingdao-华北1 (青岛)\n"
    printf "%b" "\t ${CMSG}7${CEND}. cn-beijing-华北2 (北京)           ${CMSG}8${CEND}. cn-zhangjiakou-华北3 (张家口)\n"
    printf "%b" "\t ${CMSG}9${CEND}. cn-huhehaote-华北5 (呼和浩特)    ${CMSG}10${CEND}. cn-wulanchabu-华北6 (乌兰察布)\n"
    printf "%b" "\t${CMSG}11${CEND}. cn-shenzhen-华南1 (深圳)         ${CMSG}12${CEND}. cn-heyuan-华南2 (河源)\n"
    printf "%b" "\t${CMSG}13${CEND}. cn-guangzhou-华南3 (广州)        ${CMSG}14${CEND}. cn-chengdu-西南1 (成都)\n"
    printf "%b" "\t${CMSG}15${CEND}. cn-hongkong-香港                 ${CMSG}16${CEND}. us-west-1-美国 (硅谷)\n"
    printf "%b" "\t${CMSG}17${CEND}. us-east-1-美国 (弗吉尼亚)        ${CMSG}18${CEND}. ap-northeast-1-日本 (东京)\n"
    printf "%b" "\t${CMSG}19${CEND}. ap-northeast-2-韩国 (首尔)       ${CMSG}20${CEND}. ap-southeast-1-新加坡\n"
    printf "%b" "\t${CMSG}21${CEND}. ap-southeast-3-马来西亚 (吉隆坡) ${CMSG}22${CEND}. ap-southeast-5-印度尼西亚 (雅加达)\n"
    printf "%b" "\t${CMSG}23${CEND}. ap-southeast-6-菲律宾 (马尼拉)   ${CMSG}24${CEND}. ap-southeast-7-泰国 (曼谷)\n"
    printf "%b" "\t${CMSG}25${CEND}. eu-central-1-德国 (法兰克福)     ${CMSG}26${CEND}. eu-west-1-英国 (伦敦)\n"
    printf "%b" "\t${CMSG}27${CEND}. me-east-1-阿联酋 (迪拜)\n"
    read -e -p "Please input a number:(Default 1 press Enter) " Location
    Location=${Location:-1}
    if [[ "${Location}" =~ ^[1-9]$|^1[0-9]$|^2[0-7]$ ]]; then
      break
    else
      echo "${CWARNING}input error! Please only input number 1~27${CEND}"
    fi
  done
  [[ "${1}" == 1 ]] && Host=oss-cn-hangzhou-internal.aliyuncs.com
  [[ "${1}" == 2 ]] && Host=oss-cn-shanghai-internal.aliyuncs.com
  [[ "${1}" == 3 ]] && Host=oss-cn-nanjing-internal.aliyuncs.com
  [[ "${1}" == 4 ]] && Host=oss-cn-fuzhou-internal.aliyuncs.com
  [[ "${1}" == 5 ]] && Host=oss-cn-wuhan-lr-internal.aliyuncs.com
  [[ "${1}" == 6 ]] && Host=oss-cn-qingdao-internal.aliyuncs.com
  [[ "${1}" == 7 ]] && Host=oss-cn-beijing-internal.aliyuncs.com
  [[ "${1}" == 8 ]] && Host=oss-cn-zhangjiakou-internal.aliyuncs.com
  [[ "${1}" == 9 ]] && Host=oss-cn-huhehaote-internal.aliyuncs.com
  [[ "${1}" == 10 ]] && Host=oss-cn-wulanchabu-internal.aliyuncs.com
  [[ "${1}" == 11 ]] && Host=oss-cn-shenzhen-internal.aliyuncs.com
  [[ "${1}" == 12 ]] && Host=oss-cn-heyuan-internal.aliyuncs.com
  [[ "${1}" == 13 ]] && Host=oss-cn-guangzhou-internal.aliyuncs.com
  [[ "${1}" == 14 ]] && Host=oss-cn-chengdu-internal.aliyuncs.com
  [[ "${1}" == 15 ]] && Host=oss-cn-hongkong-internal.aliyuncs.com
  [[ "${1}" == 16 ]] && Host=oss-us-west-1-internal.aliyuncs.com
  [[ "${1}" == 17 ]] && Host=oss-us-east-1-internal.aliyuncs.com
  [[ "${1}" == 18 ]] && Host=oss-ap-northeast-1-internal.aliyuncs.com
  [[ "${1}" == 19 ]] && Host=oss-ap-northeast-2-internal.aliyuncs.com
  [[ "${1}" == 20 ]] && Host=oss-ap-southeast-1-internal.aliyuncs.com
  [[ "${1}" == 21 ]] && Host=oss-ap-southeast-3-internal.aliyuncs.com
  [[ "${1}" == 22 ]] && Host=oss-ap-southeast-5-internal.aliyuncs.com
  [[ "${1}" == 23 ]] && Host=oss-ap-southeast-6-internal.aliyuncs.com
  [[ "${1}" == 24 ]] && Host=oss-ap-southeast-7-internal.aliyuncs.com
  [[ "${1}" == 25 ]] && Host=oss-eu-central-1-internal.aliyuncs.com
  [[ "${1}" == 26 ]] && Host=oss-eu-west-1-internal.aliyuncs.com
  [[ "${1}" == 27 ]] && Host=oss-me-east-1-internal.aliyuncs.com
  [[ "$(conn_port --host ${Host} --port 80)" == "false" ]] && Host=$(echo ${Host} | sed 's@-internal@@g')
  [ -e "/root/.ossutilconfig" ] && rm -f /root/.ossutilconfig
  while :; do echo
    read -e -p "Please enter the aliyun oss Access Key ID: " KeyID
    [ -z "${KeyID}" ] && continue
    echo
    read -e -p "Please enter the aliyun oss Access Key Secret: " KeySecret
    [ -z "${KeySecret}" ] && continue
    ossutil ls -e ${Host} -i ${KeyID} -k ${KeySecret} > /dev/null 2>&1
    if [ $? -eq 0 ]; then
      ossutil config -e ${Host} -i ${KeyID} -k ${KeySecret} > /dev/null 2>&1
      while :; do echo
        read -e -p "Please enter the aliyun oss bucket: " OSS_BUCKET
        ossutil mb oss://${OSS_BUCKET} > /dev/null 2>&1
        if [ $? -eq 0 ]; then
          echo "${CMSG}Bucket oss://${OSS_BUCKET}/ created${CEND}"
          sed -i "s@^oss_bucket=.*@oss_bucket=${OSS_BUCKET}@" ./options.conf
          break
        else
          echo "${CWARNING}[${OSS_BUCKET}] already exists, You need to use the OSS Console to create a bucket for storing.${CEND}"
        fi
      done
      break
    fi
  done
fi

if [ -n "$(echo ${desc_bk} | grep -w 4)" ]; then
  if [ ! -e "/usr/local/bin/coscli" ]; then
    wget -qc https://cosbrowser.cloud.tencent.com/software/coscli/coscli-linux -O /usr/local/bin/coscli
    chmod +x /usr/local/bin/coscli
  fi

  while :; do echo
    echo 'Please select your backup qcloud datacenter:'
    printf "%b" "\t ${CMSG} 1${CEND}. ap-beijing-北京              ${CMSG}2${CEND}. ap-nanjing-南京\n"
    printf "%b" "\t ${CMSG} 3${CEND}. ap-shanghai-上海             ${CMSG}4${CEND}. ap-guangzhou-广州\n"
    printf "%b" "\t ${CMSG} 5${CEND}. ap-chengdu-成都              ${CMSG}6${CEND}. ap-chongqing-重庆\n"
    printf "%b" "\t ${CMSG} 7${CEND}. ap-shenzhen-fsi-深圳金融     ${CMSG}8${CEND}. ap-shanghai-fsi-上海金融\n"
    printf "%b" "\t ${CMSG} 9${CEND}. ap-beijing-fsi-北京金融     ${CMSG}10${CEND}. ap-hongkong-香港\n"
    printf "%b" "\t ${CMSG}11${CEND}. ap-singapore-新加坡         ${CMSG}12${CEND}. ap-mumbai-孟买\n"
    printf "%b" "\t ${CMSG}13${CEND}. ap-jakarta-雅加达           ${CMSG}14${CEND}. ap-seoul-首尔\n"
    printf "%b" "\t ${CMSG}15${CEND}. ap-bangkok-曼谷             ${CMSG}16${CEND}. ap-tokyo-东京\n"
    printf "%b" "\t ${CMSG}17${CEND}. na-siliconvalley-硅谷       ${CMSG}18${CEND}. na-ashburn-弗吉尼亚\n"
    printf "%b" "\t ${CMSG}19${CEND}. na-toronto-多伦多           ${CMSG}20${CEND}. sa-saopaulo-圣保罗\n"
    printf "%b" "\t ${CMSG}21${CEND}. eu-frankfurt-法兰克福\n"
    read -e -p "Please input a number:(Default 1 press Enter) " Location
    Location=${Location:-1}
    if [[ "${Location}" =~ ^[1-9]$|^1[0-9]$|^2[0-1]$ ]]; then
      break
    else
      echo "${CWARNING}input error! Please only input number 1~21${CEND}"
    fi
  done
  [[ "${1}" == 1 ]] && REGION='ap-beijing'
  [[ "${1}" == 2 ]] && REGION='ap-nanjing'
  [[ "${1}" == 3 ]] && REGION='ap-shanghai'
  [[ "${1}" == 4 ]] && REGION='ap-guangzhou'
  [[ "${1}" == 5 ]] && REGION='ap-chengdu'
  [[ "${1}" == 6 ]] && REGION='ap-chongqing'
  [[ "${1}" == 7 ]] && REGION='ap-shenzhen-fsi'
  [[ "${1}" == 8 ]] && REGION='ap-shanghai-fsi'
  [[ "${1}" == 9 ]] && REGION='ap-beijing-fsi'
  [[ "${1}" == 10 ]] && REGION='ap-hongkong'
  [[ "${1}" == 11 ]] && REGION='ap-singapore'
  [[ "${1}" == 12 ]] && REGION='ap-mumbai'
  [[ "${1}" == 13 ]] && REGION='ap-jakarta'
  [[ "${1}" == 14 ]] && REGION='ap-seoul'
  [[ "${1}" == 15 ]] && REGION='ap-bangkok'
  [[ "${1}" == 16 ]] && REGION='ap-tokyo'
  [[ "${1}" == 17 ]] && REGION='na-siliconvalley'
  [[ "${1}" == 18 ]] && REGION='na-ashburn'
  [[ "${1}" == 19 ]] && REGION='na-toronto'
  [[ "${1}" == 20 ]] && REGION='sa-saopaulo'
  [[ "${1}" == 21 ]] && REGION='eu-frankfurt'
  while :; do echo
    read -e -p "Please enter the Qcloud COS SECRET_ID: " SECRET_ID
    [ -z "${SECRET_ID}" ] && continue
    echo
    read -e -p "Please enter the Qcloud COS SECRET_KEY: " SECRET_KEY
    [ -z "${SECRET_KEY}" ] && continue
    echo
    read -e -p "Please enter the Qcloud COS BUCKET: " COS_BUCKET
    [ -z "${COS_BUCKET}" ] && continue
    cat > ~/.cos.yaml << EOF
cos:
  base:
    secretid: ${SECRET_ID}
    secretkey: ${SECRET_KEY}
    protocol: https
  buckets:
  - name: ${COS_BUCKET}
    endpoint: cos.${REGION}.myqcloud.com
EOF
    coscli ls cos://${COS_BUCKET} > /dev/null 2>&1
    if [ $? -eq 0 ]; then
      echo "${CMSG}SECRET_ID/SECRET_KEY/REGION/BUCKET OK${CEND}"
      sed -i "s@^cos_bucket=.*@cos_bucket=${COS_BUCKET}@" ./options.conf
      echo
      break
    else
      coscli mb cos://${COS_BUCKET} -e cos.${REGION}.myqcloud.com > /dev/null 2>&1
      if [ $? -eq 0 ]; then
        echo "${CMSG}Bucket ${COS_BUCKET} created${CEND}"
        sed -i "s@^cos_bucket=.*@cos_bucket=${COS_BUCKET}@" ./options.conf
        echo
        break
      else
        echo "${CWARNING}input error! SECRET_ID/SECRET_KEY/REGION/BUCKET invalid${CEND}"
        continue
      fi
    fi
  done
fi

if [ -n "$(echo ${desc_bk} | grep -w 5)" ]; then
  if [ ! -e "/usr/local/bin/upx" ]; then
    UPX_TMP_DIR=$(mktemp -d /tmp/lnmp_upx.XXXXXX)
    trap "rm -rf $UPX_TMP_DIR" EXIT
    if [[ "${1}" == y ]]; then
      wget -qc https://collection.b0.upaiyun.com/softwares/upx/upx_0.4.8_linux_arm64.tar.gz -O $UPX_TMP_DIR/upx_0.4.8_linux_arm64.tar.gz
      tar xzf $UPX_TMP_DIR/upx_0.4.8_linux_arm64.tar.gz -C $UPX_TMP_DIR/
    else
      wget -qc https://collection.b0.upaiyun.com/softwares/upx/upx_0.4.8_linux_amd64.tar.gz -O $UPX_TMP_DIR/upx_0.4.8_linux_x86_64.tar.gz
      tar xzf $UPX_TMP_DIR/upx_0.4.8_linux_x86_64.tar.gz -C $UPX_TMP_DIR/
    fi
    /bin/mv $UPX_TMP_DIR/upx /usr/local/bin/upx
    chmod +x /usr/local/bin/upx
    rm -rf $UPX_TMP_DIR
    trap - EXIT
  fi
  while :; do echo
    read -e -p "Please enter the upyun ServiceName: " ServiceName
    [ -z "${ServiceName}" ] && continue
    echo
    read -e -p "Please enter the upyun Operator: " Operator
    [ -z "${Operator}" ] && continue
    echo
    read -e -p "Please enter the upyun Password: " Password
    [ -z "${Password}" ] && continue
    echo
    upx login ${ServiceName} ${Operator} ${Password} > /dev/null 2>&1
    if [ $? = 0 ]; then
      echo "${CMSG}ServiceName/Operator/Password OK${CEND}"
      echo
      break
    else
      echo "${CWARNING}input error! ServiceName/Operator/Password invalid${CEND}"
    fi
  done
fi

if [ -n "$(echo ${desc_bk} | grep -w 6)" ]; then
  if [ ! -e "/usr/local/bin/qshell" ]; then
    QSHELL_TMP_DIR=$(mktemp -d /tmp/lnmp_qshell.XXXXXX)
    trap "rm -rf $QSHELL_TMP_DIR" EXIT
    if [[ "${1}" == y ]]; then
      wget -qc https://github.com/qiniu/qshell/releases/download/v2.15.0/qshell-v2.15.0-linux-arm64.tar.gz -O $QSHELL_TMP_DIR/qshell-v2.15.0-linux-arm64.tar.gz
      tar xzf $QSHELL_TMP_DIR/qshell-v2.15.0-linux-arm64.tar.gz -C /usr/local/bin/
    else
      wget -qc https://github.com/qiniu/qshell/releases/download/v2.15.0/qshell-v2.15.0-linux-amd64.tar.gz -O $QSHELL_TMP_DIR/qshell-v2.15.0-linux-amd64.tar.gz
      tar xzf $QSHELL_TMP_DIR/qshell-v2.15.0-linux-amd64.tar.gz -C /usr/local/bin/
    fi
    chmod +x /usr/local/bin/qshell
    rm -rf $QSHELL_TMP_DIR
    trap - EXIT
  fi
  while :; do echo
    echo 'Please select your backup qiniu datacenter:'
    printf "%b" "\t ${CMSG} 1${CEND}. 华东            ${CMSG}2${CEND}. 华北\n"
    printf "%b" "\t ${CMSG} 3${CEND}. 华南            ${CMSG}4${CEND}. 北美\n"
    printf "%b" "\t ${CMSG} 5${CEND}. 东南亚          ${CMSG}6${CEND}. 华东-浙江2\n"
    read -e -p "Please input a number:(Default 1 press Enter) " Location
    Location=${Location:-1}
    if [[ "${Location}" =~ ^[1-6]$ ]]; then
      break
    else
      echo "${CWARNING}input error! Please only input number 1~6${CEND}"
    fi
  done
  [[ "${1}" == 1 ]] && zone='z0'
  [[ "${1}" == 2 ]] && zone='z1'
  [[ "${1}" == 3 ]] && zone='z2'
  [[ "${1}" == 4 ]] && zone='na0'
  [[ "${1}" == 5 ]] && zone='as0'
  [[ "${1}" == 6 ]] && zone='cn-east-2'
  while :; do echo
    read -e -p "Please enter the qiniu AccessKey: " AccessKey
    [ -z "${AccessKey}" ] && continue
    echo
    read -e -p "Please enter the qiniu SecretKey: " SecretKey
    [ -z "${SecretKey}" ] && continue
    echo
    read -e -p "Please enter the qiniu bucket: " QINIU_BUCKET
    [ -z "${QINIU_BUCKET}" ] && continue
    echo
    qshell account ${AccessKey} ${SecretKey} backup
    if qshell buckets | grep -w ${QINIU_BUCKET} > /dev/null 2>&1; then
      sed -i "s@^qiniu_bucket=.*@qiniu_bucket=${QINIU_BUCKET}@" ./options.conf
      echo "${CMSG}AccessKey/SecretKey/Bucket OK${CEND}"
      echo
      break
    else
      echo "${CWARNING}input error! AccessKey/SecretKey/Bucket invalid${CEND}"
    fi
  done
fi

if [ -n "$(echo ${desc_bk} | grep -w 7)" ]; then
  if [ ! -e "/usr/local/bin/aws" ] && [ ! -e "/usr/bin/aws" ]; then
    AWS_TMP_DIR=$(mktemp -d /tmp/lnmp_aws.XXXXXX)
    trap "rm -rf $AWS_TMP_DIR" EXIT
    wget -qc https://awscli.amazonaws.com/awscli-exe-linux-$(arch).zip -O $AWS_TMP_DIR/awscliv2.zip
    unzip $AWS_TMP_DIR/awscliv2.zip -d $AWS_TMP_DIR/
    $AWS_TMP_DIR/aws/install
    rm -rf $AWS_TMP_DIR
    trap - EXIT
  fi
  while :; do echo
    echo 'Please select your backup amazon datacenter:'
    printf "%b" "\t ${CMSG} 1${CEND}. us-east-2                    ${CMSG} 2${CEND}. us-east-1\n"
    printf "%b" "\t ${CMSG} 3${CEND}. us-west-1                    ${CMSG} 4${CEND}. us-west-2\n"
    printf "%b" "\t ${CMSG} 5${CEND}. af-south-1                   ${CMSG} 6${CEND}. ap-east-1\n"
    printf "%b" "\t ${CMSG} 7${CEND}. ap-south-2                   ${CMSG} 8${CEND}. ap-southeast-3\n"
    printf "%b" "\t ${CMSG} 9${CEND}. ap-southeast-4               ${CMSG}10${CEND}. ap-south-1\n"
    printf "%b" "\t ${CMSG}11${CEND}. ap-northeast-3               ${CMSG}12${CEND}. ap-northeast-2\n"
    printf "%b" "\t ${CMSG}13${CEND}. ap-southeast-1               ${CMSG}14${CEND}. ap-southeast-2\n"
    printf "%b" "\t ${CMSG}15${CEND}. ap-northeast-1               ${CMSG}16${CEND}. ca-central-1\n"
    printf "%b" "\t ${CMSG}17${CEND}. eu-central-1                 ${CMSG}18${CEND}. eu-west-1\n"
    printf "%b" "\t ${CMSG}19${CEND}. eu-west-2                    ${CMSG}20${CEND}. eu-south-1\n"
    printf "%b" "\t ${CMSG}21${CEND}. eu-west-3                    ${CMSG}22${CEND}. eu-south-2\n"
    printf "%b" "\t ${CMSG}23${CEND}. eu-north-1                   ${CMSG}24${CEND}. eu-central-2\n"
    printf "%b" "\t ${CMSG}25${CEND}. me-south-1                   ${CMSG}26${CEND}. me-central-1\n"
    printf "%b" "\t ${CMSG}27${CEND}. sa-east-1                    ${CMSG}28${CEND}. us-gov-east-1\n"
    printf "%b" "\t ${CMSG}29${CEND}. us-gov-west-1                ${CMSG}30${CEND}. cn-north-1\n"
    printf "%b" "\t ${CMSG}31${CEND}. cn-northwest-1\n"
    read -e -p "Please input a number:(Default 1 press Enter) " Location
    Location=${Location:-1}
    if [[ "${Location}" =~ ^[1-9]$|^[1-2][0-9]$|^3[0-1]$ ]]; then
      break
    else
      echo "${CWARNING}input error! Please only input number 1~31${CEND}"
    fi
  done
  [[ "${1}" == 1 ]] && REGION='us-east-2'
  [[ "${1}" == 2 ]] && REGION='us-east-1'
  [[ "${1}" == 3 ]] && REGION='us-west-1'
  [[ "${1}" == 4 ]] && REGION='us-west-2'
  [[ "${1}" == 5 ]] && REGION='af-south-1'
  [[ "${1}" == 6 ]] && REGION='ap-east-1'
  [[ "${1}" == 7 ]] && REGION='ap-south-2'
  [[ "${1}" == 8 ]] && REGION='ap-southeast-3'
  [[ "${1}" == 9 ]] && REGION='ap-southeast-4'
  [[ "${1}" == 10 ]] && REGION='ap-south-1'
  [[ "${1}" == 11 ]] && REGION='ap-northeast-3'
  [[ "${1}" == 12 ]] && REGION='ap-northeast-2'
  [[ "${1}" == 13 ]] && REGION='ap-southeast-1'
  [[ "${1}" == 14 ]] && REGION='ap-southeast-2'
  [[ "${1}" == 15 ]] && REGION='ap-northeast-1'
  [[ "${1}" == 16 ]] && REGION='ca-central-1'
  [[ "${1}" == 17 ]] && REGION='eu-central-1'
  [[ "${1}" == 18 ]] && REGION='eu-west-1'
  [[ "${1}" == 19 ]] && REGION='eu-west-2'
  [[ "${1}" == 20 ]] && REGION='eu-south-1'
  [[ "${1}" == 21 ]] && REGION='eu-west-3'
  [[ "${1}" == 22 ]] && REGION='eu-south-2'
  [[ "${1}" == 23 ]] && REGION='eu-north-1'
  [[ "${1}" == 24 ]] && REGION='eu-central-2'
  [[ "${1}" == 25 ]] && REGION='me-south-1'
  [[ "${1}" == 26 ]] && REGION='me-central-1'
  [[ "${1}" == 27 ]] && REGION='sa-east-1'
  [[ "${1}" == 28 ]] && REGION='us-gov-east-1'
  [[ "${1}" == 29 ]] && REGION='us-gov-west-1'
  [[ "${1}" == 30 ]] && REGION='cn-north-1'
  [[ "${1}" == 31 ]] && REGION='cn-northwest-1'
  while :; do echo
    read -e -p "Please enter the AWS Access Key: " ACCESS_KEY
    [ -z "${ACCESS_KEY}" ] && continue
    echo
    read -e -p "Please enter the AWS Secret Key: " SECRET_KEY
    [ -z "${SECRET_KEY}" ] && continue
    aws configure set aws_access_key_id ${ACCESS_KEY}
    aws configure set aws_secret_access_key ${SECRET_KEY}
    aws configure set region ${REGION}
    aws sts get-caller-identity > /dev/null 2>&1
    if [ $? -eq 0 ]; then
      echo "${CMSG}ACCESS_KEY/SECRET_KEY OK${CEND}"
      while :; do echo
        read -e -p "Please enter the Amazon S3 bucket: " S3_BUCKET
        [ -z "${S3_BUCKET}" ] && continue
        aws s3 ls s3://${S3_BUCKET} > /dev/null 2>&1
        if [ $? -eq 0 ]; then
          echo "${CMSG}Bucket s3://${S3_BUCKET}/ existed${CEND}"
          sed -i "s@^s3_bucket=.*@s3_bucket=${S3_BUCKET}@" ./options.conf
          break
        else
          aws s3 mb s3://${S3_BUCKET} > /dev/null 2>&1
          if [ $? -eq 0 ]; then
            echo "${CMSG}Bucket s3://${S3_BUCKET}/ created${CEND}"
            sed -i "s@^s3_bucket=.*@s3_bucket=${S3_BUCKET}@" ./options.conf
            break
          else
            echo "${CWARNING}The requested bucket name is not available. The bucket namespace is shared by all users of the system. Please select a different name and try again.${CEND}"
            continue
          fi
        fi
      done
      break
    else
      echo "${CWARNING}input error! ACCESS_KEY/SECRET_KEY invalid${CEND}"
      continue
    fi
  done
fi

if [ -n "$(echo ${desc_bk} | grep -w 8)" ]; then
  if [ ! -e "/usr/local/bin/dbxcli" ]; then
    if [[ "${1}" == y ]]; then
      wget -qc https://github.com/dropbox/dbxcli/releases/download/v3.0.0/dbxcli-linux-arm -O /usr/local/bin/dbxcli
    else
      wget -qc https://github.com/dropbox/dbxcli/releases/download/v3.0.0/dbxcli-linux-amd64 -O /usr/local/bin/dbxcli
    fi
    chmod +x /usr/local/bin/dbxcli
  fi
  while :; do echo
    if dbxcli account; then
      break
    fi
  done
fi
