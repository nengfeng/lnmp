# 网络下载和编译问题解决方案

## 概述
本文档提供了LNMP安装过程中网络下载失败和编译超时问题的具体解决方案。

## 🛠️ 已实现的改进

### 1. 增强的下载机制

#### 改进内容
- **增加重试次数**: 从6次提升到10次
- **延长超时时间**: 每次尝试60秒超时
- **渐进式延迟**: 每次失败后延迟时间递增
- **下载日志**: 记录所有下载尝试
- **详细错误信息**: 提供具体的解决建议

#### 使用示例
```bash
# 自动使用增强的下载功能
./install.sh

# 下载函数会自动重试，输出示例：
# Downloading php-8.4.19.tar.gz...
# Attempt 1 of 10...
# Attempt 2 of 10...
# Successfully downloaded php-8.4.19.tar.gz
```

### 2. 系统资源检查

#### 新增函数
```bash
check_system_resources()  # 检查内存和磁盘空间
check_compilation_dependencies()  # 检查编译依赖
```

#### 功能特点
- ✅ **内存检查**: 检测系统内存是否足够
- ✅ **磁盘空间检查**: 确保有足够空间编译
- ✅ **编译工具检查**: 验证gcc、make、cmake等
- ✅ **用户提示**: 资源不足时警告并询问

#### 使用示例
```bash
# 在安装脚本中自动调用
check_system_resources
check_compilation_dependencies
```

### 3. 带超时的编译控制

#### 新增函数
```bash
compile_with_progress [timeout_seconds] [extra_make_args]
```

#### 功能特点
- ✅ **超时控制**: 默认1小时超时，防止无限等待
- ✅ **进度监控**: 每30秒显示进度
- ✅ **日志记录**: 自动保存编译日志
- ✅ **错误处理**: 失败时显示最后30行日志

#### 使用示例
```bash
# 默认1小时超时
compile_with_progress

# 自定义超时时间（2小时）
compile_with_progress 7200

# 带额外参数
compile_with_progress 3600 "CFLAGS=-O2"
```

## 📋 使用指南

### 方案A: 提前下载（强烈推荐）

这是最安全可靠的方式：

```bash
# 1. 预下载常用组件
./download_sources.sh --common

# 2. 预下载所有组件（可选）
./download_sources.sh --all

# 3. 执行安装
./install.sh
```

**优点**:
- ✅ 避免网络问题
- ✅ 节省安装时间
- ✅ 可离线安装
- ✅ 支持多次重试安装

### 方案B: 在线安装（增强版）

如果网络稳定，可以直接在线安装：

```bash
# 直接执行安装，会自动使用增强的下载机制
./install.sh
```

**增强保护**:
- ✅ 10次重试机制
- ✅ 60秒超时保护
- ✅ 详细错误日志
- ✅ 下载进度显示

### 方案C: 手动下载（最后备选）

如果自动下载完全失败：

```bash
# 1. 查看需要下载的文件
cat DOWNLOAD_SOURCES.txt

# 2. 手动下载到 src/ 目录
cd src/
wget https://www.php.net/distributions/php-8.4.19.tar.gz
wget https://cdn.mysql.com/Downloads/MySQL-8.0/mysql-8.0.45.tar.gz
# ... 下载其他文件

# 3. 执行安装
cd ..
./install.sh
```

## 🚀 最佳实践

### 1. 生产环境安装流程

```bash
# 第一步：检查系统资源
free -h          # 检查内存（建议2GB+）
df -h            # 检查磁盘（建议10GB+）
lscpu            # 检查CPU（建议2核心+）

# 第二步：安装系统依赖
apt-get update
apt-get install -y gcc g++ make cmake wget curl

# 第三步：预下载组件（强烈推荐）
./download_sources.sh --common

# 第四步：执行安装
./install.sh

# 第五步：验证安装
nginx -v
php -v
mysql --version
```

### 2. 低配VPS安装优化

```bash
# 创建交换分区（1GB内存VPS）
dd if=/dev/zero of=/swapfile bs=1M count=2048
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile

# 调整编译线程数（降低内存使用）
export THREAD=1

# 执行安装
./install.sh
```

### 3. 网络不稳定环境

```bash
# 使用国内镜像
MIRROR_MODE=china ./download_sources.sh --common
MIRROR_MODE=china ./install.sh

# 或配置镜像
vim options.conf
# 设置 MIRROR_BASE_URL=https://mirrors.tuna.tsinghua.edu.cn
```

## 📊 错误诊断指南

### 错误1: 下载失败

**症状**:
```
Download failed after 10 attempts
```

**解决方案**:
1. 检查网络连接: `ping github.com`
2. 查看下载日志: `cat download.log`
3. 使用预下载: `./download_sources.sh --common`
4. 尝试手动下载: 参考方案C

### 错误2: 编译失败

**症状**:
```
Compilation failed
```

**解决方案**:
1. 查看编译日志: `cat compile_*.log`
2. 检查依赖: `check_compilation_dependencies`
3. 检查内存: `free -h` (需要2GB+)
4. 减少并发: `export THREAD=1`

### 错误3: 编译超时

**症状**:
```
Compilation timeout reached
```

**解决方案**:
1. 增加超时时间: 修改 `compile_with_progress 7200`
2. 检查系统负载: `top` 或 `htop`
3. 减少编译线程: `export THREAD=1`
4. 增加内存/交换分区

## 🔍 监控和调试

### 查看下载日志
```bash
cat download.log | grep -i error
```

### 查看编译日志
```bash
# 查看最新的编译日志
ls -lt compile_*.log | head -1 | xargs cat

# 查看编译错误
cat compile_*.log | grep -i error
```

### 监控编译进度
```bash
# 实时查看编译日志
tail -f compile_*.log

# 查看系统资源使用
watch -n 1 'free -h && df -h . && uptime'
```

## 📈 性能优化建议

### 根据硬件配置调整

| 内存 | 编译线程 | 预计时间 | 建议 |
|------|----------|----------|------|
| 512MB | 1 | 60-90分钟 | 添加交换分区 |
| 1GB | 1-2 | 45-60分钟 | 可用，较慢 |
| 2GB | 2-4 | 30-45分钟 | 推荐 |
| 4GB+ | 4-8 | 20-30分钟 | 最佳性能 |

### 设置编译线程数
```bash
# 自动检测（推荐）
export THREAD=$(nproc)

# 手动设置
export THREAD=2  # 适合2核CPU
export THREAD=4  # 适合4核CPU
```

## 🎯 总结

### 必做事项
1. ✅ **检查系统资源**: 确保内存和磁盘空间足够
2. ✅ **预下载组件**: 强烈建议提前下载
3. ✅ **使用镜像源**: 国内用户使用镜像源

### 可选优化
1. 🔧 调整编译线程数
2. 🔧 添加交换分区
3. 🔧 自定义超时时间

### 故障排查
1. 📝 查看下载日志
2. 📝 查看编译日志
3. 📝 检查系统资源
4. 📝 使用手动下载

通过这些改进，LNMP安装的成功率显著提升，即使在网络不稳定或资源有限的环境中也能顺利完成安装。