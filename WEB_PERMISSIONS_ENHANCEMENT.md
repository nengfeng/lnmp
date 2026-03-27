# Web目录权限安全增强

## 概述
本文档描述了LNMP安装脚本中Web目录权限的安全改进。

## 已完成的修改

### 1. 安装脚本权限增强 (`install.sh`)
**文件**: `install.sh` (第403-410行)

**修改前**:
```bash
# Set /data to 755 to allow www user access (for wwwroot and wwwlogs)
[ -d /data ] && chmod 755 /data
```

**修改后**:
```bash
# Set improved permissions for /data to enhance security
setup_web_directory_permissions
```

### 2. 新增安全函数 (`common.sh`)
**文件**: `include/common.sh` (第674-710行)

新增 `setup_web_directory_permissions()` 函数，功能包括：
- 保持 `/data` 目录为755权限（兼容性考虑）
- 设置网站根目录为750权限（更严格的安全控制）
- 设置文件为640权限（组只读）
- 确保正确的所有者为 `www:www` 用户组
- 日志目录设置为755权限（nginx/php-fpm需要）

### 3. 虚拟主机权限更新 (`vhost.sh`)
**文件**: `vhost.sh` (第440-450行)

**修改前**:
```bash
echo "set permissions of Virtual Host directory......"
chown -R ${run_user}:${run_group} ${vhostdir}
```

**修改后**:
```bash
echo "Set secure permissions for Virtual Host directory......"
# Set secure permissions: 750 for directories, 640 for files
chmod 750 ${vhostdir}
chown ${run_user}:${run_group} ${vhostdir}

# Ensure proper permissions for subdirectories and files
if [ -d "${vhostdir}" ]; then
  find ${vhostdir} -type d -exec chmod 750 {} \; 2>/dev/null
  find ${vhostdir} -type f -exec chmod 640 {} \; 2>/dev/null
fi
```

### 4. 演示脚本权限更新 (`demo.sh`)
**文件**: `include/demo.sh` (第79-84行)

增强为使用新的安全权限模型。

### 5. phpMyAdmin权限更新 (新安装)
**文件**: `include/phpmyadmin.sh` (第16-24行)

确保正确权限的同时保持功能完整性。

### 6. phpMyAdmin升级权限更新
**文件**: `include/upgrade_phpmyadmin.sh` (第44-52行)

增强升级脚本以使用安全权限。

### 7. Xdebug Web目录权限更新
**文件**: `include/pecl_xdebug.sh` (第23-31行)

为Xdebug分析工具的安全化webgrind目录权限。

## 安全效益

### 修改前 (安全性较低)
- 网站目录: 755 (其他用户可以列出目录内容)
- 文件: 各种权限不一致
- 风险: 其他系统用户可能访问敏感的Web文件

### 修改后 (更安全)
- 网站根目录: 750 (其他用户无法访问)
- 网站文件: 640 (其他用户无法读取)
- 日志目录: 755 (保持nginx/php-fpm访问需要)
- phpMyAdmin: 755 (保持Web功能需要)

## 权限矩阵

| 目录/文件类型 | 原权限 | 新权限 | 原因 |
|---------------|--------|--------|------|
| `/data` | 755 | 755 | 保持兼容性 |
| 网站根目录 | 755 | 750 | 防止其他用户访问 |
| 网站文件 | 不一致 | 640 | 防止其他用户读取 |
| 日志目录 | 755 | 755 | nginx/php-fpm需要 |
| phpMyAdmin | 755 | 755 | Web功能需要 |
| 虚拟主机 | 755 | 750 | 增强安全性 |
| 演示目录 | 755 | 755 | nginx访问需要 |
| Xdebug webgrind | 755 | 755 | Web访问需要 |

## 测试

已创建测试脚本验证新权限:
```bash
./test_permissions.sh
```

该脚本创建测试目录并应用新的权限方案，然后验证结果。

## 兼容性说明

- 这些修改向后兼容
- 现有安装不受影响，除非重新安装
- 修改增强了安全性而不破坏功能
- nginx和php-fpm将继续正常工作

## 回滚方案

如果遇到问题，可以通过以下方式恢复旧的权限方案：
1. 恢复 `install.sh` 中的修改
2. 从 `include/common.sh` 中移除 `setup_web_directory_permissions()` 函数
3. 恢复 `vhost.sh`、`include/demo.sh` 和 `include/phpmyadmin.sh` 中的修改

## 安全考虑

这些改进解决了以下安全问题：
1. **目录遍历**: 其他用户无法列出Web目录内容
2. **文件访问**: 其他用户无法读取敏感的Web文件
3. **信息泄露**: 减少了未经授权访问的攻击面
4. **权限提升**: 限制Web文件访问减少了潜在的攻击向量

修改遵循最小权限原则，同时保持Web服务器堆栈的必要功能。