# MySQL 参数调优说明

本文档说明 LNMP 一键安装脚本在不同服务器场景下的 MySQL 参数配置策略。

## 场景划分

| 场景 | 标识 | 适用环境 |
|------|------|---------|
| VPS | vps | 资源有限的虚拟专用服务器（通常 1-4GB 内存） |
| 独立服务器 | dedicated | 资源充裕的独立服务器（通常 8GB+ 内存） |

---

## 参数配置对比

### 1. 连接相关参数

| 参数 | VPS | 独立服务器 | 说明 |
|------|-----|-----------|------|
| `max_connections` | min(100, Mem/8) | min(500, Mem/4) | 最大连接数。VPS 资源有限，过多连接会耗尽内存；独立服务器可支持更多并发。 |
| `max_connect_errors` | 100 | 1000 | 最大连接错误数。独立服务器可放宽限制，避免合法用户被误封。 |
| `back_log` | 150 | 300 | 连接请求队列深度。独立服务器预期更高并发，需要更大的队列。 |
| `thread_cache_size` | 8-16 | 32-64 | 线程缓存大小。独立服务器连接频繁，缓存更多线程减少创建开销。 |

### 2. 缓冲区参数（每连接分配）

| 参数 | VPS | 独立服务器 | 说明 |
|------|-----|-----------|------|
| `sort_buffer_size` | 512K | 2M | 排序缓冲区。VPS 使用较小值避免内存耗尽。每连接分配，100连接 × 512K = 50MB，100连接 × 2M = 200MB。 |
| `join_buffer_size` | 512K | 2M | 连接缓冲区。同上，VPS 保守配置。无索引连接时使用，可多次分配。 |
| `read_buffer_size` | 128K | 1M | 顺序读缓冲区。VPS 使用更小的缓冲区。 |
| `read_rnd_buffer_size` | 256K | 1M | 随机读缓冲区。VPS 保守配置。 |

**重要**: 这些缓冲区是每连接分配的，设置过大会导致内存快速耗尽。
- VPS 场景: 每连接约 1.5MB，100连接 ≈ 150MB
- 独立服务器: 每连接约 6MB，500连接 ≈ 3GB

### 3. InnoDB 参数

| 参数 | VPS | 独立服务器 | 说明 |
|------|-----|-----------|------|
| `innodb_buffer_pool_size` | Mem×0.5 | Mem×0.7 | InnoDB 缓冲池，最重要的性能参数。VPS 需要预留内存给系统和其他服务；独立服务器可分配更多给数据库。 |
| `innodb_buffer_pool_instances` | 1 | 2-8 | 缓冲池实例数。多个实例可减少锁竞争，大内存时有效。一般每 1GB 设一个实例。 |
| `innodb_log_file_size` | 32M | 128M-256M | 重做日志文件大小。独立服务器事务量大，需要更大的日志文件减少检查点频率。 |
| `innodb_log_buffer_size` | 2M | 8M | 日志缓冲区。独立服务器事务更多，需要更大缓冲区。 |
| `innodb_flush_method` | O_DIRECT | O_DIRECT | 避免操作系统缓存双重缓冲，两种场景都推荐。 |
| `innodb_flush_log_at_trx_commit` | 2 | 1 | 日志刷写策略。VPS 追求性能，允许丢失1秒数据；独立服务器追求数据安全，每次事务刷写。 |
| `innodb_io_capacity` | 200 | 1000-2000 | IO 容量估算。VPS 通常使用普通存储；独立服务器可能有 SSD 或 RAID。 |
| `innodb_io_capacity_max` | 400 | 2000-4000 | 最大 IO 容量。 |
| `innodb_open_files` | 500 | 2000 | InnoDB 可打开的文件数。独立服务器表更多，需要更大限制。 |

### 4. MyISAM 参数

| 参数 | VPS | 独立服务器 | 说明 |
|------|-----|-----------|------|
| `key_buffer_size` | Mem×0.05 | Mem×0.1 或 64M-256M | MyISAM 索引缓存。MyISAM 较少使用，但需配置合理值。 |
| `myisam_sort_buffer_size` | 8M | 64M | MyISAM 修复/排序缓冲区。独立服务器大表可能需要更多。 |

### 5. 临时表参数

| 参数 | VPS | 独立服务器 | 说明 |
|------|-----|-----------|------|
| `tmp_table_size` | 16M | 64M | 内存临时表最大大小。独立服务器可允许更大的内存临时表。 |
| `max_heap_table_size` | 16M | 64M | MEMORY 表最大大小。需与 tmp_table_size 一致。 |

### 6. 查询缓存（MariaDB）

| 参数 | VPS | 独立服务器 | 说明 |
|------|-----|-----------|------|
| `query_cache_type` | 0 或 1 | 0 | 查询缓存开关。高并发场景建议关闭，缓存锁成为瓶颈。MySQL 8.0 已移除此功能。 |
| `query_cache_size` | 0 或 8M | 0 | 查询缓存大小。VPS 低并发时可开启小缓存；独立服务器高并发建议关闭。 |

### 7. 其他参数

| 参数 | VPS | 独立服务器 | 说明 |
|------|-----|-----------|------|
| `table_open_cache` | 400 | 2000 | 表缓存大小。独立服务器更多表访问，需要更大缓存。 |
| `table_definition_cache` | 400 | 2000 | 表定义缓存。同上。 |
| `open_files_limit` | 65535 | 65535 | 打开文件限制，两种场景一致，由系统 limits.conf 控制。 |
| `interactive_timeout` | 1800 | 3600 | 交互连接超时。VPS 更短以释放资源。 |
| `wait_timeout` | 1800 | 3600 | 非交互连接超时。同上。 |

---

## 内存占用估算

### VPS 场景（以 2GB 内存为例）

```
组件                      占用
─────────────────────────────
InnoDB Buffer Pool        1GB (50%)
连接缓冲区 (100连接)      150MB
MyISAM Key Buffer         100MB
临时表                    32MB
日志缓冲                  2MB
系统+其他                 ~700MB
─────────────────────────────
总计                      ~2GB
```

### 独立服务器场景（以 16GB 内存为例）

```
组件                      占用
─────────────────────────────
InnoDB Buffer Pool        11GB (70%)
连接缓冲区 (500连接)      3GB
MyISAM Key Buffer         256MB
临时表                    128MB
日志缓冲                  8MB
系统+其他                 ~1.5GB
─────────────────────────────
总计                      ~16GB
```

---

## 参数动态调整逻辑

安装脚本会根据以下因素动态调整参数：

1. **总内存大小**: `Mem = free -m | awk '/Mem:/{print $2}'`
2. **服务器场景**: 用户选择 VPS 或 Dedicated
3. **数据库版本**: MySQL 8.0/8.4、MariaDB 有不同配置

### 调整公式

```
# max_connections
VPS:        max_connections = min(100, Mem / 8)
Dedicated:  max_connections = min(500, Mem / 4)

# innodb_buffer_pool_size (单位: MB)
VPS:        innodb_buffer_pool = Mem * 0.5
Dedicated:  innodb_buffer_pool = Mem * 0.7

# innodb_buffer_pool_instances
VPS:        instances = 1
Dedicated:  instances = min(8, innodb_buffer_pool / 1024)

# innodb_log_file_size (单位: MB)
VPS:        log_file_size = 32
Dedicated:  log_file_size = min(256, innodb_buffer_pool / 8)
```

---

## 安全相关参数

以下参数在所有场景下保持一致：

| 参数 | 值 | 说明 |
|------|-----|------|
| `bind-address` | 127.0.0.1 | 仅本地监听，防止远程连接 |
| `local_infile` | 0 | 禁用本地文件加载，防止文件读取攻击 |
| `skip-name-resolve` | 启用 | 跳过 DNS 解析，提升连接速度并避免 DNS 欺骗 |

---

## 注意事项

1. **参数不是越大越好**: 过大的缓冲区反而可能导致内存碎片和交换
2. **监控和调整**: 部署后应监控 `show status` 和 `show variables`，根据实际情况调整
3. **SSD 优化**: 如使用 SSD，可增加 `innodb_io_capacity` 到 2000-5000
4. **MySQL 8.0+**: 已移除 query_cache，无需配置相关参数
