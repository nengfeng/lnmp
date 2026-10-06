# VeryNginx 替换 ngx_lua_waf 技术方案

> **文档状态**：v2（评审修订版）
> **基线 commit**：`2db6363`（版本 1.7.5，`version()` 输出 `1.7.5` / `2026-09-19`）
> **上游 VeryNginx**：`COMMIT` = `616becc8a2cbc554166cbf0e03147ba3e43aa745`，HEAD = `d8cbff3`
>
> **v2 修订说明**：v1 草案经逐条核对本仓库代码与上游 `install-lnmp.sh` 后，发现 4 个会导致
> 实施失败或留下损坏状态的缺陷（B1–B4）与 7 处事实性错误（E1–E7），已在本版修正。
> 逐条对照见 [§12 评审结论对照表](#12-评审结论对照表)。
>
> **已确认的前置决策**：`ngx_lua_waf` **确定删除**，不保留兼容别名、不保留降级开关。
> 该项目自 2018 年起无维护、无共享内存、无管理界面，保留双轨只会让 §3.1 的清理面翻倍。
> 回滚手段改为 git 历史 / 发布 tag（见 §9.2），而非「在旧分支保留文件」。

---

## 1. 背景与目标

### 1.1 背景

当前 LNMP 项目使用 `ngx_lua_waf` 作为 WAF 方案，存在以下局限：
- 无管理界面，规则更新需手动编辑 `config.lua`
- 无共享内存，无法做频率限制和会话管理
- 无热更新能力，每次规则变更需 reload nginx
- 项目已停止维护

VeryNginx v2 是更成熟的 Lua-based WAF 方案，具备：
- Vue.js Dashboard 管理界面
- 11 个 `lua_shared_dict` 支持频率限制、IP 信誉、会话管理
- API 热更新规则，无需 reload
- 完整的升级路径（带 commit pin）
- 可选的 Firewall Helper（Go，nftables 内核级 IP 封禁）

### 1.2 目标

1. 用 VeryNginx 完全替换 ngx_lua_waf（删除旧实现，不留双轨）
2. 保持 LNMP 现有安装/升级/卸载流程的完整性
3. 确保 vhost.sh 创建新站点时 WAF 自动生效（上游明确要求）
4. 提供平滑的迁移路径（已安装 ngx_lua_waf 的用户可一步升级）
5. 卸载 / 升级路径不得留下会让 `nginx -t` 失败的残留

## 2. 上游 VeryNginx 最新状态（2026-09-27 同步）

### 2.1 上游 commit（v2 分支）

已与本地 `/root/VeryNginx` 的 `git log` 逐条核对一致。

| Commit | 说明 | 对方案的影响 |
|--------|------|-------------|
| `d8cbff3` | fix(test): inject config fake per-test in statistics phase0 spec | 无（测试相关） |
| `d970b03` | fix(test): adapt statistics spec to per-host v2 persistence | 无（测试相关） |
| `87d9764` | fix(test): correct normalize_host expectations and isolate tmp dir | 无（测试相关） |
| `1291aa2` | feat(stats): per-host request statistics + dashboard host filter | 无（统计功能，与 WAF 集成无关） |
| `67c7d7a` | docs(install): document LNMP integration and per-vhost WAF enablement | **关键**：明确了 vhost 集成方式 |

> 上游 `install-lnmp.sh` 会把 `git rev-parse HEAD` 写入 `${VN_DIR}/COMMIT`、把
> `git describe` 写入 `${VN_DIR}/VERSION`（`install-lnmp.sh:198-212`）。**这两份元数据是
> LNMP 侧判断「装的是哪个版本」的唯一依据**，卸载时随 `configs/` 一起保留（见 §5.2.5）。

### 2.2 上游对 LNMP 集成的明确要求

来自 `docs/INSTALL_zh.md` 第 292-310 行：

> **后续新增的 vhost 自动受保护**。VeryNginx 安装之后，正常用 LNMP 添加站点即可——`lnmp vhost add` 会检测到 VeryNginx，自动把 WAF 处理器写进新生成的 vhost。
>
> **安装 VeryNginx 之前已创建的 vhost 不会自动补**，需要手动在它的 `server {}` 块里加三行处理器（不要 include 完整的 `in_server_block.conf`——它自带的 `location /` 会与 vhost 自己的 `location /` 冲突）。

### 2.3 上游 `install-lnmp.sh` 的 `show_summary()` 输出

```
To enable WAF for a site:
  Vhosts added through LNMP are protected automatically:
    lnmp vhost add   # detects VeryNginx and injects the WAF handlers
  A vhost created BEFORE this install needs the three *by_lua_file
  lines from in_server_block.conf added to its server {} block
  (skip its 'location /', which collides with the vhost's own):
    rewrite_by_lua_file ${VN_DIR}/on_rewrite.lua;
    access_by_lua_file  ${VN_DIR}/on_access.lua;
    log_by_lua_file     ${VN_DIR}/on_log.lua;
```

### 2.4 关键设计决策（基于上游要求）

| 决策点 | 上游要求 | 方案应对 |
|--------|----------|----------|
| vhost.sh 自动注入 | **必须保留**，新 vhost 自动受保护 | 保留并改进注入逻辑（§5.2.3） |
| 注入内容 | 三行 `*by_lua_file` + 两个 location 块 | 与当前 vhost.sh 逻辑一致 |
| 检测方式 | 检测 VeryNginx 是否安装 | `verynginx_is_installed()`，**前缀无关**（见 B4/E4） |
| 已有 vhost | 不自动补，用户手动添加 | 安装时提示用户（§6.3） |

## 3. 现状分析

### 3.1 当前 ngx_lua_waf 集成点（行号已按 `2db6363` 核对，全部准确）

| 文件 | 行号 | 功能 |
|------|------|------|
| `addons.sh` | 38, 52, 76-77, 113, 141-148, 179-186 | 入口、菜单、CLI 参数 |
| `include/ngx_lua_waf.sh` | 1-143 | 安装/卸载/启用/禁用逻辑 |
| `vhost.sh` | 988-1039 | 创建 vhost 时注入 VeryNginx（**注意：这段是 VeryNginx 注入，与 ngx_lua_waf 无关，删除旧文件时不要动**） |
| `tools/lint/static_checks.sh` | 18, 275 | 排除 VeryNginx 目录的 lint |
| `CHANGELOG.md` | 275 | 历史记录 |
| `DOWNLOAD_SOURCES.txt` | 151 | 下载源文档 |
| `README.md` | 25 | 功能列表 |

### 3.2 VeryNginx 现有集成方式

VeryNginx 自带 `install-lnmp.sh`（**1751 行**，非 v1 草案所写的「约 1200 行」）。
`main()`（`:1688`）的执行序列如下，**LNMP 的封装必须完整覆盖这张表**：

| 顺序 | 上游动作 | 位置 | 副作用 | LNMP 归属 |
|------|----------|------|--------|-----------|
| 1 | `require_root` | `:1702` | — | — |
| 2 | `detect_web_server` | `:1703` | 识别 nginx/tengine/openresty | 覆盖（§5.1.1 预检） |
| 3 | **python3 硬性检查，缺失即 `die`** | `:1706-1711` | 无（改动文件前就退出） | **必须前置处理（B2）** |
| 4 | `check_lua_resty_deps` | `:1712`, `:1194` | 仅 warn | 已满足（§7.6） |
| 5 | `check_geoip_deps` | `:1713`, `:1258` | 仅 warn | 已满足（§7.6） |
| 6 | `install_files`（含 `setup_admin_password`） | `:1717`, `:167` | 写 `/opt/verynginx`，**交互读密码** | **必须处理（E7）** |
| 7 | `confirm "Patch nginx.conf?"` 默认 y | `:1719` | 改写 `nginx.conf` | 接受 |
| 8 | `confirm "Install Firewall Helper?"` **默认 y** | `:1734` | 装 Go 二进制 + systemd 单元 | **必须处理（B3）** |
| 9 | `show_summary` | `:1745` | — | — |

上游无任何命令行 flag 可跳过第 8 步；可用环境变量仅 `VN_PREFIX`（`:19`）与
`VN_PBKDF2_ITER`（`:67`）。`install.py` 只接受 `--prefix`（`:368`）。

### 3.3 关键冲突点

| 冲突 | 说明 | 结论 |
|------|------|------|
| **nginx.conf 注入重叠** | `install-lnmp.sh` 注入到 `nginx.conf:90` 的默认 server 块，`vhost.sh` 注入到 `conf/vhost/<domain>.conf`。两者层级不同 | 不冲突 |
| **lua 依赖重复** | `ngx_lua_waf.sh` 装 LuaJIT/lua-cjson，`install_web_server` 也装 | 替换后不再重复 |
| **路径不一致** | ngx_lua_waf 用 `${web_install_dir}/conf/waf/`，VeryNginx 用 `VN_PREFIX`（默认 `/opt/verynginx`，**可被环境变量覆盖**） | 见 E4 |
| ~~升级路径~~ | ~~v1 草案称「`upgrade_web.sh` 重新生成 nginx.conf，可能丢失注入」~~ | **该说法不成立，见 E1** |

### 3.4 E1 更正：Nginx 升级不会覆盖 nginx.conf

v1 草案把「Nginx 升级后 VeryNginx 注入丢失」列为主要风险并据此设计 §5.2.6。实测本仓库
`include/upgrade_web.sh` 对三种 web server **只替换二进制**，不碰 `nginx.conf`：

| web server | 升级动作 | 对 conf 的唯一操作 |
|------------|----------|--------------------|
| nginx | `mv sbin/nginx → sbin/nginx.bak$ts` + `cp objs/nginx sbin/nginx`（`:269-273`） | `sed -i 's/^#brotli/brotli/'`（`:279`） |
| tengine | 同上（`:169`） | `sed -i 's/^#brotli/brotli/'`（`:474`） |
| openresty | 同上（`:94-98`） | `sed -i 's/^#brotli/brotli/'`（`:590`） |

**因此 §5.2.6 改为「升级后校验」而非「提示重装」**，§9.1 相应风险行删除。
真正需要关注的升级交互只有一条：`compile_check` 会执行 `./objs/nginx -t`
（nginx `:264` / tengine `:164` / openresty `:90`），该 `-t` 现在会**一并校验
VeryNginx 注入的指令**。这是好事（等于免费获得回归检查），但必须写进测试注意事项，
因为它意味着「VeryNginx 装坏了一个没被测到的配置」会从「升级成功」变成「升级失败」。

## 4. 目标架构

### 4.1 组件关系图

```
┌─────────────────────────────────────────────────────────────┐
│                        LNMP 项目                             │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐     │
│  │ install.sh  │    │ upgrade.sh  │    │ uninstall.sh│     │
│  └──────┬──────┘    └──────┬──────┘    └──────┬──────┘     │
│         │                  │                  │             │
│         ▼                  ▼                  ▼             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              include/web-common.sh                    │   │
│  │  (install_web_server: nginx + lua-nginx-module      │   │
│  │   + lua-resty-core + lua-resty-lrucache)             │   │
│  │   —— 无需改动，Lua 依赖已是无条件安装                 │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐     │
│  │  vhost.sh   │    │  addons.sh   │    │  backup.sh  │     │
│  └──────┬──────┘    └──────┬──────┘    └──────┬──────┘     │
│         │                  │                   │            │
│         │                  ▼                   │            │
│         │         ┌────────────────────┐        │            │
│         │         │ include/verynginx.sh│        │            │
│         │         │ (安装/卸载/检测封装) │        │            │
│         │         └──────────┬─────────┘        │            │
│         │                    │                  │            │
│         │                    ▼                  ▼            │
│         │         ┌────────────────────┐  ┌──────────────┐   │
│         │         │verynginx_tool.py   │  │定期备份       │   │
│         │         │ cleanup / seed-admin│ │ waf-rules.json│  │
│         │         └──────────┬─────────┘  └──────────────┘   │
│         ▼                    ▼                               │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              VeryNginx (外部项目)                     │   │
│  │  ${VN_PREFIX}  默认 /opt/verynginx                    │   │
│  │  ├── configs/          (config.json, waf-rules.json)  │   │
│  │  ├── dashboard/        (Vue.js SPA)                  │   │
│  │  ├── nginx_conf/       (in_{external,http,server}_   │   │
│  │  │                      block.conf)                  │   │
│  │  ├── on_rewrite.lua / on_access.lua / on_log.lua     │   │
│  │  ├── VERSION, COMMIT   (上游写入，备份/回滚依据)       │   │
│  │  └── tools/upgrade.sh  (上游自带，VeryNginx 自身升级)  │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  可选组件（默认不装，见 B3）：                               │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ /usr/local/bin/firewall-helper                       │   │
│  │ /etc/systemd/system/firewall-helper.{service,socket} │   │
│  │ /run/verynginx/  (socket 目录)                        │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 职责划分

| 组件 | 职责 |
|------|------|
| `include/web-common.sh` | **无需改动**。已无条件编译 lua-nginx-module + 安装 lua-resty-core/lrucache（`:183-222`） |
| `include/verynginx.sh` | 封装安装/卸载/状态检测/路径推断/firewall-helper 对账 |
| `include/verynginx_tool.py` | nginx.conf 结构化清理 + admin 密码预置（B2/B4/E7 的落地手段） |
| `addons.sh --verynginx` | 入口。**必须补 `. ./include/check_dir.sh`（B1）** |
| `vhost.sh` | 创建 vhost 时检测 VeryNginx 是否启用，自动注入 WAF 处理器 |
| `upgrade.sh` | 升级 web server 后**校验** VeryNginx 仍可用（不再提示重装，见 E1） |
| `uninstall.sh` | 走 `uninstall_verynginx`：先把 `configs/` 改名保留，再清 nginx.conf 注入与 firewall-helper |
| `backup.sh` | 定期备份 `configs/{waf-rules,config}.json` + `VERSION`/`COMMIT` 到 `${backup_dir}` |
| `health_check.sh` | VeryNginx 状态检查（本期纳入范围，见 §5.2.11） |

## 5. 详细改动方案

### 5.1 新增文件

#### 5.1.1 `include/verynginx.sh`

封装 VeryNginx 的安装/卸载/状态检测逻辑。**v2 相对 v1 的关键修正**：
`web_install_dir` 依赖已显式化（B1）、python3 前置（B2）、firewall-helper 对账（B3）、
`verynginx_is_installed` 前缀无关（E4）、非交互 admin 预置（E7）。

```bash
#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Description: VeryNginx WAF integration for LNMP
#
# 本文件被 addons.sh / vhost.sh / uninstall.sh / upgrade.sh source，
# 依赖调用方已提供：
#   - current_dir          （各入口脚本第 19-26 行均已设置）
#   - web_install_dir      （来自 include/check_dir.sh —— 见下方 B1 说明）
#   - ${CMSG}/${CEND}/${CWARNING}/${CFAILURE}/${CSUCCESS}（include/color.sh）
#   - svc_reload 等        （include/common.sh）
#   - CEND 等颜色变量由各入口 source include/color.sh 提供

# VeryNginx 安装前缀。与上游 install-lnmp.sh:19 的
#   VN_PREFIX="${VN_PREFIX:-/opt/verynginx}"
# 保持一致：用户在调用前 export VN_PREFIX 可改变实际落盘位置。
verynginx_install_dir="${verynginx_install_dir:-${VN_PREFIX:-/opt/verynginx}}"

# B1 说明（必须保留）：
#   web_install_dir 由 include/check_dir.sh:10-12 赋值，该文件在
#   vhost.sh:25 / uninstall.sh:27 / upgrade.sh:28 / install.sh:35 均被 source，
#   但 addons.sh 原本没有 —— 那是 v1 草案里所有检测函数在 addons 入口下退化为
#   /conf/nginx.conf 的根因。§5.2.1 已要求 addons.sh 补上该 source。
#   这里再加一层兜底：万一调用方漏 source，就地推导一次而不是静默用错路径。
_verynginx_resolve_web_dir() {
  if [ -n "${web_install_dir}" ]; then
    return 0
  fi
  if [ -e "${nginx_install_dir}/sbin/nginx" ]; then
    web_install_dir="${nginx_install_dir}"
  elif [ -e "${tengine_install_dir}/sbin/nginx" ]; then
    web_install_dir="${tengine_install_dir}"
  elif [ -e "${openresty_install_dir}/nginx/sbin/nginx" ]; then
    web_install_dir="${openresty_install_dir}/nginx"
  else
    return 1
  fi
}

# 检测 VeryNginx 是否已安装（**前缀无关**，修正 E4）
#
# 不能只查 ${verynginx_install_dir}：上游 VN_PREFIX 可被环境变量覆盖，
# 装到 /data/vn2 的用户在默认路径下会被误判为「未安装」，导致
#   - install_verynginx 覆盖式重跑（rsync 保留 configs，但会重写 nginx.conf）
#   - uninstall_verynginx 直接 return 0，整棵树留在磁盘上
# 因此双通道：先看配置前缀，再从 nginx.conf 的实际注入路径反推。
# Usage: verynginx_is_installed
# Returns: 0 if installed, 1 otherwise
verynginx_is_installed() {
  if _verynginx_looks_installed "${verynginx_install_dir}"; then
    return 0
  fi
  local d
  d=$(_verynginx_infer_dir) || return 1
  [ "$d" = "${verynginx_install_dir}" ] && return 1
  _verynginx_looks_installed "$d"
}

_verynginx_looks_installed() {
  [ -f "$1/on_access.lua" ] && [ -f "$1/configs/config.json" ]
}

# 从 nginx.conf 反推 VeryNginx 实际落盘目录。
# install-lnmp.sh 的 patch_nginx_conf 有两种注入形态：
#   模式 A（默认，replace_server_block）: rewrite_by_lua_file <DIR>/on_rewrite.lua;
#   模式 B（用户手动 include）          : include <DIR>/nginx_conf/in_http_block.conf;
# 两种都要认，否则手动 include 的用户会被当成未安装。
# Usage: _verynginx_infer_dir
_verynginx_infer_dir() {
  _verynginx_resolve_web_dir || return 1
  local nginx_conf="${web_install_dir}/conf/nginx.conf"
  [ -f "${nginx_conf}" ] || return 1
  local inferred
  # 模式 A
  inferred=$(grep -oP 'rewrite_by_lua_file\s+\K/[^;]*(?=/on_rewrite\.lua)' "${nginx_conf}" 2>/dev/null | head -1)
  # 模式 B
  if [ -z "${inferred}" ]; then
    inferred=$(grep -oP 'include\s+\K/[^;]*(?=/nginx_conf/in_)' "${nginx_conf}" 2>/dev/null | head -1)
  fi
  [ -n "${inferred}" ] || return 1
  printf '%s\n' "${inferred}"
}

# 检测 VeryNginx 是否已注入 nginx.conf 的 http 块（shared dict / lua_package_path）。
# 不要检测 rewrite_by_lua_file：那是 install-lnmp.sh 对默认 server 块的注入，
# 而 vhost 的钩子注入在 conf/vhost/<domain>.conf，不在 nginx.conf —— 用 server
# 钩子判断会把「已安装且对 vhost 生效」误判为未启用。
# 用 11 个 dict 里的任意一个做锚点，全部枚举以免上游增删 dict 时失效。
# Usage: verynginx_is_enabled
# Returns: 0 if enabled, 1 otherwise
verynginx_is_enabled() {
  _verynginx_resolve_web_dir || return 1
  local nginx_conf="${web_install_dir}/conf/nginx.conf"
  [ -f "${nginx_conf}" ] || return 1
  grep -Eq 'lua_shared_dict[[:space:]]+(vn_config|vn_locks|vn_rate_limit|vn_session|statistics|metrics|metrics_labeled|healthcheck|dns_cache|frequency_limit|ip_reputation)[[:space:]]' "${nginx_conf}"
}

# 前置依赖检查：python3（上游硬依赖）+ lua-nginx-module
# Usage: verynginx_check_prereqs
# Returns: 0 if ok, 1 otherwise
verynginx_check_prereqs() {
  local rc=0

  # B2：上游 install-lnmp.sh:1706-1711 在 main() 里、动手改任何文件之前就
  # 因缺 python3 而 die。python3 负责 replace_server_block（nginx.conf
  # server 块注入）与 PBKDF2 密码哈希，没有降级路径。v1 草案只把 python3
  # 当成「卸载时的清理问题」，风险表写错方向。
  if ! command -v python3 >/dev/null 2>&1; then
    echo "${CWARNING}python3 is required by VeryNginx (config patching + password hashing).${CEND}"
    # os_type 由 include/check_os.sh 设置（Family=debian/ubuntu）
    # vhost.sh / uninstall.sh / upgrade.sh / install.sh / addons.sh 均已 source
    if [ "${Family}" = "debian" ] || [ "${Family}" = "ubuntu" ]; then
      echo "${CMSG}Installing python3 ...${CEND}"
      apt-get update -qq
      apt-get install -y python3 || { echo "${CFAILURE}Failed to install python3${CEND}"; return 1; }
    else
      echo "${CFAILURE}Please install python3 first: apt-get install -y python3${CEND}"
      return 1
    fi
  fi

  _verynginx_resolve_web_dir || {
    echo "${CFAILURE}No web server found. Install Nginx/Tengine/OpenResty first.${CEND}"
    return 1
  }
  [ -x "${web_install_dir}/sbin/nginx" ] || {
    echo "${CFAILURE}Nginx is not installed at ${web_install_dir}${CEND}"
    return 1
  }

  # OpenResty 自带 Lua（编译参数不含 lua-nginx-module 字样），须先跳过，
  # 否则会被误判为「未编译 Lua」。
  if [ -x "${openresty_install_dir}/nginx/sbin/nginx" ] && [ "${web_install_dir}" = "${openresty_install_dir}/nginx" ]; then
    : # OpenResty has built-in Lua support
  elif ! "${web_install_dir}/sbin/nginx" -V 2>&1 | grep -Eq 'lua-nginx-module|ngx_http_lua_module'; then
    echo "${CFAILURE}Nginx was not compiled with lua-nginx-module!${CEND}"
    echo "${CWARNING}Run ./upgrade.sh --nginx to rebuild it with the Lua module.${CEND}"
    return 1
  fi

  return $rc
}

# 安装 VeryNginx
# Usage: install_verynginx
install_verynginx() {
  # 1. 前置检查（python3 + web server + lua 模块）
  verynginx_check_prereqs || return 1

  if verynginx_is_installed; then
    echo "${CWARNING}VeryNginx is already installed at $(_verynginx_infer_dir 2>/dev/null || echo "${verynginx_install_dir}")!${CEND}"
    echo "${CWARNING}Use ${CEND}${CMSG}/opt/verynginx/tools/upgrade.sh${CEND}${CWARNING} to upgrade VeryNginx itself.${CEND}"
    return 1
  fi

  # 2. 清理旧的 ngx_lua_waf 残留（迁移路径：直接安装即可，无需先手动卸载）
  _verynginx_remove_legacy_lua_waf

  # 3. 定位 VeryNginx 源码目录
  local vn_src_dir=""
  if [ -d "${current_dir}/VeryNginx" ]; then
    vn_src_dir="${current_dir}/VeryNginx"
  elif [ -d "/opt/VeryNginx" ]; then
    vn_src_dir="/opt/VeryNginx"
  elif [ -d "/root/VeryNginx" ]; then
    vn_src_dir="/root/VeryNginx"
  else
    echo "${CFAILURE}VeryNginx source not found!${CEND}"
    echo "${CWARNING}git clone https://github.com/nengfeng/VeryNginx ${current_dir}/VeryNginx${CEND}"
    echo "${CWARNING}(建议 checkout 到 ${CEND}${CMSG}616becc8a2cbc554166cbf0e03147ba3e43aa745${CEND}${CWARNING} 这个已验证的 pin)${CEND}"
    return 1
  fi
  [ -f "${vn_src_dir}/install-lnmp.sh" ] || {
    echo "${CFAILURE}VeryNginx install-lnmp.sh not found in ${vn_src_dir}${CEND}"
    return 1
  }

  # 4. 备份现有 nginx.conf（上游也会备份 .bak.N，但那是它自己的目录约定）
  local nginx_conf="${web_install_dir}/conf/nginx.conf"
  [ -f "${nginx_conf}" ] && cp -a "${nginx_conf}" "${nginx_conf}.lnmp-pre-verynginx.$(date +%Y%m%d%H%M%S)"

  # 5. E7：非交互场景预置 admin 密码，避免上游回落到随机密码
  _verynginx_seed_admin_if_needed "${vn_src_dir}"

  # 6. 调用上游安装脚本
  #    交互场景：stdin 继承，用户自然回答两个 confirm。
  #    非交互场景：stdin 接 /dev/null，confirm() 回落到默认值（patch=y）。
  if [ -t 0 ]; then
    bash "${vn_src_dir}/install-lnmp.sh"
  else
    bash "${vn_src_dir}/install-lnmp.sh" </dev/null
  fi
  local rc=$?
  if [ ${rc} -ne 0 ]; then
    echo "${CFAILURE}VeryNginx install-lnmp.sh failed (exit ${rc}).${CEND}"
    echo "${CWARNING}nginx.conf backup kept at ${nginx_conf}.lnmp-pre-verynginx.*${CEND}"
    return 1
  fi

  # 7. B3：firewall-helper 对账。上游第 8 步的 confirm 默认 y，非交互下必然
  #    装上 Go 二进制 + 两个 systemd 单元。LNMP 默认不装，因此这里显式对账。
  _verynginx_reconcile_firewall_helper

  # 8. 验证安装
  if verynginx_is_installed && verynginx_is_enabled; then
    echo "${CSUCCESS}VeryNginx installed and enabled successfully!${CEND}"
    _verynginx_print_summary
  else
    echo "${CFAILURE}VeryNginx installation verification failed!${CEND}"
    echo "${CWARNING}Check: ${nginx_conf} for lua_shared_dict / *_by_lua_file injections${CEND}"
    return 1
  fi
}

# E7：非交互 + 显式提供密码时，预置 configs/config.json 的 password_hash。
#
# 上游 setup_admin_password（:296-334）用 `read -rs` 且**没有 closed-stdin 保护**：
# 非交互下 read 失败 → password 为空 → 走「leave empty for random」分支，
# 自动生成 12 位随机密码打进日志。CI/自动化拿不到这个密码。
#
# 落地原理（依赖 install_files 内部的执行顺序）：
#   :188-225  rsync/cp 部署文件，--exclude "configs/config.json"  → 预置文件不会被覆盖
#   :228-235  if [ ! -f config.json ] → 已存在则 "keeping it"
#   :251      setup_admin_password → python3 检出 password_hash 非空 → 跳过 prompt
# 因此只要在调用上游**之前**建好 configs/config.json 即可，无需改动上游。
_verynginx_seed_admin_if_needed() {
  local vn_src_dir="$1"

  # 交互式：让上游自己提示用户输入，体验最好
  [ -t 0 ] && return 0
  # 密码只从环境变量读，不走 argv —— argv 会被 ps 看到
  [ -n "${VN_ADMIN_PASSWORD}" ] || {
    echo "${CWARNING}Non-interactive install without VN_ADMIN_PASSWORD.${CEND}"
    echo "${CWARNING}VeryNginx will auto-generate a random admin password; it is printed in the output above.${CEND}"
    return 0
  }

  local cfg_dir="${verynginx_install_dir}/configs"
  mkdir -p "${cfg_dir}" || return 1
  if [ ! -f "${cfg_dir}/config.json" ]; then
    cp "${vn_src_dir}/verynginx/configs/config.default.json" "${cfg_dir}/config.json" || return 1
  fi
  if VN_ADMIN_PASSWORD="${VN_ADMIN_PASSWORD}" VN_CONFIG="${cfg_dir}/config.json" \
     python3 "${current_dir}/include/verynginx_tool.py" seed-admin; then
    echo "${CMSG}Admin password pre-set from VN_ADMIN_PASSWORD.${CEND}"
  else
    echo "${CWARNING}Failed to pre-set admin password; falling back to upstream random password.${CEND}"
  fi
}

# 清理旧 ngx_lua_waf 残留。集成点与 include/ngx_lua_waf.sh 的 disable_lua_waf() 一致：
#   nginx.conf 里的 `include waf.conf;` + ${web_install_dir}/conf/{waf,waf.conf}
_verynginx_remove_legacy_lua_waf() {
  _verynginx_resolve_web_dir || return 0
  local nginx_conf="${web_install_dir}/conf/nginx.conf"
  if [ -f "${nginx_conf}" ] && grep -q 'include waf.conf;' "${nginx_conf}"; then
    echo "${CMSG}Detected legacy ngx_lua_waf, removing it...${CEND}"
    sed -i '/include waf.conf;/d' "${nginx_conf}"
    rm -rf "${web_install_dir}/conf/waf" "${web_install_dir}/conf/waf.conf"
    echo "${CMSG}Legacy ngx_lua_waf removed.${CEND}"
  fi
}

# B3：firewall-helper 对账
#
# 上游 main() 第 8 步：confirm "Install Firewall Helper for kernel IP blocking?" 默认 y。
# 上游没有任何 flag 可以跳过，非交互下 confirm() 因 stdin 关闭回落到默认值 → 必装。
# 装出来的东西在 LNMP 的安装目录之外：
#   /usr/local/bin/firewall-helper                    (:1420)
#   /run/verynginx/                                    (:1422)
#   /etc/systemd/system/firewall-helper.service        (:1613)
#   /etc/systemd/system/firewall-helper.socket         (:1593) + systemctl enable (:1642)
# 而 v1 草案的 uninstall_verynginx 只有 rm -rf ${verynginx_install_dir} → 全部漏掉。
#
# 策略：LNMP 默认**不装**（内核级封禁是需要用户明确决策的高影响操作，且依赖 nftables
# 与 Go 工具链）。安装后无条件对账移除；用户想要就显式 opt-in。
# 环境变量 VN_FIREWALL_HELPER=keep 可保留（并打印如何卸载）。
_verynginx_reconcile_firewall_helper() {
  if [ "${VN_FIREWALL_HELPER}" = "keep" ]; then
    if _verynginx_firewall_helper_installed; then
      echo "${CMSG}Firewall Helper kept (VN_FIREWALL_HELPER=keep).${CEND}"
      echo "${CWARNING}To remove it later: ${CEND}${CMSG}rm -f /usr/local/bin/firewall-helper /etc/systemd/system/firewall-helper.{service,socket} && systemctl daemon-reload${CEND}"
    fi
    return 0
  fi
  if _verynginx_firewall_helper_installed; then
    echo "${CMSG}Removing Firewall Helper (not part of the default LNMP install)...${CEND}"
    _verynginx_remove_firewall_helper
  fi
}

_verynginx_firewall_helper_installed() {
  [ -f /usr/local/bin/firewall-helper ] || \
  [ -f /etc/systemd/system/firewall-helper.service ] || \
  [ -f /etc/systemd/system/firewall-helper.socket ]
}

# 完整移除 firewall-helper（含 systemd 单元与 enable 状态）
_verynginx_remove_firewall_helper() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop firewall-helper.socket 2>/dev/null || true
    systemctl stop firewall-helper.service 2>/dev/null || true
    systemctl disable firewall-helper.socket 2>/dev/null || true
    rm -f /etc/systemd/system/firewall-helper.service /etc/systemd/system/firewall-helper.socket
    systemctl daemon-reload 2>/dev/null || true
    systemctl reset-failed firewall-helper.service 2>/dev/null || true
  fi
  rm -f /usr/local/bin/firewall-helper
  rm -rf /run/verynginx
  echo "${CSUCCESS}Firewall Helper removed.${CEND}"
}

# 卸载 VeryNginx
# Usage: uninstall_verynginx
uninstall_verynginx() {
  if ! verynginx_is_installed; then
    echo "${CWARNING}VeryNginx is not installed!${CEND}"
    return 0
  fi

  local vn_dir
  vn_dir=$(_verynginx_infer_dir 2>/dev/null || echo "${verynginx_install_dir}")

  # 1. 保留 WAF 规则（数据目录改名保留，不删除）
  _verynginx_keep_configs "${vn_dir}"

  # 2. 从 nginx.conf 移除注入（内部已做 Python → sed 降级）
  disable_verynginx_in_nginx_conf

  # 3. 删除安装目录（configs 已在第 1 步移出，不会被连带删除）
  rm -rf "${vn_dir}"

  # 4. firewall-helper 对账（B3：不能只删 ${vn_dir}）
  _verynginx_reconcile_firewall_helper

  # 5. reload nginx —— 若配置已被改坏，这一步会失败并留下现场
  if ! svc_reload nginx; then
    echo "${CFAILURE}nginx reload failed after VeryNginx removal!${CEND}"
    echo "${CWARNING}Run ${CEND}${CMSG}${web_install_dir}/sbin/nginx -t${CEND}${CWARNING} to inspect; backups: ${web_install_dir}/conf/nginx.conf.bak.*${CEND}"
    return 1
  fi

  echo "${CSUCCESS}VeryNginx uninstalled successfully!${CEND}"
}

# 卸载前保留 WAF 规则：目录改名 + 时间戳，不删除。
#
# 沿用 uninstall.sh 的数据目录惯例（uninstall.sh:231-234）：
#   /data/wwwroot  -> /data/wwwroot_$(date +%Y%m%d%H)
#   /data/mysql    -> /data/mysql_$(date +%Y%m%d%H)
# 即「程序目录 rm -rf，数据目录改名保留」。VeryNginx 里 configs/ 就是数据。
#
# 关键点：目标目录必须在 ${vn_dir} **之外**。若就地改名成
# ${vn_dir}/configs_bak_<ts>，紧随其后的 rm -rf "${vn_dir}" 会把它一起删掉，
# 备份等于没做。因此改名为 ${vn_dir} 的兄弟目录。
#
# VERSION / COMMIT 一并移过去：它们记录了装的是哪个 VeryNginx 版本
# （上游写入，install-lnmp.sh:198-212），是日后重装/回滚的唯一依据。
# Usage: _verynginx_keep_configs <vn_dir>
_verynginx_keep_configs() {
  local vn_dir="$1"
  [ -d "${vn_dir}/configs" ] || return 0

  local move_configs="y"
  # quiet_flag 由 uninstall.sh 的 --yes 参数设置（uninstall.sh:68-69）
  if [ "${quiet_flag}" != 'y' ] && [ -t 0 ]; then
    read -e -p "Move ${vn_dir}/configs to ${vn_dir}_configs_bak? (y/n): " move_configs
  fi

  local keep_dir
  if [ "${move_configs}" = 'y' ]; then
    keep_dir="${vn_dir}_configs_bak_$(date +%Y%m%d%H)"
  else
    # 回答 n 也不能让规则被 rm -rf 带走，改用不带时间戳的兄弟目录
    keep_dir="${vn_dir}_configs"
  fi

  /bin/mv "${vn_dir}/configs" "${keep_dir}" || {
    echo "${CFAILURE}Failed to preserve ${vn_dir}/configs — aborting removal${CEND}"
    echo "${CWARNING}Nothing was deleted. Fix the permissions or move it manually, then retry.${CEND}"
    return 1
  }
  for f in VERSION COMMIT; do
    [ -f "${vn_dir}/${f}" ] && /bin/mv "${vn_dir}/${f}" "${keep_dir}/" 2>/dev/null
  done
  echo "${CMSG}VeryNginx rules preserved: ${keep_dir}${CEND}"
  echo "${CWARNING}Delete ${keep_dir} manually once you no longer need the rules.${CEND}"
}

# 从 nginx.conf 移除 VeryNginx 注入
# Usage: disable_verynginx_in_nginx_conf
disable_verynginx_in_nginx_conf() {
  _verynginx_resolve_web_dir || return 0
  local nginx_conf="${web_install_dir}/conf/nginx.conf"
  [ -f "${nginx_conf}" ] || return 0

  # 结构化清理（更可靠）：除了指令本身，还会清掉上游的状态/备份残留（E6）
  if command -v python3 >/dev/null 2>&1 && [ -f "${current_dir}/include/verynginx_tool.py" ]; then
    python3 "${current_dir}/include/verynginx_tool.py" cleanup-nginx-conf "${nginx_conf}" || return 1
  else
    # 降级：使用 sed 清理
    _disable_verynginx_sed "${nginx_conf}"
  fi
}

# 降级清理（无 Python3 时）
_disable_verynginx_sed() {
  local nginx_conf="$1"

  # B4：手动 include 形态必须一起清，否则 rm -rf 之后 nginx -t 直接失败
  sed -i '\|include .*/nginx_conf/in_[a-z_]*\.conf;|d' "${nginx_conf}"

  # 移除 server 级 lua 钩子
  sed -i '/rewrite_by_lua_file.*on_rewrite\.lua/d' "${nginx_conf}"
  sed -i '/access_by_lua_file.*on_access\.lua/d' "${nginx_conf}"
  sed -i '/log_by_lua_file.*on_log\.lua/d' "${nginx_conf}"

  # 移除 location 块（sed 的 :a N;$!ba;N;... 跳过大括号，简单起见按单行闭合处理；
  # 完整清理请用 python 路径）
  sed -i '/location \/verynginx\/ {/,/^ *}/d' "${nginx_conf}"
  sed -i '/location \/verynginx\/static\/ {/,/^ *}/d' "${nginx_conf}"
  sed -i '/location @vn_proxy {/,/^ *}/d' "${nginx_conf}"

  # 移除 upstream vn_dynamic_upstream
  sed -i '/upstream vn_dynamic_upstream/,/^ *}/d' "${nginx_conf}"

  # 移除 11 个 lua_shared_dict
  sed -i '/lua_shared_dict vn_config /d'  "${nginx_conf}"
  sed -i '/lua_shared_dict vn_locks /d'   "${nginx_conf}"
  sed -i '/lua_shared_dict vn_rate_limit /d' "${nginx_conf}"
  sed -i '/lua_shared_dict vn_session /d'  "${nginx_conf}"
  sed -i '/lua_shared_dict statistics /d'  "${nginx_conf}"
  sed -i '/lua_shared_dict metrics /d'     "${nginx_conf}"
  sed -i '/lua_shared_dict metrics_labeled /d' "${nginx_conf}"
  sed -i '/lua_shared_dict healthcheck /d' "${nginx_conf}"
  sed -i '/lua_shared_dict dns_cache /d'   "${nginx_conf}"
  sed -i '/lua_shared_dict frequency_limit /d' "${nginx_conf}"
  sed -i '/lua_shared_dict ip_reputation /d'  "${nginx_conf}"

  # 移除 init 块（单行/多行两种形态都要覆盖）
  sed -i '/init_by_lua_block/,/^ *}/d'     "${nginx_conf}"
  sed -i '/init_worker_by_lua_block/,/^ *}/d' "${nginx_conf}"

  # 移除 WebSocket upgrade map
  sed -i '/map \$http_upgrade \$connection_upgrade/,/^ *}/d' "${nginx_conf}"

  # 移除 env SSL_CERT_FILE
  sed -i '/env SSL_CERT_FILE/d' "${nginx_conf}"

  # 移除 lua_ssl_trusted_certificate
  sed -i '/lua_ssl_trusted_certificate/d' "${nginx_conf}"
  sed -i '/lua_ssl_verify_depth/d' "${nginx_conf}"

  # 移除 lua_code_cache
  sed -i '/lua_code_cache on;/d' "${nginx_conf}"

  # E6：清掉上游的状态文件与备份，否则换前缀重装时会按陈旧状态剥错 lua_package_path 段
  rm -f "${nginx_conf}.vn_lpp"
  # 保留 nginx.conf.bak.* —— 那是回滚用的现场，不删
}

# 打印安装后提示
_verynginx_print_summary() {
  echo
  echo "${CWARNING}Next steps:${CEND}"
  echo "  ${CMSG}./vhost.sh${CEND}                        # 新建站点自动受 WAF 保护"
  echo "  ${CMSG}http://<your-ip>/verynginx/${CEND}        # Dashboard（仅默认 server 与新 vhost 可访问）"
  echo "  ${CMSG}${verynginx_install_dir}/tools/upgrade.sh${CEND}  # 升级 VeryNginx 自身（勿用 ./addons.sh --verynginx）"
  echo
  echo "${CWARNING}已存在（VeryNginx 之前创建）的 vhost 不会自动补 WAF 钩子，需手动加，${CEND}"
  echo "${CWARNING}详见 VERYNGINX_MIGRATION_PLAN.md §6.3。${CEND}"
}

# 获取 VeryNginx 安装路径（供 vhost.sh 使用）。前缀无关（E4）。
# Usage: get_verynginx_dir
get_verynginx_dir() {
  local d
  if d=$(_verynginx_infer_dir); then
    printf '%s\n' "${d}"
  elif verynginx_is_installed; then
    printf '%s\n' "${verynginx_install_dir}"
  else
    printf '\n'
  fi
}
```

#### 5.1.2 `include/verynginx_tool.py`

> **v2 变更**：v1 草案只有 `verynginx_cleanup.py`（仅清理）。v2 改名 `verynginx_tool.py`
> 并增加 `seed-admin` 子命令（E7 所需）。B2 落地后 python3 成为安装路径的硬依赖，
> 卸载路径再降级到 sed 已无价值 —— 但仍保留 sed 降级（§9.1 风险表沿用）。

```python
#!/usr/bin/env python3
"""
VeryNginx helper for LNMP.

Subcommands:
  cleanup-nginx-conf <nginx.conf>   Remove all VeryNginx injections + state files
  seed-admin                        Pre-set the Dashboard admin password hash
                                    (reads $VN_ADMIN_PASSWORD, writes $VN_CONFIG)

The hash format MUST stay byte-compatible with upstream install-lnmp.sh's
write_admin_hash(): 'p1$<iterations>$<b64 salt>$<b64 derived>' over
PBKDF2-HMAC-SHA256. The Lua verifier parses the iteration count out of the
stored string, so old and new hashes coexist.
"""
import json
import os
import re
import sys
from hashlib import pbkdf2_hmac

# The 11 shared dicts upstream injects (install-lnmp.sh:626-630).
VN_SHARED_DICTS = (
    'vn_config', 'vn_locks', 'vn_rate_limit', 'vn_session',
    'statistics', 'metrics', 'metrics_labeled', 'healthcheck',
    'dns_cache', 'frequency_limit', 'ip_reputation',
)

# A location {} block with up to 2 levels of nesting. Upstream's injected
# blocks have none, but a hand-edited one might (e.g. a nested error_page).
_BLOCK = r'(?:[^{}]|\{(?:[^{}]|\{[^{}]*\})*\})*'


def _drop(pattern, content, flags=re.MULTILINE):
    return re.sub(pattern, '', content, flags=flags)


def _drop_block(content, header_pattern):
    return re.sub(r'^[ \t]*' + header_pattern + r'[ \t]*\{' + _BLOCK + r'\}[ \t]*\n?',
                  '', content, flags=re.MULTILINE)


def cleanup_nginx_conf(conf_path):
    with open(conf_path, 'r') as f:
        content = f.read()

    # --- B4 (new in v2): manual-include install path -------------------
    # get_verynginx_dir() recognises `include <DIR>/nginx_conf/in_*.conf;`
    # as a supported install shape (upstream's own "skip patching" branch
    # prints exactly these three lines, install-lnmp.sh:1718-1721). v1's
    # cleaner had no rule for them, so uninstalling on such a host left a
    # dangling include -> `rm -rf $VN_PREFIX` -> `nginx -t` fails on the
    # next start. Must be removed BEFORE the directory goes away.
    content = _drop(r'^[ \t]*include[ \t]+[^;]*/nginx_conf/in_[a-z_]+\.conf;[ \t]*\n?',
                    content)

    # --- server-level lua hooks ---------------------------------------
    content = re.sub(r'^[ \t]*rewrite_by_lua_file\s+\S*on_rewrite\.lua[ \t]*;\s*\n?', '', content, flags=re.M)
    content = re.sub(r'^[ \t]*access_by_lua_file\s+\S*on_access\.lua[ \t]*;\s*\n?',  '', content, flags=re.M)
    content = re.sub(r'^[ \t]*log_by_lua_file\s+\S*on_log\.lua[ \t]*;\s*\n?',       '', content, flags=re.M)

    # --- location blocks (default server + vhost-injected) ------------
    content = _drop_block(content, r'location[ \t]+/verynginx/')
    content = _drop_block(content, r'location[ \t]+/verynginx/static/')
    content = _drop_block(content, r'location[ \t]+@vn_proxy')

    # --- upstream / init / map ---------------------------------------
    content = _drop_block(content, r'upstream[ \t]+vn_dynamic_upstream')
    content = _drop_block(content, r'init_by_lua_block')
    content = _drop_block(content, r'init_worker_by_lua_block')
    content = _drop_block(content, r'map[ \t]+\$http_upgrade[ \t]+\$connection_upgrade')

    # --- shared dicts -------------------------------------------------
    content = _drop(r'^[ \t]*lua_shared_dict[ \t]+(?:' + '|'.join(VN_SHARED_DICTS)
                    + r')[ \t]+\S+;[ \t]*\n?', content)

    # --- misc directives ---------------------------------------------
    content = _drop(r'^[ \t]*env[ \t]+SSL_CERT_FILE[ \t]+\S+;[ \t]*\n?', content)
    content = _drop(r'^[ \t]*lua_ssl_trusted_certificate[ \t]+\S+;[ \t]*\n?', content)
    content = _drop(r'^[ \t]*lua_ssl_verify_depth[ \t]+\S+;[ \t]*\n?', content)
    content = _drop(r'^[ \t]*lua_code_cache[ \t]+on;[ \t]*\n?', content)
    content = _drop(r'^[ \t]*resolver[ \t]+(?:8\.8\.8\.8|1\.1\.1\.1)[^;]*;[ \t]*\n?', content)

    # --- lua_package_path / cpath: drop only the VeryNginx segments ---
    def _clean_paths(match):
        prefix, paths = match.group(1), match.group(2)
        kept = [p.strip() for p in paths.split(';')
                if p.strip() and 'verynginx' not in p.lower()]
        if not kept:
            return ''
        return '{} "{}"'.format(prefix, ';'.join(kept))

    for directive in ('lua_package_path', 'lua_package_cpath'):
        content = re.sub(r'(' + directive + r'\s+)"([^"]*)"', _clean_paths, content)
        # upstream also strips its own '# vn2-managed' marker comment
        content = _drop(r'^[ \t]*#\s*vn2-managed[ \t]*\n?', content)

    # --- collapse blank runs left behind by the removals --------------
    content = re.sub(r'\n{3,}', '\n\n', content)

    with open(conf_path, 'w') as f:
        f.write(content)

    # E6: the managed lua_package_path state file. Leaving it behind makes a
    # later reinstall with a DIFFERENT prefix strip the wrong segments
    # (install-lnmp.sh:525-528 reads it to decide what "ours" was).
    for state in (conf_path + '.vn_lpp',):
        if os.path.exists(state):
            os.remove(state)
    # nginx.conf.bak.* is deliberately KEPT: it is the rollback evidence.


def seed_admin():
    password = os.environ.get('VN_ADMIN_PASSWORD', '')
    config_path = os.environ.get('VN_CONFIG', '')
    if not password or not config_path:
        print('VN_ADMIN_PASSWORD and VN_CONFIG must both be set', file=sys.stderr)
        return 1
    iterations = int(os.environ.get('VN_PBKDF2_ITER', '600000'))

    import base64
    import secrets
    salt = os.urandom(16)
    derived = pbkdf2_hmac('sha256', password.encode('utf-8'), salt, iterations)
    b64 = lambda d: base64.b64encode(d).decode('ascii')
    hash_str = 'p1${}${}${}'.format(iterations, b64(salt), b64(derived))

    with open(config_path) as f:
        config = json.load(f)
    if not config.get('admin'):
        config['admin'] = [{'user': 'verynginx', 'enable': True}]
    config['admin'][0]['password_hash'] = hash_str
    config['admin'][0]['password'] = None
    if not isinstance(config.get('security'), dict):
        config['security'] = {}
    if not config['security'].get('session_secret'):
        config['security']['session_secret'] = secrets.token_hex(32)
    with open(config_path, 'w') as f:
        json.dump(config, f, indent=4)
    print('OK')
    return 0


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    if sys.argv[1] == 'cleanup-nginx-conf':
        if len(sys.argv) != 3:
            print('Usage: {} cleanup-nginx-conf <nginx.conf>'.format(sys.argv[0]),
                  file=sys.stderr)
            sys.exit(2)
        cleanup_nginx_conf(sys.argv[2])
    elif sys.argv[1] == 'seed-admin':
        sys.exit(seed_admin())
    else:
        print('Unknown subcommand: {}'.format(sys.argv[1]), file=sys.stderr)
        sys.exit(2)
```

> **实现注意**：
> - `cleanup-nginx-conf` 的目标文件由调用方决定。默认传 `nginx.conf`；
>   若用户把注入放在自己的 snippet 里（上游用 `VN_DIRECTIVE_FILE` 跟踪这种情况，
>   `install-lnmp.sh:361`），调用方需把那个 snippet 也传进来跑一次，否则该文件里
>   的 `include` 残留同样会让 `nginx -t` 失败。本期不自动遍历 `conf.d/`。
> - `_drop_block()` 的 `_BLOCK` 正则只支持 2 层嵌套。上游注入的块无嵌套，够用；
>   遇到更深的手写块会匹配失败 —— 失败时 `nginx -t` 会报出来，不会静默改坏。

### 5.2 修改文件

#### 5.2.1 `addons.sh`

**改动点 0（B1，新增，v1 草案遗漏）**：补 `check_dir.sh`

```diff
 . ./include/common.sh
 . ./include/ip_detect.sh
 . ./include/color.sh
 . ./include/check_os.sh
+. ./include/check_dir.sh
 . ./include/download.sh
 . ./include/get_char.sh
```

> 漏掉这一行，`include/verynginx.sh` 里所有 `${web_install_dir}/conf/nginx.conf` 都会
> 退化成 `/conf/nginx.conf`：`verynginx_is_enabled` 恒假、`install_verynginx` 第 1 步就报
> 「Nginx is not installed!」、第 8 步验证必然失败。vhost.sh:25 / uninstall.sh:27 /
> upgrade.sh:28 / install.sh:35 都已经 source 了它，**只有 addons.sh 缺**。

**改动点 1**：替换 source 引用

```diff
- . ./include/ngx_lua_waf.sh
+ . ./include/verynginx.sh
```

**改动点 2**：替换 CLI 参数

```diff
  --composer                  Composer
  --fail2ban                  Fail2ban
- --ngx_lua_waf               Ngx_lua_waf
+ --verynginx                 VeryNginx (WAF)
+ --verynginx_prefix <dir>    Install prefix (default /opt/verynginx, must be set
+                             before --verynginx; equivalent to upstream VN_PREFIX)
  #
+ # Non-interactive:
+ #   VN_ADMIN_PASSWORD=... ./addons.sh --verynginx -i
+ #   VN_FIREWALL_HELPER=keep ./addons.sh --verynginx -i   # opt in to the Go
+ #                                                       # kernel IP blocker
```

**改动点 3**：替换参数解析

```diff
-     --ngx_lua_waf)
-       ngx_lua_waf_flag=y; shift 1
+     --verynginx)
+       verynginx_flag=y; shift 1
+     --verynginx_prefix)
+       verynginx_prefix="$2"; shift 2
```

> `--verynginx_prefix` 只设置 `verynginx_install_dir`（供 LNMP 侧检测/清理用），
> 并在调用上游前 `export VN_PREFIX`，因为上游只认 `VN_PREFIX`（`install-lnmp.sh:19`）。
> 不设 `--verynginx_prefix` 时不 export，让上游用自己那份默认值，两边天然一致。

**改动点 4**：替换菜单选项

```diff
  What Are You Doing?
  \t${CMSG}1${CEND}. Install/Uninstall PHP Composer
  \t${CMSG}2${CEND}. Install/Uninstall fail2ban
- \t${CMSG}3${CEND}. Install/Uninstall ngx_lua_waf
+ \t${CMSG}3${CEND}. Install/Uninstall VeryNginx (WAF)
  \t${CMSG}q${CEND}. Exit
```

**改动点 5**：替换菜单处理逻辑

```diff
  3)
    ACTION_FUN
    if [ "${install_flag}" = 'y' ]; then
-     [ -e "${nginx_install_dir}/sbin/nginx" ] && Nginx_lua_waf
-     [ -e "${tengine_install_dir}/sbin/nginx" ] && Tengine_lua_waf
-     [ -e "${openresty_install_dir}/nginx/sbin/nginx" ] && echo "${CMSG}OpenResty has built-in Lua support${CEND}"
-     enable_lua_waf
+     install_verynginx
    elif [ "${uninstall_flag}" = 'y' ]; then
-     disable_lua_waf
+     uninstall_verynginx
    fi
    ;;
```

**改动点 6**：替换 CLI 直接调用逻辑

```diff
- if [[ "${ngx_lua_waf_flag}" == y ]]; then
+ if [[ "${verynginx_flag}" == y ]]; then
    if [ "${install_flag}" = 'y' ]; then
-     [ -e "${nginx_install_dir}/sbin/nginx" ] && Nginx_lua_waf
-     [ -e "${tengine_install_dir}/sbin/nginx" ] && Tengine_lua_waf
-     [ -e "${openresty_install_dir}/nginx/sbin/nginx" ] && echo "${CMSG}OpenResty has built-in Lua support${CEND}"
-     enable_lua_waf
+     install_verynginx
    elif [ "${uninstall_flag}" = 'y' ]; then
-     disable_lua_waf
+     uninstall_verynginx
    fi
  fi
```

#### 5.2.2 `vhost.sh`

**关键改动**：保留并改进 VeryNginx 自动注入逻辑。

**原逻辑问题**（`vhost.sh:988-997`）：
- 只用 `grep -oP 'include\s+\K/.*?(?=/nginx_conf/in_)'` 推断路径 —— 这是**模式 B**，
  而上游默认安装走的是**模式 A**（`replace_server_block` 直接写三行 `*by_lua_file`，
  根本不产生 include）。所以默认安装下这个 grep 返回空，只能靠 `/opt/verynginx`
  硬编码兜底；一旦用户自定义 `VN_PREFIX`，注入路径就是错的（WAF 静默不生效）。
- `verynginx_dir` 拿到后还要求 `${dir}/nginx_conf/in_server_block.conf` 存在，
  这对模式 A 是不必要的前置条件。

**新逻辑**：
- 用 `verynginx_is_installed()` 判断（双通道、前缀无关）
- 用 `get_verynginx_dir()` 取实际路径（模式 A / B 都认）
- 注入内容与上游 `in_server_block.conf` 的「去掉 `location /`」副本保持一致

> **维护同步警告**：下方注入块是上游 `verynginx/nginx_conf/in_server_block.conf` 的
> 「去掉 `location /`」副本。上游每次改 in_server_block.conf（如新增安全头/CSP），
> vhost.sh 不会自动同步。已核对：v2 基线 `616becc8` 下二者除 `location /` 外**逐行一致**。
> 优先方案是请上游提供不含 `location /` 的可 include 变体（如 `in_vhost_block.conf`）；
> 在变体落地前，每次升级 VeryNginx 后须人工核对，并在 `tools/lint/static_checks.sh`
> 加一条漂移检测（见 §5.2.10）。

```bash
  Add_Vhost() {
    if [ -e "${web_install_dir}/sbin/nginx" ]; then
      Choose_ENV
      Input_Add_domain
      Nginx_anti_hotlinking

      # VeryNginx WAF 自动注入（上游要求：新 vhost 自动受保护）
      local verynginx_include=""
      local verynginx_dir=""
      if verynginx_is_installed; then
        verynginx_dir=$(get_verynginx_dir)
      fi
      if [[ -n "${verynginx_dir}" ]] && [[ -f "${verynginx_dir}/on_access.lua" ]]; then
        verynginx_include="  rewrite_by_lua_file ${verynginx_dir}/on_rewrite.lua;
  access_by_lua_file ${verynginx_dir}/on_access.lua;
  log_by_lua_file ${verynginx_dir}/on_log.lua;

  set \$vn_proxy_scheme \"http\";
  set \$vn_proxy_host \$host;
  set \$vn_proxy_port \"80\";
  set \$vn_proxy_sni '';
  set \$vn_in_exec '';
  set \$vn_static_root '';
  set \$vn_static_expires 'epoch';

  location @vn_proxy {
      proxy_http_version 1.1;
      proxy_set_header Host \$vn_proxy_host;
      proxy_set_header X-Request-Id \$request_id;
      proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto \$scheme;
      proxy_set_header Upgrade \$http_upgrade;
      proxy_set_header Connection \$connection_upgrade;
      proxy_ssl_name \$vn_proxy_sni;
      proxy_ssl_server_name on;
      proxy_ssl_verify on;
      proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
      proxy_ssl_verify_depth 2;
      proxy_hide_header Server;
      proxy_hide_header X-Powered-By;
      proxy_connect_timeout 3s;
      proxy_read_timeout 60s;
      proxy_send_timeout 60s;
      proxy_pass http://vn_dynamic_upstream;
  }

  location /verynginx/static/ {
      alias ${verynginx_dir}/dashboard/;
      expires epoch;
      add_header X-Content-Type-Options \"nosniff\" always;
      add_header X-Frame-Options \"SAMEORIGIN\" always;
      add_header X-XSS-Protection \"1; mode=block\" always;
      add_header Content-Security-Policy \"default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'self'\" always;
      # 显式空块：location 级 access/log_by_lua_block（即使为空）会替换 server 级的
      # access_by_lua_file/log_by_lua_file，导致 WAF 对该路径失效。
      # 上游 install-lnmp.sh 的 replace_server_block() 同样注入这两行。
      access_by_lua_block { }
      log_by_lua_block { }
  }
  location /verynginx/ {
      # Managed by router plugin; no content handler needed
  }"
        echo "${CMSG}VeryNginx WAF enabled for this vhost${CEND}"
      else
        echo "${CWARNING}VeryNginx WAF not installed. Use ./addons.sh --verynginx to install.${CEND}"
      fi

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
```

#### 5.2.3 `options.conf`

```bash
# VeryNginx WAF（外部项目，不纳入 LNMP 版本管理；源码需自行 clone）
verynginx_install_dir=/opt/verynginx
```

#### 5.2.4 `.gitignore`

```gitignore
# ============================================
# 外部 WAF 项目（本地集成，不纳入版本管理）
# ============================================
/VeryNginx
```

> 现状：`VeryNginx` 符号链接当前是 untracked 状态，`.gitignore` 里**还没有**这条规则
> （已核对）。不加会被 `git add -A` 误提交。

#### 5.2.5 `uninstall.sh`

在卸载 web server **之前**处理 VeryNginx：

```bash
# 需在文件头部添加：. ./include/verynginx.sh
# （uninstall.sh:27 已 source check_dir.sh，web_install_dir 可用；
#   uninstall.sh 已 source common.sh，svc_reload 可用）
if verynginx_is_installed; then
  echo "${CMSG}Uninstalling VeryNginx...${CEND}"
  # 备份 configs/ + VERSION + COMMIT（不可逆动作前留证）
  # disable_verynginx_in_nginx_conf 内部已做 Python → sed 降级
  # B4: 必须先清 include，再删目录，否则 nginx -t 失败
  # B3: 必须一并清理 firewall-helper 的 systemd 单元与二进制
  uninstall_verynginx
fi
```

> v1 草案在这里内联了 `disable_verynginx_in_nginx_conf` + `rm -rf`，与
> `uninstall_verynginx` 逻辑重复且**漏了备份、漏了 firewall-helper、漏了 reload 校验**。
> v2 统一走 `uninstall_verynginx`。
> `backup_dir` 已在 `options.conf` 中定义（默认 `/data/backup`），`uninstall.sh` 已 source
> `options.conf`，可直接使用。

#### 5.2.6 `upgrade.sh`（E1 更正：校验，不是重装）

```bash
# 需在文件头部添加：. ./include/verynginx.sh
# （upgrade.sh:28 已 source check_dir.sh）
# 位置：Upgrade_Nginx / Upgrade_Tengine / Upgrade_OpenResty 成功之后
#
# E1: 本仓库的 web 升级只替换二进制（upgrade_web.sh:269-273 / :169 / :94-98），
#     nginx.conf 不会被覆盖，所以 VeryNginx 注入不会因升级丢失。
#     这里做的是「校验」而不是 v1 草案的「提示重装」——
#     compile_check 的 `nginx -t` 虽已顺带校验过注入，但那只覆盖默认 server 块，
#     覆盖不到 vhost/*.conf 里的 WAF 钩子（钩子指向的 .lua 若随前缀变更而失效，
#     -t 不会报错，只在请求时才 500）。
if verynginx_is_installed; then
  local _vn_dir; _vn_dir=$(get_verynginx_dir)
  if [[ -n "${_vn_dir}" ]] && [[ -f "${_vn_dir}/on_access.lua" ]]; then
    echo "${CSUCCESS}VeryNginx still active at ${_vn_dir}${CEND}"
  else
    echo "${CWARNING}VeryNginx config detected but ${_vn_dir}/on_access.lua is missing.${CEND}"
    echo "${CWARNING}Run ${CEND}${CMSG}./addons.sh --verynginx -u && ./addons.sh --verynginx -i${CEND}"
  fi
fi
```

#### 5.2.7 `README.md`

```diff
- - Fail2ban (安全防护) / Composer / ngx_lua_waf (WAF)
+ - Fail2ban (安全防护) / Composer / VeryNginx (WAF)
```

> 另需在「常用命令」补 `./addons.sh --verynginx`（见 §5.2.8 同步项）。

#### 5.2.8 `DOWNLOAD_SOURCES.txt`

```diff
- ngx_lua_waf         | https://github.com/loveshell/ngx_lua_waf       | GitHub    | 无
+ VeryNginx           | https://github.com/nengfeng/VeryNginx         | GitHub    | 无
```

> VeryNginx **不由 `download_sources.sh` 下载**：它是外部项目，体积大、自带 release 流程，
> 且 `install-lnmp.sh` 期望一个 git 仓库（要用 `git rev-parse HEAD` 写 `COMMIT`）。
> 因此不走 `sources.conf` / `versions.txt`，改为在 `README.md` 写明 clone 步骤 + pin。

#### 5.2.9 `tools/lint/static_checks.sh`

**已确认无需改动**（`tools/lint/static_checks.sh:18,275` 已排除 `./VeryNginx/*`）。
但**新增一条护栏**（见 §5.2.10）。

#### 5.2.10 `tools/lint/static_checks.sh`（新增第 13 条护栏）

§5.2.2 的注入块与上游 `in_server_block.conf` 的漂移检测。当前 `static_checks.sh` 有 12 项
护栏（已实测 PASS），新增第 13 项：

```bash
# == 13. vhost.sh VeryNginx injection must match upstream in_server_block.conf ==
# The injected block is a copy of upstream's in_server_block.conf minus
# 'location /'. Upstream edits that file freely; a silent divergence means
# new vhosts run a different WAF config than the default server block.
# Skipped when ./VeryNginx is absent (not cloned).
```

检查逻辑：以 `try_files` 为分界标记（`location /` 块的唯一特征行），
比较「分界之前的所有非注释行」的集合。这样即使 `location /verynginx/` 等
其他 location 块出现在中间，也不会被误判为分界。
VeryNginx 源码不存在时 SKIP 而非 FAIL（CI 容器里没有 clone，见 §8.4）。

#### 5.2.11 `health_check.sh` / `backup.sh`（v2 从 §11 提前到本期）

- `health_check.sh`：新增 VeryNginx 检查项（`verynginx_is_installed` &&
  `verynginx_is_enabled` && 三个 `.lua` 存在），FAIL 时退出码为 1。
  这条不是「以后再说」——卸载/升级路径的正确性高度依赖 nginx.conf 注入状态，
  没有健康检查，用户无法在出事之前发现注入被清掉了。
- `backup.sh`：备份 `${VN_DIR}/configs/{config,waf-rules}.json` + `VERSION` + `COMMIT`
  到 `${backup_dir}/verynginx/`。理由同上：`uninstall_verynginx` 会删掉整个目录，
  规则是用户资产（可能花时间调过），不能在无备份的情况下删除。

#### 5.2.12 `CHANGELOG.md`

新增 v2.0.0 条目，`Removed` 段记录 `include/ngx_lua_waf.sh` 与 `--ngx_lua_waf`，
`Changed` 段记录 `addons.sh --verynginx`。

> **版本号待定**：当前 1.7.5，本次删除公开 CLI 选项（`--ngx_lua_waf`）与模块
> （`include/ngx_lua_waf.sh`），按项目自述的 SemVer 策略（`CHANGELOG.md` 开头
> 「adheres to Semantic Versioning」）应发 **2.0.0** 而非 v1 草案写的 1.8.0。
> 请确认后再定稿。

### 5.3 删除文件

#### 5.3.1 `include/ngx_lua_waf.sh`

**整个文件删除，不保留别名、不保留降级开关**（已确认的决策，理由见文档头）。
所有逻辑已迁移到 `include/verynginx.sh`。

> 删除时**不要动** `vhost.sh:988-1039` —— 那段是 VeryNginx 注入，与 ngx_lua_waf 无关。
> 同时按 §5.2.7 / §5.2.8 更新 `README.md` / `DOWNLOAD_SOURCES.txt` / `CHANGELOG.md`
> 中的 `ngx_lua_waf` 字样（`README.md:25`、`DOWNLOAD_SOURCES.txt:151`、
> `CHANGELOG.md:275` 为历史记录，**不改**）。

## 6. 迁移路径

### 6.1 已安装 ngx_lua_waf 的用户

```
1. ./addons.sh --verynginx -i
   - verynginx_check_prereqs：检查/安装 python3，检查 nginx + lua-nginx-module
   - _verynginx_remove_legacy_lua_waf：移除 `include waf.conf;` + conf/{waf,waf.conf}
   - 定位源码目录：current_dir/VeryNginx → /opt/VeryNginx → /root/VeryNginx
   - 备份 nginx.conf 为 nginx.conf.lnmp-pre-verynginx.<ts>
   - _verynginx_seed_admin_if_needed：非交互场景预置 admin 密码
     交互式：按提示设置 Dashboard 管理员密码
     非交互式：export VN_ADMIN_PASSWORD=... （否则上游生成随机密码并打进日志）
   - 上游 install-lnmp.sh：部署到 /opt/verynginx + 注入 nginx.conf
   - _verynginx_reconcile_firewall_helper：移除非预期的 firewall-helper
   - 验证：verynginx_is_installed && verynginx_is_enabled

2. 验证
   - /usr/local/nginx/sbin/nginx -t
   - 访问 http://<your-ip>/verynginx/  （Dashboard）
   - 访问 http://<your-ip>/verynginx/static/style.css （静态资源）
3. 存量 vhost 手动补钩子（见 §6.3）
```

### 6.2 新用户

```
1. ./install.sh                       # 已含 lua-nginx-module + lua-resty-core/lrucache
2. git clone https://github.com/nengfeng/VeryNginx ./VeryNginx
   git -C ./VeryNginx checkout 616becc8a2cbc554166cbf0e03147ba3e43aa745
3. ./addons.sh --verynginx -i
4. ./vhost.sh                         # 新建站点自动受 WAF 保护
```

### 6.3 已有 vhost 的用户（安装 VeryNginx 之前创建的站点）

上游明确说明：**安装 VeryNginx 之前已创建的 vhost 不会自动补**。

> **重要**：这些 vhost 也不会被 `uninstall_verynginx` 的清理脚本覆盖 ——
> `verynginx_cleanup.py` 只处理 `nginx.conf`，不遍历 `conf/vhost/*.conf`。
> 这是有意的（vhost 文件是用户资产），但意味着**迁移完成后这些 vhost 仍是裸奔状态**，
> 必须在安装提示里显式告知（`_verynginx_print_summary` 已包含该提示）。

用户需要手动在已有 vhost 的 `server {}` 块里加：

```nginx
rewrite_by_lua_file /opt/verynginx/on_rewrite.lua;
access_by_lua_file  /opt/verynginx/on_access.lua;
log_by_lua_file     /opt/verynginx/on_log.lua;
location /verynginx/static/ { alias /opt/verynginx/dashboard/; expires epoch; }
location /verynginx/ { }
```

## 7. 兼容性处理

### 7.1 nginx.conf 注入幂等性

`install-lnmp.sh` 的 `patch_nginx_conf()` 已实现幂等性（已核实）：
- 每个 dict/init 指令独立 `directive_file()` 检查（`:626-630`），不是「见到一个标记就全跳过」
- `lua_package_path` 用 managed-marker + 状态文件策略（`:520-580`），
  自定义 `VN_PREFIX` 下也能正确换路径
- server 块注入用 Python 每次全量替换

### 7.2 LNMP 自带 `lua_package_path` 的合并

`config/nginx.conf:19-20` 已经带 LNMP 自己的 `lua_package_path` / `lua_package_cpath`。
已核实上游的 awk 合并逻辑（`install-lnmp.sh:530-580`）会**保留用户原有段**、只追加
VeryNginx 的段并打 `# vn2-managed` 标记。**无冲突，无需额外处理。**

### 7.3 多 nginx 实例

`install-lnmp.sh` 的 `detect_web_server()`（`:113`）支持 nginx/tengine/openresty 三种，
与 LNMP 的 `check_dir.sh:10-12` 判定顺序一致。

### 7.4 OpenResty 特殊处理

OpenResty 自带 lua-nginx-module。`verynginx_check_prereqs()` 里**先判 OpenResty 再 grep
编译参数**，否则会被误判为「未编译 Lua」（OpenResty 的 `nginx -V` 不含
`lua-nginx-module` 字样）。

### 7.5 多 PHP 版本

VeryNginx 的 lua 钩子在 server 级别，与 PHP 版本无关。多 PHP 版本（mphp）无需特殊处理。

### 7.6 上游两个依赖检查的实际情况

`check_lua_resty_deps()`（`:1194`）与 `check_geoip_deps()`（`:1258`）**都只 warn，不 die**，
且 LNMP 已满足其要求（已核实）：

| 依赖 | 是否真需要 | LNMP 是否已装 |
|------|-----------|--------------|
| `lua-resty-core` | **需要**：`ngx.re` 被 6 个文件使用（`matcher/compare.lua`、`action/rewrite.lua`、`waf-rule-manager.lua`、`resty/http_connect.lua` 等） | ✅ `include/web-common.sh:200-214`，还额外建了 `resty/core/init.lua` |
| `lua-resty-lrucache` | **不需要**：`grep -rn lrucache verynginx/` 在 `.lua` 里 0 命中，上游这个检查偏保守 | ✅ `include/web-common.sh:216-222` 已装 |
| GeoIP（LuaJIT + FFI） | 可选，仅影响 IP 信誉库 | ✅ LuaJIT 由 `web-common.sh:185-192` 编译 |

**结论**：无需在方案里额外装任何 Lua 依赖。install.sh 装完的 nginx 直接满足要求。

### 7.7 per-host 统计（上游新特性）

上游 `1291aa2` 的 per-host 统计与 WAF 集成无关，但需要注意：
- `statistics` dict 的 key 从 `1m:<uri>:*` 变为 `1m:<host>:<uri>:*`
- 需要确保 `max_hosts` 配置合理（默认 50）
- 升级时统计会重置（易失数据，非配置）

## 8. 测试计划

### 8.1 单元测试

| 测试项 | 命令 | 预期结果 |
|--------|------|----------|
| VeryNginx 安装 | `./addons.sh --verynginx -i` | 安装成功，nginx.conf 注入正确 |
| VeryNginx 卸载 | `./addons.sh --verynginx -u` | 卸载成功，`nginx -t` 通过，**无残留 systemd 单元** |
| 重复安装 | 连续运行两次 | 第二次提示已安装，并提示用 `tools/upgrade.sh` 升级 |
| 重复卸载 | 连续运行两次 | 第二次提示未安装 |
| 自定义前缀 | `./addons.sh --verynginx_prefix /data/vn2 --verynginx -i` | 安装到 `/data/vn2`；**再跑一次安装应识别为「已安装」**（E4 回归） |
| 缺 python3 | 在无 python3 的容器里 `-i` | 自动装 python3 后继续；装不上则明确报错而非让上游 die |
| 缺 lua 模块 | 用未编译 Lua 的 nginx `-i` | 提示先跑 `./upgrade.sh --nginx` |

### 8.2 集成测试

| 测试项 | 命令 | 预期结果 |
|--------|------|----------|
| 安装后创建 vhost | `./vhost.sh` | vhost 自动注入 WAF 处理器；**默认前缀和自定义前缀都要测**（E4） |
| 手动 include 形态 | 手改 nginx.conf 用 `include .../nginx_conf/in_*.conf` 后 `-u` | **卸载后 `nginx -t` 必须通过**（B4 回归） |
| 默认安装形态卸载 | 标准安装后 `-u` | `nginx -t` 通过，`/usr/local/bin/firewall-helper` 不存在，两个 systemd 单元已 `reset-failed`/删除（B3 回归） |
| 升级 Nginx 后 | `./upgrade.sh --nginx <ver>` | VeryNginx 仍 active（E1）；`nginx -t` 通过 |
| 卸载全流程 | `./uninstall.sh --all --yes` | 先备份 configs/ 再清理；`/opt/verynginx` 消失；nginx.conf 无 `verynginx` 残留 |
| health check | `./health_check.sh` | VeryNginx 检查项在；注入被清掉时 FAIL 且退出码 1 |

### 8.3 回归测试

| 测试项 | 命令 | 预期结果 |
|--------|------|----------|
| 现有 vhost 功能 | 访问已创建的 vhost | 正常访问，WAF 日志记录 |
| Let's Encrypt | `./vhost.sh` 选 LE | 证书签发成功，WAF 不干扰（`acme-challenge` 已在 `fa8b8e0` 豁免重定向） |
| 多 PHP 版本 | `./vhost.sh` 选 mphp 8.4 | PHP 8.4 站点正常，WAF 生效 |
| 反代 vhost | `./vhost.sh` 选 proxy | `@vn_proxy` 与 `$vn_proxy_*` 变量齐全（对应 `48cbb40`） |
| 备份/恢复 | `./backup.sh` 后卸载再装 | `waf-rules.json` 可恢复 |

### 8.4 容器测试

`.github/workflows/container-smoke.yml` 新增 VeryNginx 步骤。
**v1 草案的 `ln -s /root/VeryNginx ./VeryNginx` 在 CI 容器里跑不通** —— 容器只 build
本仓库，没有 `/root/VeryNginx`，会停在 `install-lnmp.sh not found`。改为显式 clone + pin：

```yaml
- name: Install VeryNginx
  run: |
    # 外网可达性由 workflow 自行保证；pin 与方案基线一致
    # 先无检出克隆，再 fetch 特定 commit（--depth 1 只保留最新历史，无法直接 fetch）
    git clone --no-checkout https://github.com/nengfeng/VeryNginx ./VeryNginx
    git -C ./VeryNginx fetch --depth 1 origin 616becc8a2cbc554166cbf0e03147ba3e43aa745
    git -C ./VeryNginx checkout 616becc8a2cbc554166cbf0e03147ba3e43aa745
    VN_ADMIN_PASSWORD=ci-smoke-pwd ./addons.sh --verynginx -i

- name: Verify VeryNginx
  run: |
    /usr/local/nginx/sbin/nginx -t
    grep -q 'lua_shared_dict' /usr/local/nginx/conf/nginx.conf
    grep -q 'rewrite_by_lua_file' /usr/local/nginx/conf/nginx.conf
    # B3 回归：默认不应留下 firewall-helper
    test ! -f /usr/local/bin/firewall-helper
    test ! -f /etc/systemd/system/firewall-helper.socket
    # 静态资源可取
    curl -sf http://localhost/verynginx/static/style.css -o /dev/null

- name: Vhost inherits WAF
  run: |
    ./vhost.sh          # 交互，expect 驱动
    grep -q 'on_access.lua' /usr/local/nginx/conf/vhost/*.conf

- name: Uninstall VeryNginx
  run: |
    ./addons.sh --verynginx -u
    /usr/local/nginx/sbin/nginx -t          # B4 回归：不能失败
    test ! -d /opt/verynginx
    ! grep -q 'verynginx' /usr/local/nginx/conf/nginx.conf
```

前置条件：该容器镜像需装 `python3`（或在 `Install VeryNginx` 步骤里由
`verynginx_check_prereqs` 自动装；建议直接进镜像，避免步骤内 apt 拖慢）。

### 8.5 提交前必过的四道门禁（CONTRIBUTING.md）

本方案改动 `addons.sh` / `vhost.sh` / `uninstall.sh` / `upgrade.sh` /
`include/verynginx.sh` / `include/verynginx_tool.py`，**每道都要绿**：

```bash
bash tools/lint/static_checks.sh      # 13 项静态护栏（§5.2.10 新增第 13 项）
bash tools/test_offline.sh            # 166 用例离线逻辑测试
bash tools/lint/os_gate_checks.sh     # 21 用例发行版门禁
shellcheck -S warning $(find . -name '*.sh' -not -path './src/*' -not -path './VeryNginx/*')
```

> - `verynginx.sh` 必须过 shellcheck warning 级。已知需注意：
>   `local` 只在函数内用、命令替换全部加引号、`grep` 无匹配返回 1 时不能触发
>   `set -e` 类中断（LNMP 入口脚本未开 `set -e`，但仍按 warning 级要求写）。
> - `verynginx_tool.py` 不在 shellcheck 范围内；建议加 `python3 -m py_compile`
>   到 `static_checks.sh` 第 13 项里一起做语法检查。
> - 护栏第 13 项在 `./VeryNginx` 不存在时应 SKIP 而非 FAIL，否则本地未 clone 的
>   贡献者会被卡住。

## 9. 风险与回滚

### 9.1 风险

| 风险 | 影响 | 缓解措施 |
|------|------|----------|
| VeryNginx 安装失败 | WAF 不可用 | 上游有 `nginx -t` 校验；LNMP 额外备份 `nginx.conf.lnmp-pre-verynginx.<ts>` 并在失败时打印路径。**ngx_lua_waf 不再作为备选**（已确认删除）；回滚走 §9.2 |
| nginx.conf 注入冲突 → nginx 起不来 | 站点全挂 | 上游 `nginx -t` 失败即回滚；LNMP 安装前备份 conf；`uninstall_verynginx` 卸载后强制 `svc_reload` 校验，失败即报并保留 `.bak.*` |
| **手动 include 形态卸载后 nginx 起不来**（B4） | 站点全挂 | `verynginx_tool.py cleanup-nginx-conf` 删除 `include .../nginx_conf/in_*.conf`；sed 降级路径同样覆盖；§8.2 有专门回归用例 |
| **firewall-helper 泄漏**（B3） | 残留 root 二进制 + 已 enable 的 systemd 单元；内核级封禁规则可能残留 | 默认不装；`_verynginx_reconcile_firewall_helper` 在安装后与卸载时各跑一次，完整停服 + disable + 删单元 + 删二进制 + 清 `/run/verynginx`；`VN_FIREWALL_HELPER=keep` 为显式 opt-in |
| **缺 python3**（B2） | 上游在改动任何文件前 die，LNMP 侧表现为「什么都没发生」 | `verynginx_check_prereqs` 前置检查并按需 apt 安装；失败时给出明确中文/英文提示而非上游原文 |
| **nginx 升级导致 vhost 钩子失效** | vhost 静默 500（`-t` 不报错） | `nginx.conf` 不被覆盖（§3.4 已核实），但 `VN_PREFIX` 若被改会让钩子指向空路径 → §5.2.6 的升级后校验 + §5.2.11 的健康检查兜底 |
| **非交互安装拿不到管理员密码**（E7） | 自动化流程无法登录 Dashboard | `VN_ADMIN_PASSWORD` 环境变量预置（格式与上游 `p1$` 一致）；未提供时明确提示「随机密码已打印在上方输出」 |
| **注入块与上游漂移** | 新 vhost 的 WAF 配置与默认 server 块不一致 | §5.2.10 新增第 13 项护栏自动检测；并推动上游提供不含 `location /` 的 include 变体 |
| 规则被误删 | 用户 WAF 规则丢失 | `uninstall_verynginx` 与 `uninstall.sh` 卸载前备份 `configs/` 到 `${backup_dir}/verynginx/`；`backup.sh` 纳入常规备份（§5.2.11） |

### 9.2 回滚方案

`ngx_lua_waf` 已确定删除，因此回滚不再依赖「保留旧文件」，而依赖 git 历史：

1. **发布前**：本方案合并到 `main` 之前，先打 tag `v1.7.5`（当前 `version()` 输出）。
   出现问题时 `git revert` 合并 commit 即可完整回到 v1.7.5 状态。
2. **已发布后**：
   - 脚本层：`./upgrade.sh --script` 回到上一个 release tarball；
     或从 tag 重新取 `addons.sh` / `vhost.sh` / `include/ngx_lua_waf.sh`。
   - 站点层：VeryNginx 的注入是**纯附加**的（vhost 里三行 `*by_lua_file` +
     两个 `location`），移除它们不影响站点原有行为；
     `disable_verynginx_in_nginx_conf` 可精确清除。
3. **不建议**的做法：手工 `sed` 删 vhost 里的钩子。WAF 钩子覆盖 rewrite/access/log
   三个阶段，手删容易漏掉 `set $vn_*` 变量导致 `@vn_proxy` 报未知变量。

## 10. 实施步骤

### Phase 1：准备（0.5 天）

1. `.gitignore` 加 `/VeryNginx`（§5.2.4）
2. `options.conf` 加 `verynginx_install_dir`（§5.2.3）
3. 创建 `include/verynginx.sh`（§5.1.1）
4. 创建 `include/verynginx_tool.py`（§5.1.2）

**出口条件**：`bash -n include/verynginx.sh` + `python3 -m py_compile include/verynginx_tool.py` 通过。

### Phase 2：核心改动（1.5 天）

1. `addons.sh`：补 `check_dir.sh`（B1）+ 替换 ngx_lua_waf（§5.2.1）
2. `vhost.sh`：改用 `verynginx_is_installed()` / `get_verynginx_dir()`（§5.2.2）
3. `uninstall.sh`：改走 `uninstall_verynginx`（§5.2.5）
4. `upgrade.sh`：升级后校验（§5.2.6）
5. `health_check.sh` + `backup.sh`（§5.2.11）
6. 删除 `include/ngx_lua_waf.sh`（§5.3.1）

**出口条件**：§8.1 全部单元测试通过 + §8.5 四道门禁全绿。

### Phase 3：护栏与文档（0.5 天）

1. `tools/lint/static_checks.sh` 新增第 13 项护栏（§5.2.10）
2. 更新 `README.md` / `DOWNLOAD_SOURCES.txt`（§5.2.7 / §5.2.8）
3. `CHANGELOG.md` 起草 2.0.0 条目（§5.2.12，版本号待确认）

### Phase 4：容器验证（1 天）

1. `container-smoke.yml` 加 §8.4 的 4 个步骤
2. 完整跑通：安装 → 校验 → 建 vhost → 卸载 → `nginx -t`
3. 手工验证 B3 / B4 两条回归（firewall-helper 不泄漏、手动 include 形态卸载干净）

### Phase 5：发布（0.5 天）

1. 四道门禁 + 容器冒烟全绿
2. 合并到 `main`，打 tag
3. 发布（版本号按 §5.2.12 确认）

> **相比 v1 草案**：Phase 1 从 1 天降到 0.5 天（准备工作量确实小），
> 但 Phase 2 从 2 天升到 1.5 天且**新增了 5 个改动点**（B1/E4/E7 的健康检查与备份），
> Phase 3 新增护栏。总计由 6 天调整为 4 天 —— 因为 v2 砍掉了基于错误前提的
> 「Nginx 升级重装提示」相关工作。

## 11. 后续优化（本期不做）

1. **vhost.sh 可选注入**：提供 `--no-waf` 参数让用户选择是否为新 vhost 启用 WAF
   （当前是「装了 VeryNginx 就必然注入」，与上游要求一致，但粒度偏粗）
2. **多站点 WAF 策略**：支持为不同 vhost 配置不同的 WAF 规则集（依赖上游 per-host 配置）
3. **per-host 统计集成**：上游 `1291aa2` 的 dashboard host filter 可与 LNMP 的 vhost 列表联动
4. **Firewall Helper 正式纳入**：若用户确有内核级封禁需求，评估把它做成
   `addons.sh --firewall-helper` 独立选项（需要 Go 工具链 + nftables，需单独设计依赖与回滚）
5. **上游推动**：请 VeryNginx 提供不含 `location /` 的 `in_vhost_block.conf`，
   消除 vhost.sh 注入块的漂移风险（根治 §5.2.10 的护栏）

## 12. 评审结论对照表

| 编号 | v1 草案的问题 | 证据 | v2 的处理 |
|------|--------------|------|-----------|
| **B1** | `addons.sh` 未 source `check_dir.sh`，`web_install_dir` 未定义，所有检测函数退化为 `/conf/nginx.conf` | `web_install_dir` 仅在 `include/check_dir.sh:10-12` 赋值；`vhost.sh:25`、`uninstall.sh:27`、`upgrade.sh:28`、`install.sh:35` 有 source，`addons.sh:24-38` 没有 | §5.2.1 改动点 0 补 source；§5.1.1 另有 `_verynginx_resolve_web_dir` 兜底 |
| **B2** | python3 是上游硬依赖（改动文件前即 die），方案完全没处理 | `install-lnmp.sh:1706-1711`；`grep python3` 在 `install.sh` 依赖列表中 0 命中 | §5.1.1 `verynginx_check_prereqs` 前置检查 + apt 安装；§7/§9.1 风险表改写 |
| **B3** | firewall-helper 被默认装上（上游 confirm 默认 y、无 flag 可关），卸载只 `rm -rf $VN_DIR` → 泄漏 root 二进制 + 2 个已 enable 的 systemd 单元 | `install-lnmp.sh:1719/1734`（prompt）、`:1420`（bin）、`:1422`（dir）、`:1593/1613`（units）、`:1642`（enable） | §5.1.1 `_verynginx_reconcile_firewall_helper` 安装后 + 卸载时各对账一次；`VN_FIREWALL_HELPER=keep` 显式 opt-in；§8.1/§8.2/§8.4 有回归断言 |
| **B4** | 清理脚本不删手动 `include .../nginx_conf/in_*.conf`，卸载后 `nginx -t` 失败 | `get_verynginx_dir` 模式 B 与上游 `install-lnmp.sh:1718-1721` 都确认该形态存在；v1 的 python 无对应规则 | §5.1.1 `_disable_verynginx_sed` + §5.1.2 `cleanup-nginx_conf` 均补规则；§8.2 专门回归用例 |
| **E1** | 「Nginx 升级重新生成 nginx.conf，丢失注入」在本仓库不成立 | `upgrade_web.sh:269-273`（nginx）/`:169`（tengine）/`:94-98`（openresty）只换二进制；conf 仅 `sed brotli` | §3.4 新增专节更正；§5.2.6 由「提示重装」改为「升级后校验」；§9.1 删该风险行；实施工作量相应减少 |
| **E2** | 「install-lnmp.sh 约 1200 行」；`check_lua_resty_deps`/`check_geoip_deps` 无归属 | 实测 1751 行；`main():1702-1745` 九步序列 | §3.2 改为完整执行序列表 + 归属列；§7.6 核实两个检查的依赖已被 LNMP 满足 |
| **E3** | 容器测试 `ln -s /root/VeryNginx ./VeryNginx` 在 CI 里不存在 | CI 容器只 build 本仓库 | §8.4 改为 `git clone` + checkout 到 `616becc8` pin + 补 `python3` 前置 |
| **E4** | `verynginx_is_installed` 写死 `/opt/verynginx`，但上游 `VN_PREFIX` 可覆盖 → 误判未安装 | `install-lnmp.sh:19` `VN_PREFIX="${VN_PREFIX:-/opt/verynginx}"` | §5.1.1 改为「配置路径 + nginx.conf 推断」双通道；`addons.sh` 增 `--verynginx_prefix`；§8.1 加自定义前缀回归 |
| **E5** | 让用户重跑 `./addons.sh --verynginx` 来升级，但该命令会「already installed」提前返回 | §5.1.1 的早退分支；上游自带 `${VN_DIR}/tools/upgrade.sh`（`:219-224`） | §5.1.1 早退提示改为指向 `tools/upgrade.sh`；`_verynginx_print_summary` 同步更正；§6.2 补 pin 步骤 |
| **E6** | 清理留下 `${NGINX_CONF}.vn_lpp` 状态文件与 `.bak.*` | `install-lnmp.sh:525-528`（读状态）、`:342-360`（备份） | §5.1.2 删除 `.vn_lpp`；§5.1.1 sed 降级路径同样删除；`.bak.*` 明确保留为回滚现场 |
| **E7** | 非交互安装时上游自动生成随机密码，方案没提 | `install-lnmp.sh:296-334`，`read -rs` 无 closed-stdin 保护 | §5.1.1 `_verynginx_seed_admin_if_needed` 预置（利用 `install_files` 内 `:228` 早于 `:251` 的顺序）；§5.1.2 增 `seed-admin` 子命令；密码走环境变量不走 argv |
| — | ngx_lua_waf 保留为备选 / 旧分支保留（与 §5.3.1 删除自相矛盾） | 用户已确认删除 | 统一为删除；§9.2 回滚改用 git tag / `git revert`；版本号建议 2.0.0（§5.2.12 待确认） |
| — | 健康检查 / 规则备份被推迟到「后续优化」 | — | §5.2.11 提前到本期：卸载会删 `configs/`，规则是用户资产；注入状态无监控则无法提前发现被清掉 |
| — | 无注入块漂移检测 | — | §5.2.10 新增护栏第 13 项 + §8.5 门禁 |
