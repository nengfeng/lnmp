# LNMP 反代功能设计方案

> 状态：已实现（`reverse_proxy.sh` + `include/reverse_proxy.sh` + Lua 模块）  
> 脚本入口：`reverse_proxy.sh`  
> 方案日期：2026-11-24

## 1. 目标与已确认决策

新增独立的反向代理管理脚本，不接入 `vhost.sh`。用户输入域名 A 和上游 B 后，访问 A 会返回 B 的内容，并尽量让用户感知不到 B。

已确认的决定：

| 项 | 决定 |
|---|---|
| rewrite | **默认开启**，可用 `--no-rewrite` 关闭 |
| cert | **默认 auto**，可显式选择 custom / none |
| 上游路径 | MVP **只支持根路径 `/`** |
| 域名数量 | **单域名**，不做别名/多域名 |
| 访问控制 | MVP **不做**，后续可扩展 |
| WebSocket / SSE / 大文件流式 | **不支持** |
| 管理入口 | **命令行** |
| 与 vhost 的关系 | **完全独立脚本**，只共享 nginx 配置目录 |

### 1.1 两条透明级别

- **L1 地址栏透明**：A 不跳转，内容原样来自 B。稳定、简单。
- **L2 内容透明**：尽量改写响应头和响应体中的 B 域名。接受不完美。

默认走 L2；对已知会出问题的上游，用 `--no-rewrite` 退回 L1。

### 1.2 明确不承诺的 L2 场景

- 上游强制 gzip 且无法协商成 identity
- JS 运行时动态拼接的绝对 URL
- JSON API 中超过阈值或未被改写的绝对地址
- 二进制资源内部的域名字符串
- SSE / 直播 / 大文件
- `__Host-` Cookie、`Secure` Cookie、Domain 绑定导致的登录态异常
- 上游基于 TLS 指纹、UA、地域的拦截

这些限制必须在 `docs/reverse_proxy.md`、`--help` 和 CHANGELOG 中写清楚。

---

## 2. 文件布局

```text
reverse_proxy.sh                         # CLI 入口
include/reverse_proxy.sh                 # 核心函数库，供 CLI 和测试 source
config/reverse_proxy/nginx.conf.template # nginx 配置模板
config/reverse_proxy/rp_header.lua       # header_filter_by_lua 文件
config/reverse_proxy/rp_body.lua         # body_filter_by_lua 的 nginx 胶水层
config/reverse_proxy/rp_rewrite.lua      # 纯 Lua 替换/缓冲逻辑，供 luajit 测试
tools/test_reverse_proxy.sh              # 离线单元测试
docs/reverse_proxy.md                    # 本文档
```

运行时数据：

```text
/data/lnmp/reverse_proxy/
├── <domain>.conf          # 元数据，key=value
├── backups/               # 覆盖前的配置/元数据备份
├── lua/                   # 实际加载的 Lua 文件
└── operations.log         # 操作日志
```

生成的站点配置：

```text
${web_install_dir}/conf/vhost/<domain>.conf
```

文件头必须带标记：

```nginx
# LNMP reverse proxy managed by reverse_proxy.sh - DO NOT EDIT
```

`web_install_dir` 通过 `include/check_dir.sh` 的既有逻辑确定：优先 Nginx，其次 Tengine，最后 OpenResty 的 `nginx` 子目录。

---

## 3. CLI 设计

```bash
./reverse_proxy.sh add \
  --domain a.example \
  --upstream https://b.example \
  [--host-header upstream|public|custom:<host>] \
  [--no-rewrite] \
  [--cert auto|custom|none] \
  [--email admin@a.example] \
  [--dns dns_ali] \
  [--cert-file /path/fullchain.pem --key-file /path/privkey.pem] \
  [--verify-upstream on|off] \
  [--connect-timeout 10] [--read-timeout 60] \
  [--skip-upstream-check] \
  [--allow-private-upstream] \
  [--force]

./reverse_proxy.sh update --domain a.example [可覆盖字段]
./reverse_proxy.sh delete --domain a.example [--purge-cert]
./reverse_proxy.sh list
./reverse_proxy.sh show --domain a.example
./reverse_proxy.sh test  --domain a.example
```

短选项：`-d`、`-u`、`-h`。

默认值：

| 项 | 默认 |
|---|---|
| `--rewrite` | 开启 |
| `--host-header` | `upstream` |
| `--cert` | `auto` |
| `--verify-upstream` | `on` |
| `--connect-timeout` | `10` 秒 |
| `--read-timeout` | `60` 秒 |
| `--email` | `auto` 模式下交互提示；非交互环境必须提供 |
| `--dns` | 空，使用 HTTP-01 webroot |
| `--force` | 不允许覆盖已有同名 vhost |

`update` 只覆盖显式传入的字段，未传字段沿用元数据。

---

## 4. 上游模型与安全校验

### 4.1 结构化解析

把 upstream 拆为：

```text
upstream_scheme
upstream_host
upstream_port
upstream_path   # MVP 仅允许 /
```

规则：

- 只允许 `http` / `https`
- 禁止 userinfo、query、fragment
- host 只允许域名或 IP
- 默认端口 80 / 443
- 路径必须为 `/`，否则拒绝
- scheme / host 统一转小写
- 去掉末尾多余斜杠

### 4.2 SSRF 防护

默认禁止反代到：

```text
0.0.0.0/8
127.0.0.0/8
172.16.0.0/12
192.168.0.0/16
169.254.0.0/16
100.64.0.0/10
::1
fc00::/7
fe80::/10
```

解析 upstream host 时，对每个 A/AAAA 地址先归一化再分类，任一记录命中即拒绝，除非显式 `--allow-private-upstream`。

#### IPv4-mapped / IPv4-compatible IPv6

不能只做字符串前缀匹配。`::ffff:127.0.0.1`、`::ffff:10.0.0.1` 在字符串层面不命中任何 IPv4 黑名单，但在内核 socket 层会按对应 IPv4 地址处理，是一个实际可用的绕过路径。

归一化步骤：

1. IPv4：直接检查黑名单。
2. IPv6：
   - 转小写，拒绝带 `%zone` 的记录。
   - 如果末尾是点分 IPv4（如 `::ffff:127.0.0.1`），先把该 32 位后缀转换成两个十六进制 group；如果已经是十六进制 group 形式（如 `::ffff:7f00:1`），直接进入下一步。
   - 展开 `::` 压缩，得到完整的 8 组。
   - **IPv4-mapped**：前 5 组为 `0000` 且第 6 组为 `ffff` 时，取第 7、8 组还原成 IPv4，再按 IPv4 黑名单检查。
   - **IPv4-compatible**（已废弃，但一并防御）：前 6 组全为 `0000` 时，同样取第 7、8 组还原成 IPv4 再检查。
   - 再检查 IPv6 本身：`::/128`（未指定）、`::1`、`fc00::/7`、`fe80::/10`。

示例：

| 地址 | 判定 |
|---|---|
| `::ffff:127.0.0.1` | 拒绝 |
| `::ffff:10.0.0.1` | 拒绝 |
| `::ffff:7f00:1` | 拒绝（mapped 的十六进制写法） |
| `::127.0.0.1` | 拒绝（compatible） |
| `fd00::1` | 拒绝 |
| `2606:4700::1111` | 允许 |

实现上用纯 bash 数组完成展开和提取，不引入 perl/python 依赖。

已知残余风险：NAT64（`64:ff9::/96`）、6to4（`2002::/16`）、Teredo（`2001::/32`）也会内嵌 IPv4 地址，但它们不是内核意义上的 IPv4-mapped；DNS 正常不会返回这类记录，MVP 暂不展开，留作后续加固项并写入局限说明。

已知局限：nginx 之后仍会再次解析 DNS，理论上有 DNS rebinding 风险。MVP 不做 IP pinning，文档中明确说明。

### 4.3 连通性检查

添加前用 `curl` 请求一次上游：

- 使用 `--host-header` 指定的 Host
- HTTPS 默认验证证书
- 失败则中止，除非 `--skip-upstream-check`
- 不强制要求 HTTP 200，因为上游可能拦截非浏览器 UA

---

## 5. 证书策略

`PATH_SSL=${web_install_dir}/conf/ssl`，与 `vhost.sh` 保持一致。

### 5.1 `auto`

复用现有 acme.sh：

1. 检查 `~/.acme.sh/acme.sh`；缺失时给出安装方法或复用 `vhost.sh` 的安装逻辑。
2. 先写一个仅含 ACME challenge 的 80 端口 vhost：

   ```nginx
   location ^~ /.well-known/acme-challenge/ {
       root /data/wwwroot/acme/<domain>;
   }
   ```

3. reload nginx。
4. 执行 acme.sh：
   - 默认 HTTP-01 + webroot
   - 指定 `--dns dns_xxx` 时走 DNS-01
5. 安装证书到 `${PATH_SSL}/${domain}.crt` 和 `.key`。
6. 生成最终 vhost，保留 challenge location 供续期使用。
7. reload nginx。
8. 用 `openssl x509 -checkend` 验证证书。
9. reloadcmd 固定为 `${web_install_dir}/sbin/nginx -s reload`。

DNS API 凭据由 acme.sh 自己管理，本脚本不保存密钥。

### 5.2 `custom`

- 校验证书和私钥存在、可读。
- 校验证书与私钥匹配。
- 复制到 `${PATH_SSL}/${domain}.crt` 和 `.key`。
- key 权限设为 `600`。
- 元数据记录来源路径和复制时间。
- 不负责续期；删除时也不自动删除。

### 5.3 `none`

- 只监听 80。
- 明确警告：页面内如有 HTTPS 绝对链接、HSTS、Secure Cookie，可能出现混合内容或登录态问题。

### 5.4 删除时的证书处理

- 默认保留证书。
- `--purge-cert` 删除 `${PATH_SSL}` 下的证书和私钥。
- 如果该域名在 acme.sh 中有续期条目，应同时执行 `acme.sh --remove -d <domain>`，避免续期任务持续报错。

`update --cert auto` 时，即使模式没变，也要检查现有证书是否存在、是否即将过期；缺失或临期则重新签发。

---

## 6. nginx 配置模板

### 6.1 结构

推荐拆成两个 server block。

```nginx
# 80：ACME challenge + 跳转；cert none 时直接反代
server {
    listen 80;
    listen [::]:80;
    server_name __DOMAIN__;

    location ^~ /.well-known/acme-challenge/ {
        root /data/wwwroot/acme/__DOMAIN__;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}

# 443：反代
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    __HTTP2_DIRECTIVE__
    server_name __DOMAIN__;

    ssl_certificate     ${PATH_SSL}/__DOMAIN__.crt;
    ssl_certificate_key ${PATH_SSL}/__DOMAIN__.key;

    access_log /data/wwwlogs/__DOMAIN__.proxy.access.log;
    error_log  /data/wwwlogs/__DOMAIN__.proxy.error.log;

    set $rp_upstream_host "__UPSTREAM_HOST__";
    set $rp_public_host  "__DOMAIN__";
    set $rp_public_scheme "https";

    location / {
        proxy_pass __UPSTREAM_URL__;

        proxy_http_version 1.1;
        proxy_set_header Host __PROXY_HOST__;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Connection "";

        proxy_connect_timeout __CONNECT_TIMEOUT__s;
        proxy_send_timeout    __READ_TIMEOUT__s;
        proxy_read_timeout    __READ_TIMEOUT__s;

        # 仅上游为 https 时生成以下三行
        proxy_ssl_server_name on;
        proxy_ssl_name __UPSTREAM_HOST__;
        proxy_ssl_verify __VERIFY_UPSTREAM__;

        proxy_buffering on;
        proxy_cache off;

        # rewrite 模式启用
        proxy_set_header Accept-Encoding "";
        header_filter_by_lua_file  /data/lnmp/reverse_proxy/lua/rp_header.lua;
        body_filter_by_lua_file   /data/lnmp/reverse_proxy/lua/rp_body.lua;
    }
}
```

`cert none` 时不生成 443 server block，80 的 `location /` 直接做反代。

### 6.2 HTTP/2 语法

沿用 `vhost.sh` 的版本判断：

- nginx >= 1.25.1 / 支持的 OpenResty：使用独立指令 `http2 on;`
- 更旧的 nginx：使用 `listen 443 ssl http2;` 和 `listen [::]:443 ssl http2;`

不能直接假定所有构建都支持 `http2 on;`。

### 6.3 SSL 加固

不要另发明一套弱配置。复用 `vhost.sh` 已有的：

- `ssl_protocols TLSv1.2 TLSv1.3`
- ECDH curve
- 加密套件
- session cache / timeout
- OCSP stapling（证书含 OCSP URI 时）
- 必要的 `ssl_conf_command`

HSTS 默认不强制开启，避免 A 的子域名尚未全部 HTTPS 时造成不可逆影响。如后续需要，再加 `--hsts` 选项。

### 6.4 上游 Host 与 SNI

- `--host-header upstream`：`proxy_set_header Host <B 主机名>`
- `--host-header public`：`proxy_set_header Host $host`
- `--host-header custom:<host>`：写入自定义值，需做字符白名单

SNI 始终使用 B 的主机名：

```nginx
proxy_ssl_server_name on;
proxy_ssl_name <B 主机名>;
```

自定义端口的 Host 是否带端口，MVP 先统一不带端口，必要时后续增加选项。

`proxy_ssl_verify on` 使用构建时的默认证书链。上游使用私有 CA 时，MVP 只能选择 `--verify-upstream off`；`--ca-file` 留待后续版本。

### 6.5 改写变量

```nginx
set $rp_upstream_host "B";
set $rp_upstream_origin "https://B";
set $rp_public_host  "A";
set $rp_public_origin "https://A";
set $rp_public_scheme "https";
set $rp_rewrite_watermark "1048576";   # 1 MiB
set $rp_rewrite_max_bytes "8388608";   # 8 MiB
```

Lua 文件通过这些变量工作，不在 Lua 代码里硬编码域名。

---

## 7. L2 改写设计

### 7.1 `rp_header.lua`

职责：

- 改写 `Location` 中的上游 origin；显式数字端口随 host 一起消费，避免泄漏到 A。
- 改写 `Set-Cookie` 中已有的 `Domain=B`；比较时忽略端口和前导点。
- 不主动给 `__Host-` Cookie 添加 Domain。
- 如果响应是文本类型且未被压缩，清除 `Content-Length`；非文本或 `Content-Encoding` 非空时不清除，直接 passthrough。
- 不处理 `Path` 前缀重写，因为 MVP 不支持上游子路径。

要点：

- `ngx.header.content_length = nil` 用于清除上游长度；如当前模块版本行为不一致，回退到 `proxy_hide_header Content-Length`。
- `Set-Cookie` 可能是字符串或数组，统一按数组处理。
- 只替换精确等于上游 host 的 Domain，大小写不敏感；带端口或前导点的值按 host 部分比较。
- Location / body 替换都有 host 边界检查，不会把 `B.evil.com` 当成 `B`。

### 7.2 `rp_body.lua`

策略：**有界缓冲 + 中间水位冲刷**。既不在内存里缓冲整页，也不逐 chunk 盲改导致跨块 URL 被截断。

#### 阈值

| 变量 | 默认 | 作用 |
|---|---:|---|
| `$rp_rewrite_watermark` | 1 MiB | 已缓冲数据达到该水位后，冲刷一段已改写的安全前缀 |
| `$rp_rewrite_max_bytes` | 8 MiB | 累计输入超过后，冲刷当前缓冲并进入 passthrough，后续字节原样输出 |
| overlap | 由 upstream origin 推导 | 最长可能匹配长度，用于计算“危险窗口”和防止冲刷边界切断 URL |

`overlap = #upstream_origin + 16`，并设最小值兜底。它表示一个待替换 URL 的最大可能长度。

#### 算法

1. 在 `ngx.ctx` 中维护：
   - `buf`：尚未冲刷的文本尾部
   - `total`：已处理的输入字节数
   - `skip`：是否已进入 passthrough
2. 每个 chunk：
   - `skip` 为真：原样输出该 chunk。
   - 否则追加到 `buf`，累加 `total`。
   - 若 `total > max_bytes`：对当前 `buf` 做一次性改写并输出，然后 `skip = true`，后续 chunk 原样输出。
   - 否则若 `#buf >= watermark + 2 * overlap`，尝试安全冲刷：
     1. 初始冲刷点 `cut = #buf - overlap`。
     2. 在危险窗口 `(cut - overlap, cut]` 内搜索可能的匹配起点：`https://`、`http://`、`//`。取最早的一个 `p`。
     3. 如果找到 `p`：把 `cut` 退到 `p - 1`，重复第 2 步；如果 `p - 1 < watermark`，本轮不冲刷，继续攒数据。
     4. 如果找不到危险起点且 `cut >= watermark`：对 `buf[1 .. cut]` 做改写并输出，保留 `buf[cut + 1 ..]` 进入下一轮。
   - 未达到冲刷条件时设置 `ngx.arg[1] = ""`，继续攒数据。
3. eof：
   - 先把 eof chunk 拼接到 `buf`；
   - 如果未 `skip`，对剩余 `buf` 做最后一次改写并输出；
   - 如果已 `skip`，eof chunk 本身必须原样输出，不能丢弃。

#### 为什么扫描危险窗口

固定保留 `2 * overlap` 并不能证明边界安全：一个 URL 可能正好从冲刷前缀的最后几个字节开始，前半被改写、后半被保留，造成替换断裂或重复。因此冲刷前必须检查 `(cut - overlap, cut]`：这里是所有“起点已冲刷但结尾可能越界”的位置。把 `cut` 退到这些潜在起点之前，就能保证已冲刷前缀里的匹配都完整结束，跨边界匹配留给后续轮次处理。

危险窗口扫描是保守的：任何 `//` 都会被视为潜在起点，因此可能比理论最小保留区多留一点数据；安全优先于冲刷进度。

分段输出的拼接结果必须与对完整 body 做一次 `gsub` 的结果一致（未超过 `max_bytes` 时）。

#### 行为边界

- 只处理：
  - `text/*`
  - `application/javascript`
  - `application/json`
  - `application/xml`
- 检测 `Content-Encoding`，有压缩则整个响应 passthrough，不做体重写。
- 超过 `max_bytes` 后进入 passthrough；已改写部分和未改写部分都会完整输出，不允许丢尾部。
- 替换：
  - `https://B[:port]`
  - `http://B[:port]`
  - `//B[:port]`

  显式数字端口随 host 一起消费；匹配要求后续字符不是 host 名字符，句末 `.` 只在后面不再跟域名标签时视为边界。
- 保留路径、query、锚点。
- 不处理 `https:\/\/B`、`https%3A%2F%2FB` 等编码变体，除非后续增加显式选项。

#### 实现注意

- 把纯字符串替换和缓冲状态机放进 `rp_rewrite.lua`，`rp_body.lua` 只负责 `ngx.arg` / `ngx.ctx` 与 `ngx.var` 胶水，便于用 luajit 直接测试。
- `ngx.ctx` 用于承载 buffer 和状态。
- `ngx.arg[2]` 为 eof 时，`ngx.arg[1]` 可能非空，必须先拼接再处理。
- 不得手动把 `ngx.arg[2]` 设为 `true`。
- 需要在实现阶段用真实响应验证：分块、eof 非空、水位冲刷、超长 passthrough。

### 7.3 为什么不用 sub_filter

当前 nginx 编译参数只有：

```text
--add-module=../lua-nginx-module
--add-module=../ngx_brotli
```

没有 `--with-http_sub_module`。即使编译了 `sub_filter`，它也只能改 body，无法统一处理 `Set-Cookie` 和 `Location`。Lua 方案与现有技术栈一致。

---

## 8. 安全边界

- 仅 root 可执行。
- 全程 `flock`，避免并发修改。
- 配置原子写入：临时文件 + `mv`。
- 覆盖前备份旧配置和元数据，保留最近 10 份。
- 每次生成后 `nginx -t`，失败回滚。
- reload 后检查进程存活。
- upstream 只能来自管理员输入，运行时不可修改。
- 默认拒绝私网 upstream。
- 自定义 Host 头做字符白名单，防止换行注入。
- 模板用占位符替换，不把用户输入直接拼进 shell heredoc。
- 元数据文件权限 `600`，证书 key `600`。
- 不是开放代理：每个 server block 固定一个上游。
- Lua 文件由脚本安装，不允许用户传入任意 Lua 代码。

---

## 9. 管理语义

### 9.1 add

1. 检查 metadata 不存在。
2. 检查目标 vhost 是否存在；存在且非本脚本管理时拒绝，除非 `--force`。
3. 校验 domain / upstream。
4. SSRF 检查。
5. 上游连通性检查。
6. 安装 Lua 文件到 `/data/lnmp/reverse_proxy/lua/`。
7. 证书处理。
8. 渲染配置。
9. `nginx -t`。
10. 写配置和 metadata。
11. reload。
12. 记录操作日志。

### 9.2 update

- 合并显式传入字段。
- upstream 变化时重新做 SSRF / 连通性检查。
- cert 模式变化时重新处理证书。
- 重新渲染、校验、reload。

### 9.3 delete

- 只允许删除带本脚本标记的配置。
- 删除 vhost 文件和 metadata。
- 默认保留证书。
- `--purge-cert` 才删除证书，并清理 acme.sh 续期条目。
- reload。

### 9.4 list / show / test

- `list`：domain、upstream、rewrite、cert、更新时间。
- `show`：完整 metadata + 当前配置 + 证书到期时间。
- `test`：
  - `nginx -t`
  - 本机回环请求 A
  - rewrite 模式下检查响应头和 body 中是否仍含 B
  - 输出诊断报告

---

## 10. 升级与兼容

- `upgrade_web.sh` 重建 nginx 时已经包含 `lua-nginx-module`，Lua 反代配置不受影响。
- Lua 文件放 `/data` 持久目录，不依赖 `conf/` 是否被重置。
- 启动时检测：
  - `web_install_dir`
  - `nginx` 二进制
  - `conf/nginx.conf`

### 10.1 rewrite 能力探测（不把 `nginx -V` 当判据）

只 grep `nginx -V` 会把“编译参数里存在”误当成“当前能加载”，生产环境可能因此生成一份必然启动失败的 rewrite 配置。改写功能必须用真实的 nginx 解析结果来判定。

探测流程：

1. 生成一个临时最小 `nginx.conf`，包含：

   ```nginx
   header_filter_by_lua_file <tmp>/rp_probe_header.lua;
   body_filter_by_lua_file  <tmp>/rp_probe_body.lua;
   ```

   先不加任何 `load_module`，执行 `${web_install_dir}/sbin/nginx -t -p <tmp> -c nginx.conf`。成功说明模块已静态编译进二进制（或通过 `nginx -g` 在启动参数里加载），rewrite 可用。
2. 若不成功，查找动态模块候选：

   - `${web_install_dir}/modules/ngx_http_lua_module.so`
   - `nginx -V` 输出里的 `--modules-path=<path>` 下的 `ngx_http_lua_module.so`
   - `/usr/lib/nginx/modules/ngx_http_lua_module.so`
   - `/usr/lib64/nginx/modules/ngx_http_lua_module.so`

   对每个存在的 `.so`，在临时配置顶部加入 `load_module "<path>";` 后再 `nginx -t`。任一成功即认为动态模块可用，并记录该路径。
3. 全部失败则 rewrite 不可用。

动态模块可用但全局配置尚未 `load_module` 时，脚本才能在 `${web_install_dir}/conf/nginx.conf` 的主上下文（`events` 之前）插入：

```nginx
load_module "/path/to/ngx_http_lua_module.so";
```

该操作必须：

- 先检查 `conf/` 下是否已有 `ngx_http_lua_module` 相关 `load_module`，避免重复；
- 备份 `nginx.conf`；
- `nginx -t` 通过后才写入并重载；
- 失败则恢复备份并中止；
- 无法安全修改全局配置时直接拒绝 rewrite，不能留下半可用状态。

`nginx -V` 只用于：获取版本（HTTP/2 语法）、`--modules-path`、确认二进制位置；不作为 Lua 支持的最终判据。

- 活跃引擎是 Tengine 或探测确认没有可用 Lua 模块时：
  - `--no-rewrite` 可以工作
  - 默认 rewrite / `--rewrite` 直接拒绝并输出探测结论
- `vhost.sh` 创建同名站点继续拒绝；本脚本也不覆盖非本脚本管理的 vhost。
- acme.sh 的 reloadcmd 使用当前检测到的绝对路径；切换 web 引擎后应重新 `update` 或重新签发。

---

## 11. 测试计划

### 11.1 离线单元测试

新 `tools/test_reverse_proxy.sh`，source `include/reverse_proxy.sh`：

- domain 合法性
- upstream 解析与归一化
- 非法 scheme / userinfo / 子路径拒绝
- 私网 IP 拒绝
- 模板渲染关键字段
- metadata 读写
- 备份 / 回滚路径
- `nginx -t` mock

另增 `tools/test_reverse_proxy_lua.lua`（有 `lua`/`luajit` 时运行，否则跳过），直接测试纯 Lua 改写模块：

- 一次性 `gsub` 与分段缓冲结果一致
- URL 在任意 chunk 边界被拆开
- eof chunk 非空且携带完整/部分 URL
- eof 为空但前面缓冲仍有内容
- 危险窗口内存在潜在匹配起点时，冲刷点回退且不切断匹配
- 多个潜在起点连续出现，重复回退直到安全
- 水位冲刷恰好发生在 URL 中间时不切断匹配
- eof chunk 非空且本身包含完整/部分 URL
- 超过 `max_bytes` 后进入 passthrough，已改写部分与原始尾部都完整输出
- 空 chunk、连续空 chunk、eof 为空
- 输出拼接后与完整 body 一次改写结果相同（未超 max 时）

接入现有：

```text
tools/lint/static_checks.sh
shellcheck -S warning
```

### 11.2 集成测试

容器内起本地 upstream，验证：

- L1 反代
- L2 头改写
- L2 体改写
- `cert none` / `custom` 路径
- update upstream
- delete
- 故意渲染错误配置，验证 `nginx -t` 回滚
- body filter 的分块、eof、超长响应
- 上游以 1 字节、7 字节、64 字节等非常规分块发送，URL 被拆散
- 人为让冲刷边界落在 URL 中间或潜在匹配起点附近，验证危险窗口回退
- eof chunk 本身包含 URL、URL 尾部或为空
- 响应体跨过 watermark 和 max_bytes，验证无内存失控、无尾部丢失
- `Content-Length` 被清除后以 chunked 输出，长度可校验
- `Location`、`Set-Cookie Domain` 改写
- Lua 能力探测矩阵：
  - 静态编译模块
  - 动态模块且全局配置已 `load_module`
  - 动态模块存在但全局未加载，自动插入后可用
  - `.so` 缺失或 ABI 不匹配，rewrite 被拒绝
  - Tengine / 无 Lua，rewrite 被拒绝

### 11.3 手工验收

```bash
./reverse_proxy.sh add -d a.example -u https://b.example --cert none
curl -H 'Host: a.example' http://127.0.0.1/ | grep -i 'b.example'
./reverse_proxy.sh test -d a.example
./reverse_proxy.sh delete -d a.example
```

---

## 12. 实施顺序

1. 函数库 + CLI 骨架 + metadata + L1 + list/show/delete。
2. `nginx -t` / reload / 备份 / 回滚。
3. 证书策略。
4. Lua 头改写。
5. Lua 体改写。
6. SSRF / 安全校验完善。
7. 离线测试、静态检查、容器 smoke。
8. 文档和 README。

---

## 13. 整体检查结论

对照仓库现状复查后的修订点：

1. **`web_install_dir` 来源**：不自己猜路径，复用 `include/check_dir.sh` 的逻辑，兼容 Nginx / Tengine / OpenResty。
2. **证书目录**：`PATH_SSL=${web_install_dir}/conf/ssl`，与 `vhost.sh` 一致。
3. **HTTP/2 语法**：不能固定写 `http2 on;`，需要按 nginx/OpenResty 版本选择。
4. **SSL 加固**：复用 `vhost.sh` 已有策略，不降低加密强度；HSTS 默认不强制。
5. **Lua 能力探测**：rewrite 不能用 `nginx -V` 判断；必须用 `nginx -t` 实际探测静态指令和动态 `load_module`。动态模块可用但未加载时，脚本负责安全插入 `load_module`（备份 + 测试 + 回滚），否则拒绝 rewrite。
6. **acme.sh 删除**：`--purge-cert` 要一并清理 acme.sh 续期条目，否则续期 cron 会持续报错。
7. **Content-Length**：body 改写会改变长度，必须在 header filter 中清除；实现阶段要验证当前 lua-nginx-module 的行为。
8. **body filter 语义**：`ngx.arg[1] = ""` 与 eof 处理需要真实响应验证，不能只靠离线断言；缓冲策略改为水位冲刷，冲刷前扫描 `(cut - overlap, cut]` 危险窗口并回退，保证跨块 URL 不被截断且不丢尾部。
9. **DNS rebinding**：MVP 不做 upstream IP pinning，需在局限中声明。
10. **Host 端口**：自定义端口上游的 Host 头 MVP 统一不带端口，必要时后续再加选项。
11. **证书续期 reloadcmd**：使用当前检测到的绝对路径；切换 web 引擎后需要重新应用。
12. **访问控制**：MVP 不做，不在方案中预留未经验证的复杂语义。
13. **HTTPS 指令条件化**：`proxy_ssl_*` 只在上游为 https 时生成，避免对 HTTP 上游产生无意义或版本相关配置。
14. **证书续期检查**：`update --cert auto` 必须检查证书存在性和有效期，不能只在模式变化时才处理。
15. **IPv4-mapped IPv6**：SSRF 检查必须先把 `::ffff:a.b.c.d` / `::ffff:hex:hex` 解包成 IPv4 再查黑名单；同时覆盖已废弃的 IPv4-compatible `::a.b.c.d`。纯 bash 实现，不引入 perl/python。
16. **未指定地址**：除私网段外，同时拒绝 `0.0.0.0/8` 和 `::/128`；否则 `0.0.0.0` 这类记录在部分系统上仍可能连到本机。
17. **体重写内存控制**：用中间水位冲刷替代整页缓冲；冲刷前扫描 `(cut - overlap, cut]` 危险窗口并回退到潜在匹配起点之前，防止跨块 URL 被截断；eof 非空 chunk 必须拼接后再输出，并对此设计专门测试。

以上修订已并入本文件。

## 14. 实现期修复记录

- `update` 未传 `--email` / `--dns_api` / `--host-header` 时从元数据补齐，不再覆盖为空；渲染使用补齐后的 custom Host。
- DNS-01 模式失败或成功都不删除现网 vhost；HTTP-01 的 bootstrap 失败会恢复备份。
- `update` / `delete` / `show` / `test` 先做 domain 合法性校验，拒绝路径穿越。
- HTTPS 上游默认配置 `proxy_ssl_trusted_certificate`（系统 CA 包）和 `proxy_ssl_verify_depth 2`。
- Location / Set-Cookie / body 替换改为有边界、可消费端口的匹配，避免子域误伤与端口泄漏。
- 连通性检查改为失败即中止（除非 `--skip-upstream-check`），并使用 `--host-header` 解析出的实际 Host。
- `update` 回滚将 verify 值归一化为 nginx 的 `on`/`off`；`update` 校验 timeout。
- `rp_body.lua` 不再每个 chunk 重新加载模块，改由 header filter 每请求加载一次并放入 `ngx.ctx`。
- 自定义证书改为比较公钥材料，支持 RSA / ECDSA / Ed25519。
- 非交互 `--cert auto` 强制要求 `--email`。
- 备份按 label 保留最近 10 份（`RP_BACKUP_KEEP` 可覆盖）。
- Cookie Domain 同时处理前导点和末尾根点。
- `test` 使用 `--resolve` 让 HTTPS 探测带正确 SNI。
- rewrite 模式显式 `proxy_redirect off`，避免与 Lua 双改 Location；no-rewrite 保留 nginx 默认行为。
- header filter 同时改写 `Refresh`、`Content-Location`、`Link`；body 重写支持省略上游端口（如上游 `:8080`，正文为 `//b.example.com/x`）。
- body 覆盖类型增加 `application/xhtml+xml`、`application/ld+json`。
- OpenResty 版本字符串按 `openresty/` 解析，现代 OpenResty 使用 `http2 on;`。
- reload 存活检查改为读取配置中的 master PID 文件，不再使用 `pgrep -f`。
