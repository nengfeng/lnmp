#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp

Install_fail2ban() {
  pushd ${current_dir}/src > /dev/null
  src_url="https://github.com/fail2ban/fail2ban/archive/refs/tags/${fail2ban_ver}.tar.gz" && Download_src
  tar xzf fail2ban-${fail2ban_ver}.tar.gz
  pushd fail2ban-${fail2ban_ver} > /dev/null
  if command -v python3 > /dev/null 2>&1; then
    python3 setup.py install
  else
    python setup.py install
  fi
  /bin/cp build/fail2ban.service /lib/systemd/system/
  svc_enable fail2ban
  if grep -q "^Port" /etc/ssh/sshd_config; then
    now_ssh_port=$(grep ^Port /etc/ssh/sshd_config | awk '{print $2}' | head -1)
  else
    now_ssh_port=22
  fi
  if ufw status | grep -wq inactive; then
    ufw default allow incoming
    ufw --force enable
  fi
  cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
ignoreip = 127.0.0.1/8
bantime  = 86400
findtime = 600
maxretry = 5
backend = auto
banaction = ufw
action = %(action_mwl)s

[sshd]
enabled = true
filter  = sshd
port    = ${now_ssh_port}
action = %(action_mwl)s
logpath = /var/log/auth.log
bantime  = 86400
findtime = 600
maxretry = 5
EOF
  cat > /etc/logrotate.d/fail2ban << EOF
/var/log/fail2ban.log {
    missingok
    notifempty
    postrotate
      /usr/local/bin/fail2ban-client flushlogs >/dev/null || true
    endscript
}
EOF
  kill -9 $(ps -ef | grep fail2ban | grep -v grep | awk '{print $2}') > /dev/null 2>&1
  svc_start fail2ban
  popd > /dev/null
  if [ -e "/usr/local/bin/fail2ban-server" ]; then
    echo; echo "${CSUCCESS}fail2ban installed successfully! ${CEND}"
  else
    echo; echo "${CFAILURE}fail2ban install failed, Please try again! ${CEND}"
  fi
}

Uninstall_fail2ban() {
  svc_stop fail2ban
  svc_disable fail2ban
  rm -rf /usr/local/bin/fail2ban* /etc/init.d/fail2ban /etc/fail2ban /etc/logrotate.d/fail2ban /var/log/fail2ban.* /var/run/fail2ban /lib/systemd/system/fail2ban.service
  # Clean up Python modules
  rm -rf /usr/local/lib/python*/dist-packages/fail2ban* /usr/local/lib/python*/site-packages/fail2ban* 2>/dev/null
  echo; echo "${CMSG}fail2ban uninstall completed${CEND}";
}
