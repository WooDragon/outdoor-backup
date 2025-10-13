# Batch Cleanup Functionality - Usage Guide

## 概述

批量清理功能（cleanup-all.sh）用于在备份数据同步到 NAS 后，清空路由器本地存储的备份数据，释放空间。

## 核心设计原则

- **安全第一**：UUID 格式验证，路径安全检查，防止误删
- **保留结构**：只删除文件内容，保留目录结构
- **保留别名**：默认保留 aliases.json，下次插卡仍可识别
- **详细日志**：所有操作记录到 syslog 和本地日志

## 使用方式

### 1. 基本用法（保留别名）

```bash
/opt/outdoor-backup/scripts/cleanup-all.sh /mnt/ssd/SDMirrors
```

**行为**：
- 删除所有 UUID 目录下的备份文件
- 保留目录结构（空目录）
- 保留 aliases.json（别名映射表）
- 保留 .logs、.tmp 等特殊目录

**适用场景**：
- 数据已同步到 NAS
- 需要释放本地存储空间
- 希望下次插卡时仍能识别卡片名称

### 2. 完全清理（清空别名）

```bash
/opt/outdoor-backup/scripts/cleanup-all.sh /mnt/ssd/SDMirrors 0
```

**行为**：
- 删除所有 UUID 目录下的备份文件
- 保留目录结构
- **清空 aliases.json**（重置为空）
- 下次插卡将显示 "SD_xxxxxxxx"（UUID 前8位）

**适用场景**：
- 重置系统，清除所有历史记录
- 更换新的 SD 卡组，避免混淆
- 不需要保留卡片别名信息

### 3. LuCI WebUI 调用（推荐）

通过 WebUI 的批量清理功能，提供多重确认机制：

1. **预览阶段**：显示所有卡片名称和大小
2. **第一步确认**：列出将删除的内容和保留的内容
3. **第二步确认**：输入"清空备份数据"并勾选复选框
4. **执行清理**：显示进度，完成后显示结果

**WebUI 调用示例**（Lua）：

```lua
function api_cleanup_execute()
    local backup_root = luci.sys.exec("uci get outdoor-backup.config.backup_root"):gsub("%s+", "")
    local cleanup_script = "/opt/outdoor-backup/scripts/cleanup-all.sh"
    local cmd = string.format("%s '%s' 1", cleanup_script, backup_root)
    local result = luci.sys.exec(cmd)
    -- ...
end
```

## 执行示例

### 示例 1：正常清理（3 张卡，93.4 GB）

```bash
# 执行清理
$ /opt/outdoor-backup/scripts/cleanup-all.sh /mnt/ssd/SDMirrors 1

# 日志输出（/opt/outdoor-backup/log/backup.log）
2025-10-13 14:50:00 [INFO] Starting batch cleanup of backup data
2025-10-13 14:50:00 [INFO] Backup root: /mnt/ssd/SDMirrors
2025-10-13 14:50:00 [INFO] Keep aliases: 1
2025-10-13 14:50:00 [INFO] Total size before cleanup: 100338688000 bytes
2025-10-13 14:50:01 [INFO] Cleaning up backup data for UUID: 550e8400-e29b-41d4-a716-446655440000
2025-10-13 14:50:15 [INFO] Deleted 48800MB from UUID: 550e8400-e29b-41d4-a716-446655440000
2025-10-13 14:50:15 [INFO] Cleaning up backup data for UUID: 7c9e6679-7425-40de-944b-e07fc1f90ae7
2025-10-13 14:50:25 [INFO] Deleted 32100MB from UUID: 7c9e6679-7425-40de-944b-e07fc1f90ae7
2025-10-13 14:50:25 [INFO] Cleaning up backup data for UUID: 3b1e7a9f-8d6c-4c3e-b2f4-9a1e7d8c4b5a
2025-10-13 14:50:30 [INFO] Deleted 12500MB from UUID: 3b1e7a9f-8d6c-4c3e-b2f4-9a1e7d8c4b5a
2025-10-13 14:50:30 [INFO] Deleted backup data from 3 UUID directories
2025-10-13 14:50:30 [INFO] Skipped 0 directories (special or invalid)
2025-10-13 14:50:30 [INFO] Total size after cleanup: 52428800 bytes
2025-10-13 14:50:30 [INFO] Freed space: 100286259200 bytes
2025-10-13 14:50:30 [INFO] Preserved aliases.json (keep_aliases=1)
2025-10-13 14:50:30 [INFO] Batch cleanup completed successfully
```

### 示例 2：错误处理（路径不存在）

```bash
$ /opt/outdoor-backup/scripts/cleanup-all.sh /non/existent/path
2025-10-13 15:00:00 [ERROR] Backup root does not exist: /non/existent/path
Usage: /opt/outdoor-backup/scripts/cleanup-all.sh <backup_root> [keep_aliases]
# 退出码：2 (EXIT_PATH_ERROR)
```

### 示例 3：安全防护（不安全路径）

```bash
$ /opt/outdoor-backup/scripts/cleanup-all.sh "/tmp/../etc"
2025-10-13 15:00:00 [ERROR] Unsafe path detected: /tmp/../etc
# 退出码：2 (EXIT_PATH_ERROR)
```

## 数据结构说明

### 清理前

```
/mnt/ssd/SDMirrors/
├── 550e8400-e29b-41d4-a716-446655440000/
│   ├── DCIM/
│   │   ├── IMG_0001.JPG (10 MB)
│   │   ├── IMG_0002.JPG (10 MB)
│   │   └── ...
│   └── VIDEO/
│       └── VID_0001.MP4 (500 MB)
├── 7c9e6679-7425-40de-944b-e07fc1f90ae7/
│   └── ...
├── .logs/
│   └── backup_550e8400_20251013.log
└── lost+found/
```

### 清理后（keep_aliases=1）

```
/mnt/ssd/SDMirrors/
├── 550e8400-e29b-41d4-a716-446655440000/  (空目录)
├── 7c9e6679-7425-40de-944b-e07fc1f90ae7/  (空目录)
├── .logs/  (保留)
│   └── backup_550e8400_20251013.log
└── lost+found/  (保留)
```

### aliases.json（清理前后对比）

**清理前/清理后（keep_aliases=1）**：

```json
{
  "version": "1.0",
  "aliases": {
    "550e8400-e29b-41d4-a716-446655440000": {
      "alias": "三星TF卡Pro128G",
      "notes": "户外摄影专用卡",
      "created_at": 1728825600,
      "last_seen": 1728900000
    }
  }
}
```

**清理后（keep_aliases=0）**：

```json
{
  "version": "1.0",
  "aliases": {}
}
```

## 退出码

| 退出码 | 常量 | 说明 |
|--------|------|------|
| 0 | EXIT_SUCCESS | 执行成功 |
| 1 | EXIT_INVALID_ARGS | 参数错误（缺少 backup_root） |
| 2 | EXIT_PATH_ERROR | 路径错误（不存在、不安全、无写权限） |
| 3 | EXIT_CLEANUP_ERROR | 清理过程错误（未使用） |

## 安全机制

### 1. UUID 格式验证

```bash
# is_valid_uuid() 函数验证 UUID 格式
# 格式：xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx (8-4-4-4-12)
# 长度：36 字符
# 字符集：0-9a-fA-F

# 有效 UUID（会被清理）
550e8400-e29b-41d4-a716-446655440000 ✓

# 无效 UUID（跳过）
invalid-directory-name ✗
lost+found ✗（特殊目录）
.logs ✗（特殊目录）
```

### 2. 路径安全检查

```bash
# is_safe_path() 函数检查目录遍历攻击
/mnt/ssd/SDMirrors ✓
/tmp/test ✓

# 不安全路径（拒绝）
/tmp/../etc ✗
/mnt/ssd/../root ✗
/home/user/../../etc ✗
```

### 3. 权限检查

```bash
# 检查 backup_root 是否可写
if [ ! -w "$BACKUP_ROOT" ]; then
    log_error "Backup root is not writable: $BACKUP_ROOT"
    exit 2
fi
```

## 测试

项目包含完整的测试套件（test-cleanup.sh），涵盖以下场景：

### 运行测试

```bash
cd /path/to/outdoor-backup
bash test-cleanup.sh
```

### 测试覆盖（17 个测试）

1. **UUID 验证（5 tests）**
   - 有效 UUID（小写/大写）
   - 无效 UUID（短/非十六进制/格式错误）

2. **大小计算（2 tests）**
   - 正常目录大小计算
   - 不存在路径处理

3. **清理功能（6 tests）**
   - UUID 目录内容删除
   - 目录结构保留
   - 无效目录跳过
   - 特殊目录保留
   - aliases.json 保留/清空

4. **错误处理（3 tests）**
   - 缺少参数
   - 不存在路径
   - 不安全路径

5. **跨平台兼容性**
   - Linux（du -sb）
   - macOS/BSD（du -sk 回退）

### 测试输出示例

```
========================================
  Outdoor Backup - Cleanup Test Suite
========================================

=== Test 1: UUID Validation ===
✓ PASSED: Valid UUID accepted (lowercase)
✓ PASSED: Valid UUID accepted (uppercase)
✓ PASSED: Invalid UUID rejected (short)
✓ PASSED: Invalid UUID rejected (non-hex char)
✓ PASSED: Invalid UUID rejected (too short)

=== Test 2: Total Size Calculation ===
✓ PASSED: Total size calculated: 24125440 bytes (~23MB)
✓ PASSED: Non-existent path returns 0

=== Test 3: Cleanup with Aliases Preserved ===
✓ PASSED: UUID directory 1 cleaned (0 files)
✓ PASSED: UUID directory 2 cleaned (0 files)
✓ PASSED: UUID directory 1 structure preserved
✓ PASSED: Invalid directory preserved (not a UUID)
✓ PASSED: Special directory preserved (lost+found)
✓ PASSED: aliases.json preserved with 2 aliases

=== Test 4: Cleanup with Aliases Cleared ===
✓ PASSED: aliases.json cleared (empty aliases object)

=== Test 5: Error Handling ===
✓ PASSED: Missing argument rejected
✓ PASSED: Non-existent directory rejected
✓ PASSED: Unsafe path rejected (directory traversal)

========================================
  Test Results
========================================
Passed: 17
Failed: 0

All tests passed!
```

## 性能指标

| 数据量 | 文件数 | 预期时间 | 说明 |
|--------|--------|---------|------|
| 10 GB | 100 | ~1 秒 | 快速删除 |
| 50 GB | 1000 | ~3 秒 | rm -rf 速度取决于文件系统 |
| 100 GB | 5000 | ~5 秒 | SSD：极快，HDD：较慢 |

**注意**：实际性能取决于：
- 文件系统类型（ext4 / btrfs / NTFS）
- 存储设备类型（SSD / HDD）
- 文件数量（小文件更慢）

## 故障排查

### 问题 1：Permission denied

```bash
# 错误
/opt/outdoor-backup/scripts/cleanup-all.sh: line 110: cannot remove '/mnt/ssd/SDMirrors/xxx': Permission denied

# 原因
- backup_root 无写权限
- 文件被其他进程占用

# 解决
chmod -R u+w /mnt/ssd/SDMirrors
```

### 问题 2：aliases.json 未清空（keep_aliases=0）

```bash
# 原因
- aliases.json 文件权限只读
- 目录不存在

# 解决
chmod u+w /opt/outdoor-backup/conf/aliases.json
mkdir -p /opt/outdoor-backup/conf
```

### 问题 3：脚本执行无输出

```bash
# 原因
- logger 不可用（syslog 未运行）
- 日志目录不存在

# 解决
mkdir -p /opt/outdoor-backup/log
/etc/init.d/syslog start
```

## 注意事项

1. **数据不可恢复**：清理后数据无法恢复，请确保已同步到 NAS
2. **并发安全**：不要在备份过程中执行清理（会被备份锁阻止）
3. **空间释放**：清理后需执行 `sync` 确保写入磁盘
4. **别名保留**：推荐保留 aliases.json，方便下次识别卡片

## 相关文档

- **[webui-design.md](docs/webui-design.md)** - WebUI 批量清理界面设计
- **[README.md](README.md)** - 项目整体文档
- **[BUILD.md](BUILD.md)** - 构建和安装指南

## API 参考（WebUI 集成）

### cleanup_all_backup_data()

Shell 函数，定义在 cleanup-all.sh 中。

**功能**：批量清理所有备份数据

**参数**：
- `BACKUP_ROOT`（全局变量）：备份根目录
- `KEEP_ALIASES`（全局变量）：1=保留别名，0=清空别名

**返回值**：
- 0：成功
- 1/2/3：错误（参见退出码）

**日志输出**：
- `/opt/outdoor-backup/log/backup.log`
- syslog（tag: outdoor-backup-cleanup）

### get_total_backup_size()

Shell 函数，定义在 common.sh 中。

**功能**：计算备份根目录总大小

**参数**：
- `$1`：backup_root 路径

**返回值**：
- stdout：大小（字节）
- exit code：0=成功，1=路径不存在

**示例**：

```bash
. /opt/outdoor-backup/scripts/common.sh
size=$(get_total_backup_size "/mnt/ssd/SDMirrors")
echo "Total size: $size bytes"
```

### is_valid_uuid()

Shell 函数，定义在 common.sh 中。

**功能**：验证 UUID 格式

**参数**：
- `$1`：UUID 字符串

**返回值**：
- 0：有效 UUID
- 1：无效 UUID

**示例**：

```bash
. /opt/outdoor-backup/scripts/common.sh
if is_valid_uuid "550e8400-e29b-41d4-a716-446655440000"; then
    echo "Valid UUID"
else
    echo "Invalid UUID"
fi
```

## 版本历史

- **v1.0** (2025-10-13) - 初始版本
  - 批量清理备份数据
  - UUID 格式验证
  - 路径安全检查
  - aliases.json 保留/清空选项
  - 跨平台兼容（Linux/macOS/BSD）
  - 完整测试套件（17 tests）
