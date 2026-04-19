#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp

# Custom profile
cat > /etc/profile.d/lnmp.sh << EOF
HISTSIZE=10000
HISTTIMEFORMAT="%F %T \$(whoami) "

alias l='ls -AFhlt --color=auto'
alias lh='l | head'
alias ll='ls -l --color=auto'
alias ls='ls --color=auto'
alias vi=vim

GREP_OPTIONS="--color=auto"
alias grep='grep --color'
alias egrep='egrep --color'
alias fgrep='fgrep --color'
EOF

sed -i 's@^"syntax on@syntax on@' /etc/vim/vimrc

# PS1
[ -z "$(grep ^PS1 ~/.bashrc)" ] && echo "PS1='\${debian_chroot:+(\$debian_chroot)}\\[\\e[1;32m\\]\\u@\\h\\[\\033[00m\\]:\\[\\033[01;34m\\]\\w\\[\\033[00m\\]\\$ '" >> ~/.bashrc

# history
[ -z "$(grep history-timestamp ~/.bashrc)" ] && echo "PROMPT_COMMAND='{ msg=\$(history 1 | { read x y; echo \$y; });user=\$(whoami); echo \$(date \"+%Y-%m-%d %H:%M:%S\"):\$user:\$(pwd)/:\$msg ---- \$(who am i); } >> /tmp/\$(hostname).\$(whoami).history-timestamp'" >> ~/.bashrc

# /etc/security/limits.conf
[ -e /etc/security/limits.d/*nproc.conf ] && rename nproc.conf nproc.conf_bk /etc/security/limits.d/*nproc.conf
[ -z "$(grep 'session required pam_limits.so' /etc/pam.d/common-session)" ] && echo "session required pam_limits.so" >> /etc/pam.d/common-session
sed -i '/^# End of file/,$d' /etc/security/limits.conf
cat >> /etc/security/limits.conf <<EOF
# End of file
* soft nproc 65535
* hard nproc 65535
* soft nofile 65535
* hard nofile 65535
root soft nproc 65535
root hard nproc 65535
root soft nofile 65535
root hard nofile 65535
EOF

# /etc/hosts
[ "$(hostname -i | awk '{print $1}')" != "127.0.0.1" ] && sed -i "s@127.0.0.1.*localhost@&\n127.0.0.1 $(hostname)@g" /etc/hosts

# Set timezone
rm -rf /etc/localtime
ln -s /usr/share/zoneinfo/${timezone} /etc/localtime

# /etc/sysctl.conf
[ -z "$(grep 'fs.file-max' /etc/sysctl.conf)" ] && cat >> /etc/sysctl.conf << EOF
fs.file-max = 1000000
fs.inotify.max_user_instances = 16384
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_max_tw_buckets = 100000
net.ipv4.route.gc_timeout = 100
net.ipv4.tcp_syn_retries = 1
net.ipv4.tcp_synack_retries = 1
net.core.somaxconn = 32768
net.core.netdev_max_backlog = 32768
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_max_orphans = 32768
EOF
if ! sysctl -p > /dev/null 2>&1; then
  echo "Warning: Failed to apply sysctl settings" >&2
fi

sed -i 's@^ACTIVE_CONSOLES.*@ACTIVE_CONSOLES="/dev/tty[1-2]"@' /etc/default/console-setup
locale-gen en_US.UTF-8
[ -d "/var/lib/locales/supported.d" ] && echo "en_US.UTF-8 UTF-8" > /var/lib/locales/supported.d/local
cat > /etc/default/locale << EOF
LANG=en_US.UTF-8
LANGUAGE=en_US:en
EOF

# ufw
if [[ "${firewall_flag}" == 'y' ]]; then
  ufw allow 22/tcp || echo "Warning: Failed to configure ufw for port 22" >&2
  [ "${ssh_port}" != "22" ] && ufw allow ${ssh_port}/tcp || echo "Warning: Failed to configure ufw for port ${ssh_port}" >&2
  ufw allow 80/tcp || echo "Warning: Failed to configure ufw for port 80" >&2
  ufw allow 443/tcp || echo "Warning: Failed to configure ufw for port 443" >&2
  ufw --force enable || echo "Warning: Failed to enable ufw" >&2
else
  ufw --force disable || echo "Warning: Failed to disable ufw" >&2
fi
svc_restart rsyslog || echo "Warning: Failed to restart rsyslog" >&2
svc_restart ssh || echo "Warning: Failed to restart ssh" >&2

. /etc/profile
. ~/.bashrc
