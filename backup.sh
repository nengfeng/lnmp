#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp
# Description: Backup script for databases and websites
#              Supports multiple backup destinations: local, remote, OSS, COS, S3, etc.

export PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# Check if user is root
[ "$(id -u)" != "0" ] && { echo "${CFAILURE}Error: You must be root to run this script${CEND}"; exit 1; }

current_dir=$(dirname "$(readlink -f "$0")")
pushd "${current_dir}/tools" > /dev/null
. ../options.conf
. ../include/color.sh
[ ! -e "${backup_dir}" ] && mkdir -p "${backup_dir}"

# ============================================
# Helper Functions
# ============================================

# Get list of items from comma-separated string
# Usage: get_items "item1,item2,item3"
get_items() {
  echo "$1" | tr ',' ' '
}

# Check if local backup is also configured
# Usage: has_local_backup
has_local_backup() {
  echo "${backup_destination}" | grep -qw 'local'
}

# Get cloud storage command based on destination type
# Usage: get_cloud_commands destination_type
get_cloud_commands() {
  local dest_type="$1"
  
  case "${dest_type}" in
    oss)
      echo "ossutil cp -f"
      ;;
    cos)
      echo "coscli sync"
      ;;
    upyun)
      echo "upx put"
      ;;
    qiniu)
      echo "qshell rput"
      ;;
    s3)
      echo "aws s3 sync"
      ;;
    dropbox)
      echo "dbxcli put"
      ;;
    *)
      echo ""
      ;;
  esac
}

# Delete old files from cloud storage
# Usage: cloud_delete_old destination_type bucket_name
cloud_delete_old() {
  local dest_type="$1"
  local bucket_name="$2"
  local old_date
  old_date=$(date +%F --date="${expired_days} days ago")
  
  case "${dest_type}" in
    oss)
      ossutil rm -rf "oss://${bucket_name}/${old_date}/"
      ;;
    cos)
      coscli rm -rf "cos://${bucket_name}/${old_date}" > /dev/null 2>&1
      ;;
    upyun)
      upx rm -a "${old_date}" > /dev/null 2>&1
      ;;
    qiniu)
      qshell listbucket "${bucket_name}" "/${old_date}" /tmp/qiniu.txt > /dev/null 2>&1
      qshell batchdelete -force "${bucket_name}" /tmp/qiniu.txt > /dev/null 2>&1
      rm -f /tmp/qiniu.txt
      ;;
    s3)
      aws s3 rm -r "s3://${bucket_name}/${old_date}" > /dev/null 2>&1
      ;;
    dropbox)
      dbxcli rm -f "${old_date}" > /dev/null 2>&1
      ;;
  esac
}

# ============================================
# Database Backup Functions
# ============================================

# Backup database to local storage
# Usage: db_local_backup
db_local_backup() {
  for D in $(get_items "${db_name}"); do
    ./db_bk.sh "${D}"
  done
}

# Backup database to remote server
# Usage: db_remote_backup
db_remote_backup() {
  for D in $(get_items "${db_name}"); do
    ./db_bk.sh "${D}"
    local DB_GREP DB_FILE
    DB_GREP="DB_${D}_$(date +%Y%m%d)"
    DB_FILE=$(ls -lrt "${backup_dir}" | grep "${DB_GREP}" | tail -1 | awk '{print $NF}')
    echo "file:::${backup_dir}/${DB_FILE} ${backup_dir} push" >> config_backup.txt
    echo "com:::[ -e \"${backup_dir}/${DB_FILE}\" ] && rm -rf ${backup_dir}/DB_${D}_$(date +%Y%m%d --date="${expired_days} days ago")_*.tgz" >> config_backup.txt
  done
}

# Backup database to cloud storage (generic function)
# Usage: db_cloud_backup destination_type bucket_name
db_cloud_backup() {
  local dest_type="$1"
  local bucket_name="$2"
  local upload_cmd
  upload_cmd=$(get_cloud_commands "${dest_type}")
  
  [ -n "${upload_cmd}" ] || return 1
  
  for D in $(get_items "${db_name}"); do
    ./db_bk.sh "${D}"
    
    local DB_GREP DB_FILE remote_path
    DB_GREP="DB_${D}_$(date +%Y%m%d)"
    DB_FILE=$(ls -lrt "${backup_dir}" | grep "${DB_GREP}" | tail -1 | awk '{print $NF}')
    remote_path="/$(date +%F)/${DB_FILE}"
    
    # Upload based on cloud type
    case "${dest_type}" in
      oss)
        ossutil cp -f "${backup_dir}/${DB_FILE}" "oss://${bucket_name}${remote_path}"
        ;;
      cos)
        coscli sync "${backup_dir}/${DB_FILE}" "cos://${bucket_name}${remote_path}"
        ;;
      upyun)
        upx put "${backup_dir}/${DB_FILE}" "${remote_path}"
        ;;
      qiniu)
        qshell rput "${bucket_name}" "${remote_path}" "${backup_dir}/${DB_FILE}"
        ;;
      s3)
        aws s3 sync "${backup_dir}/${DB_FILE}" "s3://${bucket_name}${remote_path}"
        ;;
      dropbox)
        dbxcli put "${backup_dir}/${DB_FILE}" "$(date +%F)/${DB_FILE}"
        ;;
    esac
    
    if [ $? -eq 0 ]; then
      cloud_delete_old "${dest_type}" "${bucket_name}"
      ! has_local_backup && rm -f "${backup_dir}/${DB_FILE}"
    fi
  done
}

# ============================================
# Website Backup Functions
# ============================================

# Backup website to local storage
# Usage: web_local_backup
web_local_backup() {
  for W in $(get_items "${website_name}"); do
    ./website_bk.sh "${W}"
  done
}

# Backup website to remote server
# Usage: web_remote_backup
web_remote_backup() {
  for W in $(get_items "${website_name}"); do
    if [ "$(du -sm "${wwwroot_dir}/${W}" 2>/dev/null | awk '{print $1}')" -lt 2048 ]; then
      ./website_bk.sh "${W}"
      local Web_GREP Web_FILE
      Web_GREP="Web_${W}_$(date +%Y%m%d)"
      Web_FILE=$(ls -lrt "${backup_dir}" | grep "${Web_GREP}" | tail -1 | awk '{print $NF}')
      echo "file:::${backup_dir}/${Web_FILE} ${backup_dir} push" >> config_backup.txt
      echo "com:::[ -e \"${backup_dir}/${Web_FILE}\" ] && rm -rf ${backup_dir}/Web_${W}_$(date +%Y%m%d --date="${expired_days} days ago")_*.tgz" >> config_backup.txt
    else
      echo "file:::${wwwroot_dir}/${W} ${backup_dir} push" >> config_backup.txt
    fi
  done
}

# Create website archive file
# Usage: create_web_archive website_name
create_web_archive() {
  local W="$1"
  
  [ ! -e "${wwwroot_dir}/${W}" ] && { echo "[${wwwroot_dir}/${W}] not exist"; return 1; }
  [ ! -e "${backup_dir}" ] && mkdir -p "${backup_dir}"
  
  local PUSH_FILE="${backup_dir}/Web_${W}_$(date +%Y%m%d_%H).tgz"
  
  if [ ! -e "${PUSH_FILE}" ]; then
    pushd "${wwwroot_dir}" > /dev/null
    tar czf "${PUSH_FILE}" "./${W}"
    popd > /dev/null
  fi
  
  echo "${PUSH_FILE}"
}

# Backup website to cloud storage (generic function)
# Usage: web_cloud_backup destination_type bucket_name
web_cloud_backup() {
  local dest_type="$1"
  local bucket_name="$2"
  
  for W in $(get_items "${website_name}"); do
    local PUSH_FILE
    PUSH_FILE=$(create_web_archive "${W}")
    
    [ -n "${PUSH_FILE}" ] || continue
    
    local remote_path
    remote_path="/$(date +%F)/${PUSH_FILE##*/}"
    
    # Upload based on cloud type
    case "${dest_type}" in
      oss)
        ossutil cp -f "${PUSH_FILE}" "oss://${bucket_name}${remote_path}"
        ;;
      cos)
        coscli sync "${PUSH_FILE}" "cos://${bucket_name}${remote_path}"
        ;;
      upyun)
        upx put "${PUSH_FILE}" "${remote_path}"
        ;;
      qiniu)
        qshell rput "${bucket_name}" "${remote_path}" "${PUSH_FILE}"
        ;;
      s3)
        aws s3 sync "${PUSH_FILE}" "s3://${bucket_name}${remote_path}"
        ;;
      dropbox)
        dbxcli put "${PUSH_FILE}" "$(date +%F)/${PUSH_FILE##*/}"
        ;;
    esac
    
    if [ $? -eq 0 ]; then
      cloud_delete_old "${dest_type}" "${bucket_name}"
      ! has_local_backup && rm -f "${PUSH_FILE}"
    fi
  done
}

# ============================================
# Main Backup Dispatcher
# ============================================

# Run backup based on destination type
# Usage: run_backup destination_type
run_backup() {
  local DEST="$1"
  
  case "${DEST}" in
    local)
      echo "${backup_content}" | grep -owq 'db' && db_local_backup
      echo "${backup_content}" | grep -owq 'web' && web_local_backup
      ;;
    remote)
      echo "com:::[ ! -e \"${backup_dir}\" ] && mkdir -p ${backup_dir}" > config_backup.txt
      echo "${backup_content}" | grep -owq 'db' && db_remote_backup
      echo "${backup_content}" | grep -owq 'web' && web_remote_backup
      ./mabs.sh -c config_backup.txt -T -1 | tee -a mabs.log
      ;;
    oss)
      echo "${backup_content}" | grep -owq 'db' && db_cloud_backup oss "${oss_bucket}"
      echo "${backup_content}" | grep -owq 'web' && web_cloud_backup oss "${oss_bucket}"
      ;;
    cos)
      echo "${backup_content}" | grep -owq 'db' && db_cloud_backup cos "${cos_bucket}"
      echo "${backup_content}" | grep -owq 'web' && web_cloud_backup cos "${cos_bucket}"
      ;;
    upyun)
      echo "${backup_content}" | grep -owq 'db' && db_cloud_backup upyun ""
      echo "${backup_content}" | grep -owq 'web' && web_cloud_backup upyun ""
      ;;
    qiniu)
      echo "${backup_content}" | grep -owq 'db' && db_cloud_backup qiniu "${qiniu_bucket}"
      echo "${backup_content}" | grep -owq 'web' && web_cloud_backup qiniu "${qiniu_bucket}"
      ;;
    s3)
      echo "${backup_content}" | grep -owq 'db' && db_cloud_backup s3 "${s3_bucket}"
      echo "${backup_content}" | grep -owq 'web' && web_cloud_backup s3 "${s3_bucket}"
      ;;
    dropbox)
      echo "${backup_content}" | grep -owq 'db' && db_cloud_backup dropbox ""
      echo "${backup_content}" | grep -owq 'web' && web_cloud_backup dropbox ""
      ;;
  esac
}

# ============================================
# Main Execution
# ============================================

for DEST in $(get_items "${backup_destination}"); do
  run_backup "${DEST}"
done
