# LNMP 一键安装脚本

适用于 Debian/Ubuntu 的 LNMP (Linux + Nginx + MySQL/MariaDB + PHP) 一键安装脚本。

## 支持的组件

### Web 服务器
- Nginx / Tengine / OpenResty
- 自动配置 HTTPS (Let's Encrypt / 自签名)
- 支持 TLS 1.2/1.3、HTTP/2、OCSP Stapling、HSTS Preload

### 数据库
- MySQL 8.0 / 8.4
- MariaDB 10.11 / 11.4 / 11.8
- PostgreSQL 16 / 17 / 18

### PHP
- PHP 8.3 / 8.4 / 8.5 (支持多版本共存)
- 14 种 PECL 扩展 (Redis, Memcached, MongoDB, Swoole, Xdebug 等)

### 其他服务
- Redis / Memcached / Pure-FTPd / phpMyAdmin / Node.js
- Fail2ban (安全防护) / Composer / ngx_lua_waf (WAF)

## 快速开始

### 1. 配置安装选项

```bash
vim options.conf
```

主要配置项：
- `nginx_option`: Web 服务器 (1=Nginx, 2=Tengine, 3=OpenResty)
- `db_option`: 数据库 (1=MySQL 8.4, 2=MySQL 8.0, 3-5=MariaDB, 6=PostgreSQL)
- `php_option`: PHP 版本 (1=8.3, 2=8.4, 3=8.5)
- `server_scenario`: 服务器场景 (vps=资源受限, dedicated=独立服务器)
- `MIRROR_BASE_URL`: 下载镜像源 (默认清华镜像)

### 2. 预下载组件（推荐）

```bash
./download_sources.sh --common          # 自动检测 IP 选择镜像
./download_sources.sh --china --common  # 强制国内镜像
./download_sources.sh --all             # 下载所有组件
```

### 3. 执行安装

```bash
./install.sh
```

交互式安装或通过命令行参数指定选项：
```bash
./install.sh --nginx_option 1 --db_option 1 --php_option 2 --dbrootpwd "YourPassword"
```

## 架构设计

### 目录结构

```
├── install.sh          # 主安装脚本
├── uninstall.sh        # 卸载脚本
├── upgrade.sh          # 升级脚本
├── vhost.sh            # 虚拟主机管理 (支持 HTTPS)
├── addons.sh           # 附加组件 (Composer/Fail2ban/WAF)
├── pureftpd_vhost.sh   # FTP 虚拟用户管理
├── reset_db_root_password.sh  # 数据库密码重置
│
├── include/            # 核心模块
│   ├── common.sh       # 通用抽象层 (服务管理/输入函数/镜像检测/日志轮转)
│   ├── ip_detect.sh    # IP 检测 (替代闭源 ois 二进制)
│   ├── ext-common.sh   # PHP 扩展统一管理
│   ├── mysql.sh        # MySQL 统一安装函数
│   ├── mariadb.sh      # MariaDB 统一安装函数
│   ├── php.sh          # PHP 统一安装函数
│   ├── db-common.sh    # 数据库通用函数 (安装/配置/调优)
│   ├── php-common.sh   # PHP 通用函数 (编译/配置/FPM)
│   ├── web-common.sh   # Web 服务器通用函数
│   ├── check_download.sh  # 下载管理 (镜像检测/校验码)
│   └── ...
│
├── config/             # 配置文件模板 (Nginx/PHP/数据库)
├── systemd/            # systemd 服务文件
├── src/                # 下载的源码包
└── DOWNLOAD_SOURCES.txt # 组件下载源文档
```

### 核心抽象层 (common.sh)

统一的服务管理和用户交互函数：

**服务管理** (自动检测 systemd/SysV init):
```bash
svc_start <service>     # 启动服务
svc_stop <service>      # 停止服务
svc_restart <service>   # 重启服务
svc_reload <service>    # 重载配置
svc_enable <service>    # 开机启动
svc_disable <service>   # 取消开机启动
svc_is_active <service> # 检查运行状态
```

**安全输入函数**:
```bash
confirm "提示" var_name [default]           # y/n 确认
select_number "提示" var min max default    # 数字选择
input_string "提示" var_name [default]      # 文本输入
input_password "提示" var default min_len   # 密码输入 (含校验)
check_installed type path name              # 防重复安装检查
```

**镜像检测**:
```bash
init_mirror                    # 自动检测 IP 设置镜像源
get_mirror_url official china  # 获取镜像 URL
```

**日志轮转**:
```bash
setup_nginx_logrotate <logdir>      # Nginx 日志轮转
setup_mysql_logrotate <datadir>     # MySQL 日志轮转
setup_php_fpm_logrotate <phpdir>    # PHP-FPM 日志轮转
```

### IP 检测 (ip_detect.sh)

纯 bash 实现，替代已移除的闭源二进制：

```bash
. ./include/ip_detect.sh
ip_local           # 获取本机 IP
ip_state           # 获取国家代码 (CN/US/SG...)，4级 API fallback
conn_port -h X -p Y  # TCP 端口连通测试
```

### PHP 扩展管理 (ext-common.sh)

声明式扩展注册表，统一安装/卸载逻辑：

```bash
# 安装所有启用的扩展
install_enabled_exts

# 卸载所有启用的扩展
uninstall_enabled_exts
```

## 服务器场景调优

`server_scenario` 参数影响性能配置：

| 参数 | VPS (资源受限) | 独立服务器 |
|------|---------------|-----------|
| **MySQL** | | |
| innodb_buffer_pool | 内存 50% | 内存 70% |
| max_connections | 内存/8 (最大100) | 内存/4 (最大500) |
| flush_log_at_trx_commit | 2 (性能优先) | 1 (ACID 安全) |
| **PHP-FPM** | | |
| pm.max_children | 内存/60 | 内存/30 |
| rlimit_files | 51200 | 102400 |
| **Nginx** | | |
| worker_connections | 51200 | 102400 |
| keepalive_timeout | 60s | 300s |
| open_file_cache | 禁用 | 启用 |

## 下载源配置

### 镜像自动选择 (默认)

脚本自动检测 IP 位置：
- **中国 IP** → `MIRROR_BASE_URL` (清华镜像)
- **其他地区** → 官方源

支持的镜像站 (`options.conf`):
```bash
MIRROR_BASE_URL=https://mirrors.tuna.tsinghua.edu.cn  # 清华 (默认)
MIRROR_BASE_URL=https://mirrors.ustc.edu.cn           # 中科大
MIRROR_BASE_URL=https://mirrors.aliyun.com            # 阿里云
MIRROR_BASE_URL=https://mirrors.xtom.com              # xtom (国际CDN)
```

### 手动指定

```bash
MIRROR_MODE=china ./install.sh      # 强制国内镜像
MIRROR_MODE=official ./install.sh   # 强制官方源
```

### 校验码验证

默认启用 SHA256/PGP/MD5 校验，防止下载文件被篡改。跳过方式：
```bash
VERIFY_CHECKSUM=no ./download_sources.sh nginx
```

## HTTPS 支持

创建虚拟主机时 (`./vhost.sh`)，支持三种模式：

| 模式 | 说明 |
|------|------|
| HTTP Only | 仅 HTTP，无 SSL |
| 自签名证书 | OpenSSL 生成，有效期 100 年 |
| Let's Encrypt | acme.sh 自动申请，支持自动续期 |
| 自定义证书 | 使用已购买的商业证书 (.crt + .key) |

**Let's Encrypt 特性**:
- 支持 RSA (2048/3072/4096/8192) 和 ECC (ec-256/ec-384/ec-521)
- 支持 DNS-01 验证 (通配符证书)，支持 12+ DNS 提供商
- 支持 HTTP-01 验证 (标准域名验证)

**TLS 安全配置**:
- 仅 TLS 1.2 / 1.3
- 现代加密套件 (ECDHE + AES-GCM + CHACHA20)
- OCSP Stapling 启用
- HSTS (含 includeSubDomains + preload)
- HTTP/2 启用

## 安全特性

### 代码安全
- **无 eval 注入风险**: 参数解析使用纯 bash，不使用 `eval set`
- **安全输入函数**: `confirm`/`select_number`/`input_password` 防注入
- **完整日志轮转**: Nginx/MySQL/PHP-FPM 自动轮转，防止磁盘爆满
- **目录权限**: `/data` 目录默认 750，仅 root 可访问

### 下载安全
- 所有下载源使用 HTTPS 加密传输
- 支持 SHA256/PGP/MD5 校验码验证
- IP 自动检测选择最优镜像源

### 数据库安全
- 数据库仅监听本地地址 (127.0.0.1)
- 密码输入禁止 `+` `|` `&` 等危险字符
- VPS 模式 `innodb_flush_log_at_trx_commit=2` (可能丢失 ≤1s 数据)
- 独立服务器模式 `innodb_flush_log_at_trx_commit=1` (完全 ACID)

### PHP 安全
- 禁用危险函数: `exec`, `system`, `shell_exec`, `passthru`, `popen` 等
- 隐藏 PHP 版本 (`expose_php = Off`)
- 文件上传限制: 50MB
- 执行时间限制: 600s

## 更新

```bash
./upgrade.sh script              # 更新脚本本身
./upgrade.sh nginx 1.28.2        # 更新 Nginx
./upgrade.sh php 8.4.10          # 更新 PHP
./upgrade.sh db 8.4.3            # 更新数据库
./upgrade.sh redis 7.4.1         # 更新 Redis
./upgrade.sh --cacert            # 更新 CA 根证书 (建议每 3-6 个月)
```

## 卸载

```bash
./uninstall.sh                   # 交互式卸载
./uninstall.sh --all --quiet     # 静默全部卸载
```

数据目录会重命名为带时间戳的备份，不会直接删除。

## 系统要求

- **操作系统**: Debian 11/12, Ubuntu 20.04/22.04/24.04
- **内存**: 最低 512MB，推荐 1GB+
- **磁盘**: 最低 5GB，推荐 10GB+
- **架构**: x86_64, aarch64

## 常用命令

```bash
# 服务管理
systemctl {start|stop|restart|reload} nginx
systemctl {start|stop|restart|reload} php-fpm
systemctl {start|stop|restart} mysqld
systemctl {start|stop|restart} redis-server

# 虚拟主机
./vhost.sh                    # 添加
./vhost.sh del                # 删除

# 数据库密码重置
./reset_db_root_password.sh

# FTP 用户管理
./pureftpd_vhost.sh

# 附加组件
./addons.sh                   # Composer / Fail2ban / WAF
```

## 配置文件位置

| 组件 | 路径 |
|------|------|
| Nginx | `/usr/local/nginx/conf/nginx.conf` |
| 虚拟主机 | `/usr/local/nginx/conf/vhost/*.conf` |
| SSL 证书 | `/usr/local/nginx/conf/ssl/` |
| PHP | `/usr/local/php/etc/php.ini` |
| PHP-FPM | `/usr/local/php/etc/php-fpm.conf` |
| OPCache | `/usr/local/php/etc/php.d/02-opcache.ini` |
| MySQL/MariaDB | `/etc/my.cnf` |
| Redis | `/usr/local/redis/etc/redis.conf` |
| Pure-FTPd | `/usr/local/pureftpd/etc/pure-ftpd.conf` |

## 项目状态

经过全面安全审计和代码风格重构（2026年3月），本项目已从"能用但坑多"的脚本集，转变为一个高质量的运维工具。安全漏洞、代码 bug 和风格问题已全面修复。

**当前质量评分：A-**

| 维度 | 评级 | 说明 |
|------|------|------|
| 架构设计 | A- | 模块化清晰，统一抽象层，`svc_*` 服务管理 |
| 安全性 | A- | 已修复 eval 注入、curl\|bash、投毒域名等漏洞 |
| 代码风格 | A | 9 类风格问题全部清零（见下表） |
| POSIX 兼容 | A | 所有脚本使用 `#!/bin/bash`，bash 特性正确使用 |
| 测试覆盖 | D | 仅有语法检查，无自动化测试 |
| 文档 | B+ | README/下载源/健康检查均有文档 |

**代码风格修复统计（72 次提交）：**

| 类别 | 修复前 | 修复后 | 说明 |
|------|--------|--------|------|
| 反引号 `` ` `` | ~80 处 | 0 处 | 全部替换为 `$()` |
| `echo -e` | 154 处 | 0 处 | 全部替换为 `printf "%b"` |
| `[ ] ==` | ~350 处 | 0 处 | 全部替换为 `[[ ]]` |
| `[ ] -a/-o` | ~20 处 | 0 处 | 全部替换为 `&&`/`\|\|` |
| 变量未加引号 | ~50 处 | 0 处 | 命令替换全部加引号 |
| HTTP 明文 URL | 10+ 处 | 0 处 | 全部 HTTPS |
| linuxeye.com 引用 | 74 处 | 0 处 | 全部清除 |
| `while` 死循环 | 7 处 | 0 处 | 改为 `while :` |
| `$?` 无意义检查 | 6 处 | 0 处 | 赋值后检查已清除 |

**POSIX 兼容说明：**

所有脚本使用 `#!/bin/bash`，因此 bash 特性（`[[ ]]`、`local`、`read -e`、`=~` 等）是**故意为之**，不是兼容性问题。修复的 POSIX 问题包括：

- `echo -e` → `printf "%b"`（`echo -e` 在 bash 中也不推荐）
- `[ ] ==` → `[[ ]]`（`==` 在 `[ ]` 中是未定义行为）
- `[ ] -a/-o` → `[[ ]] &&/||`（`-a/-o` 已被 POSIX 废弃）
- 反引号 → `$()`（反引号在 POSIX 中有效但可读性差）

**安全修复：**
- eval DNS_PAR 注入漏洞 → 输入验证 + 格式检查
- curl\|bash 管道执行 → 下载后验证再执行
- linuxeye.com 投毒域名引用 → 全部清除
- 403 重定向到外部域名 → `return 403`

**新功能：**
- `--customcert` 自定义证书支持
- `health_check.sh` 安装后健康检查
- `--version` 显示当前组件版本

**未来改进方向：**

1. **测试框架** — 添加自动化测试，至少覆盖安装/升级/卸载的关键路径
2. **函数文档** — 为 `common.sh` 等核心模块补充 API 文档
3. **CI/CD** — 添加 GitHub Actions 自动化检查

## 致谢

本项目最初基于 [linuxeye/lnmp](https://github.com/linuxeye/lnmp) 构建，在此基础上进行了全面的安全审计、架构重构和功能增强。感谢原项目作者 yeho 的初始工作。

感谢 [主机测评](https://www.zhujiceping.com) 提供的修改调试环境。

## License

Apache License 2.0
