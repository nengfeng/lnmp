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
  [ -z "$(grep ^Port /etc/ssh/sshd_config)" ] && now_ssh_port=22 || now_ssh_port=$(grep ^Port /etc/ssh/sshd_config | awk '{print $2}' | head -1)
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
  # unban every IP and flush the firewall chains fail2ban created before removing it,
  # otherwise orphan f2b-* chains keep blocking traffic
  if [ -x /usr/local/bin/fail2ban-client ]; then
    fail2ban-client unban --all >/dev/null 2>&1 || true
  fi
  if command -v iptables >/dev/null 2>&1; then
    for c in $(iptables -S 2>/dev/null | awk '{print $2}' | grep -E '^f2b-'); do
      iptables -F "$c" >/dev/null 2>&1 || true
      iptables -X "$c" >/dev/null 2>&1 || true
    done
  fi
  if command -v nft >/dev/null 2>&1; then
    nft list tables 2>/dev/null | awk '/f2b-/{print $2, $3}' | while read -r family name; do
      nft delete table "$family" "$name" >/dev/null 2>&1 || true
    done
  fi
  svc_stop fail2ban
  svc_disable fail2ban
  # Back up (do NOT silently delete) the user's jail.local / config
  if [ -d /etc/fail2ban ]; then
    /bin/mv /etc/fail2ban "/etc/fail2ban_bak_$(date +%Y%m%d%H)" 2>/dev/null || true
  fi
  rm -rf /usr/local/bin/fail2ban* /etc/init.d/fail2ban /etc/logrotate.d/fail2ban /var/log/fail2ban.* /var/run/fail2ban /lib/systemd/system/fail2ban.service
  # Clean up Python modules
  rm -rf /usr/local/lib/python*/dist-packages/fail2ban* /usr/local/lib/python*/site-packages/fail2ban* 2>/dev/null
  echo; echo "${CMSG}fail2ban uninstall completed (config backed up to /etc/fail2ban_bak_*)${CEND}";
}
