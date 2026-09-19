# PGP 公钥（用于验证下载的源码签名）

本目录存放上游项目的 PGP 公钥，供两条下载路径使用：

- 安装路径：`install.sh` 在 `checkDownload` 之前执行 `gpg --import keys/*.asc`，
  供 `verify_pgp_signature`（include/check_download.sh）使用；
- 预下载路径：`download_sources.sh` 的 asc 校验分支同样导入本目录并强制校验
  （坏签名 / 无法验证 / 钥匙缺失均判该组件失败）。

覆盖 Nginx / OpenResty / Curl / libsodium 的源码签名。

**这些 fingerprint 必须与上游官网公布的完全一致**——一旦固化错公钥，等于主动
信任错误来源，比「不验证」更危险。上游 rotate 公钥时，按下面的「更新」流程做。

## 公钥清单

| 文件 | 签名者 | Fingerprint | 上游来源 |
|---|---|---|---|
| `nginx.skandaurov.asc` | Sergey Kandaurov | `D6786CE303D9A9022998DC6CC8464D549AF75C0A` | https://nginx.org/keys/pluknet.key |
| `openresty.agentzh.asc` | Yichun Zhang (agentzh) | `25451EB088460026195BD62CB550E09EA0E98066` | https://openresty.org/en/download.html（key id A0E98066）|
| `curl.stenberg.asc` | Daniel Stenberg | `27EDEAF22F3ABCEB50DB9A125CC908FDB71E12C2` | https://curl.se/docs/verify.html |
| `libsodium.denis.asc` | Frank Denis (jedisct1) | `54A2B8892CC3D6A597B92B6C210627AABA709FE1` | https://download.pureftpd.org/public_keys/jedi.gpg.asc |

注：
- `curl.stenberg.asc` 含 3 个历史 key（dsa1024 `914C53…`、rsa2048 `4461EA…`、
  rsa2048 `27EDEA…`），当前 curl release 用最后一个 `27EDEA…`。
- **nginx 签名者已变更**：2024 年 Maxim Dounin 离开 nginx（去维护 freenginx），
  源码签名改用 Sergey Kandaurov（`nginx.org/keys/mdounin.key` 已下线）。
- `libsodium` 已迁移到 Minisign，但 `.sig`（PGP）仍保留提供，故继续用 PGP。

## 验证方法

```bash
gpg --show-keys keys/<file>.asc    # 比对上面表中的 fingerprint
```

## 更新流程（上游 rotate 公钥时）

1. 从上游官网/keyserver 获取新公钥，并**与上游官网公布的 fingerprint 交叉验证**。
2. 用 `gpg --show-keys` 确认 fingerprint 与官方一致。
3. 替换本目录对应文件，更新上表。
4. 同步更新 include/check_download.sh 里对应组件的签名 URL（若签名 URL 也变了）。
