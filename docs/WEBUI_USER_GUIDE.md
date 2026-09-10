# Outdoor Backup WebUI 用户手册

## 概述

Outdoor Backup WebUI 是一个基于 LuCI 框架的 Web 管理界面，为 SD 卡自动备份系统提供可视化监控和管理功能。

**核心功能**：
- 显示运行中的备份状态和完成后的真实 rsync 统计
- 存储空间可视化（饼图、使用率）
- 备份历史记录查看
- SD 卡别名管理（解决 UUID 不可读问题）
- 批量清理备份数据（多重安全确认）
- 日志查看和过滤

**设计原则**：
- 零配置：安装即用，自动检测备份状态
- 实时更新：每 10 秒自动刷新状态
- 安全优先：批量清理需要两步确认 + 输入确认文字

---

## 访问 WebUI

### 安装

```bash
# 安装 WebUI 包（依赖 outdoor-backup 核心包）
opkg install luci-app-outdoor-backup_*.ipk
```

### 访问方式

安装完成后，通过浏览器访问：

```
http://<路由器IP>/cgi-bin/luci/admin/services/outdoor-backup
```

**示例**：
```
http://192.168.1.1/cgi-bin/luci/admin/services/outdoor-backup
```

**导航路径**：
```
LuCI 主页 → Services（服务） → Outdoor Backup
```

---

## 功能说明

### 1. 状态页面（Status）

#### 1.1 当前备份状态

**功能**：显示正在进行的备份任务。

**显示内容**：
- 卡片名称（别名或 UUID）
- 设备路径（如 `/dev/sda1`）
- 开始时间
- `active` 运行状态

运行中快照不提供实时百分比、文件数、传输字节数、速率或 ETA。对应字段为 `0`，表示未知而非零传输。状态页面可以按既有页面刷新频率重读快照，但刷新不会使运行时具备实时进度 writer 能力。

备份完成后，history 的文件数和字节数来自成功 rsync 的 `--stats` 输出。管理器只会在 rsync、摘要写入、最终目标锚点健康检查和目标身份复验均成功后记录 `completed`。

#### 1.2 存储空间

**功能**：显示备份存储位置的磁盘使用情况

**显示内容**：
- 备份根目录路径
- 已用空间 / 总空间（百分比）
- 可用空间
- 使用率进度条（颜色渐变：绿→黄→红）

**示例界面**：

```
┌─ Storage Space ───────────────────────────────────┐
│ Backup Root: /mnt/ssd/SDMirrors                    │
│ Used: 119 GB / 476 GB (25%)                        │
│ Available: 357 GB                                  │
│                                                     │
│ [████████░░░░░░░░░░░░░░░░░░░░░░░░░░] 25%         │
└─────────────────────────────────────────────────────┘
```

**注意事项**：
- `storage.root` 显示稳定的规范备份路径，而不是 `/proc/self/fd` 形式的内部锚点路径。
- `status.sh` 通过活跃目标 FD 的 `df` 读取空间计数。
- 运行时空间计数无法取得时会写入零值；这不代表目标存储为空。

#### 1.3 备份历史

**功能**：显示所有已备份的 SD 卡记录

**表格列**：
- **Card Name**：卡片名称（别名或 UUID 前 8 位）
- **UUID**：完整 UUID 的前 8 位（带省略号）
- **Last Backup**：最后一次备份时间（人性化显示）
- **Size**：备份数据总大小
- **Status**：备份状态（已完成 / 运行中 / 错误）
- **Actions**：操作按钮（编辑别名）

**示例界面**：

```
┌─ Backup History ────────────────────────────────────────────────┐
│ Card Name         │ UUID      │ Last Backup │ Size   │ Actions │
│ ──────────────────────────────────────────────────────────────── │
│ Canon_5D4_Card1   │ 550e8400… │ 2 min ago   │ 48.8GB │ [Edit]  │
│ Sony A7R5 Backup  │ 7c9e6679… │ 1 hour ago  │ 32.1GB │ [Edit]  │
│ DJI_Mavic3_Card1  │ 3b1e7a9f… │ Yesterday   │ 12.5GB │ [Edit]  │
└──────────────────────────────────────────────────────────────────┘
```

**时间显示规则**：
- 小于 1 分钟：`X seconds ago`
- 小于 1 小时：`X minutes ago`
- 小于 1 天：`X hours ago`
- 超过 1 天：完整日期时间

**状态徽章颜色**：
- **Completed**：绿色（备份成功）
- **Running**：蓝色（正在备份）
- **Error**：红色（备份失败）

#### 1.4 批量清理按钮

**位置**：状态页面底部（危险操作区域）

**按钮样式**：红色 + ⚠️ 图标

**功能说明文字**：
```
Clean up all backup data while preserving alias mappings.
Use this after backing up to NAS.
```

**点击后**：打开批量清理预览对话框（见 [批量清理功能](#操作-2批量清理备份数据)）

---

### 2. 配置页面（Configuration）

#### 2.1 基本设置

**功能**：配置全局备份参数

**配置项**：

| 配置项 | 说明 | 默认值 |
|--------|------|--------|
| **Enable Auto Backup** | 启用/禁用自动备份 | 启用 |
| **Backup Root Directory** | 备份存储位置 | `/mnt/ssd/SDMirrors` |
| **Debug Mode** | 调试日志开关 | 禁用 |

**保存方式**：点击 "Save & Apply" 按钮

#### 2.2 LED 设置

**功能**：配置 LED 指示灯路径（硬件相关）

**配置项**：

| 配置项 | 说明 | 默认值 |
|--------|------|--------|
| **Green LED Path** | 绿灯路径（成功指示） | `/sys/class/leds/green:lan` |
| **Red LED Path** | 红灯路径（错误指示） | `/sys/class/leds/red:sys` |

**查找 LED 路径**：

```bash
# SSH 到路由器
ls /sys/class/leds/

# 示例输出
green:lan  red:sys  blue:wan
```

#### 2.3 高级设置

**功能**：配置备份行为参数

**配置项**：

**自动备份方向**：
- **PRIMARY**：SD 卡 → 已配置的目标存储。新卡的 `FieldBackup.conf` 只生成该值。
- **REPLICA**：读取既有 `FieldBackup.conf` 时保留的兼容数据值，不是自动恢复模式。

**已有 `REPLICA` 卡**：
- 管理器会返回明确错误并拒绝反向同步。
- 管理器不会执行 `rsync`。
- 管理器会保留卡配置和 sentinel 文件的字节内容。
- 管理器不会更新别名、创建目标 UUID 叶目录或创建单次备份日志。
- 管理器可在读取卡前创建已配置的 `BACKUP_ROOT`，并将拒绝写入应用错误日志。

`FieldBackup.conf` 是来自卡的纯数据。管理器不会执行其内容，也不会将 `REPLICA` 自动改成 `PRIMARY`。稳态只读挂载限制用户态写入，但不是取证写保护；ext4 的脏日志仍可能重放。首次初始化要求没有正式配置，使用短暂读写挂载写入临时文件并发布正式文件。读写挂载或实际写入失败都表示不能初始化。恢复只读后的重读只检查流程，不能证明介质持久性或卡身份。失败时管理器不会启动 `rsync`。

---

### 3. 日志页面（Logs）

#### 3.1 功能说明

**显示内容**：
- 系统日志最后 100 行
- 日志级别颜色高亮
- 实时刷新选项
- 日志过滤

**日志级别**：
- **ERROR**：红色加粗（错误信息）
- **WARN**：黄色加粗（警告信息）
- **INFO**：蓝色（一般信息）
- **DEBUG**：灰色（调试信息）

#### 3.2 功能按钮

| 按钮 | 功能 | 说明 |
|------|------|------|
| **Refresh** | 刷新日志 | 重新加载最后 100 行 |
| **Download Full Log** | 下载完整日志 | 下载 `backup.log` 文件 |
| **Auto Refresh (10s)** | 自动刷新 | 每 10 秒刷新一次 |

#### 3.3 日志过滤

**过滤选项**：
- **All Levels**：显示所有日志
- **INFO**：只显示 INFO 级别
- **WARN**：只显示 WARN 级别
- **ERROR**：只显示 ERROR 级别
- **DEBUG**：只显示 DEBUG 级别

**使用方法**：
1. 在过滤下拉框中选择日志级别
2. 日志内容自动过滤
3. 重新选择 "All Levels" 恢复显示

---

## 常见操作

### 操作 1：设置 SD 卡别名

**场景**：首次插入新 SD 卡后，系统自动生成 UUID 前缀（如 `SD_550e8400`），不易识别。

**步骤**：

1. **插入 SD 卡并等待备份完成**
   - 绿色 LED 常亮表示完成

2. **访问 WebUI 状态页面**
   ```
   Services → Outdoor Backup → Status
   ```

3. **在备份历史表格中找到该卡**
   - 显示名称：`SD_550e8400`（UUID 前 8 位）

4. **点击 "Edit" 按钮**
   - 弹出别名编辑对话框

5. **填写别名和备注**
   ```
   Alias: Canon_5D4_Card1
   Notes: 佳能相机主卡，128GB，购于 2024-01
   ```

6. **点击 "Save Alias" 保存**
   - 成功后自动刷新页面
   - 显示名称变为 `Canon_5D4_Card1`

7. **下次插入此卡时**
   - 自动显示别名（无需重新设置）

**注意事项**：
- 别名可以包含中文、数字、符号
- 别名为空时自动回退到 UUID 前缀
- 删除别名不会删除备份数据

---

### 操作 2：批量清理备份数据

**场景**：路由器存储空间不足，需要清理所有已备份到 NAS 的数据。

**重要提示**：
- ⚠️ 此操作不可撤销
- ✅ 别名映射会保留（aliases.json）
- ✅ 配置文件会保留
- ✅ 日志文件会保留
- ❌ 所有备份数据会被删除

**步骤**：

#### 第一步：预览数据

1. **访问状态页面**
   ```
   Services → Outdoor Backup → Status
   ```

2. **点击底部 "⚠️ Batch Cleanup..." 按钮**
   - 弹出预览对话框

3. **查看将被清理的数据**
   - 表格显示所有卡片、UUID、大小
   - 底部显示总计（如：3 张卡，93.4 GB）

4. **确认保留内容**
   ```
   Will be preserved:
   ✓ Alias mappings (aliases.json)
   ✓ Configuration files
   ✓ Log files
   ```

5. **确认删除内容**
   ```
   Will be deleted:
   ✗ All backup data in subdirectories
   ✗ Cannot be undone
   ```

6. **点击 "Next Step" 进入确认步骤**

#### 第二步：最终确认

1. **查看警告信息**
   ```
   ⚠️ Last Warning: This operation CANNOT be undone!
   Will delete: 93.4 GB (3 cards)
   ```

2. **输入确认文字**
   - 在输入框中输入：`清空备份数据`（必须完全匹配）

3. **勾选确认复选框**
   ```
   ☑ 我已经将数据备份到 NAS，确认清空
   ```

4. **点击 "Confirm Cleanup" 按钮**
   - 按钮在输入正确且勾选后才启用

#### 第三步：执行清理

1. **显示进度对话框**
   ```
   Cleaning Up...
   Executing cleanup...
   [████████████████░░░░░░░░░░░░] 50%
   Please wait... Do not close this window or navigate away.
   ```

2. **等待清理完成**
   - 通常需要 10-30 秒（取决于数据量）

3. **自动关闭并刷新页面**
   - 存储空间显示更新
   - 备份历史表格清空（别名保留）

#### 取消操作

在任何步骤中点击 "Cancel" 或关闭对话框可以取消操作（不会删除数据）。

---

### 操作 3：删除 SD 卡别名

**场景**：不再使用某张 SD 卡，希望从列表中移除别名映射。

**步骤**：

1. **访问状态页面**
   ```
   Services → Outdoor Backup → Status
   ```

2. **在备份历史中找到该卡**
   - 点击 "Edit" 按钮

3. **点击 "Delete Mapping" 按钮**
   - 弹出确认对话框

4. **阅读警告信息**
   ```
   ⚠️ Note:
   - Deleting the alias mapping will NOT delete backup data
   - Backup data will be preserved at: /mnt/ssd/SDMirrors/550e8400-...
   - To clean up backup data, use the "Batch Cleanup" feature
   ```

5. **点击 "Confirm Delete" 确认**
   - 别名映射删除
   - 备份数据保留

6. **如需删除备份数据**
   - 使用 SSH 手动删除：
     ```bash
     rm -rf /mnt/ssd/SDMirrors/550e8400-*
     ```
   - 或使用批量清理功能

---

## 故障排查

### 问题 1：WebUI 无法访问

**症状**：浏览器显示 404 Not Found

**可能原因**：
- LuCI 服务未启动
- IPK 包未正确安装
- 权限问题

**解决方法**：

```bash
# 1. 检查 LuCI 服务
/etc/init.d/uhttpd status
/etc/init.d/uhttpd restart

# 2. 检查包是否安装
opkg list-installed | grep outdoor-backup

# 3. 重新安装
opkg remove luci-app-outdoor-backup
opkg install luci-app-outdoor-backup_*.ipk

# 4. 清除浏览器缓存并刷新
```

---

### 问题 2：状态页面显示 "Status file not found"

**症状**：状态页面无法加载数据

**可能原因**：
- 核心备份包未安装
- 状态文件未生成
- 文件权限问题

**解决方法**：

```bash
# 1. 检查核心包
opkg list-installed | grep outdoor-backup

# 2. 检查状态文件
ls -la /opt/outdoor-backup/var/status.json

# 3. 手动创建空状态文件（临时）
mkdir -p /opt/outdoor-backup/var
cat > /opt/outdoor-backup/var/status.json <<'EOF'
{
  "version": "1.0",
  "last_update": 0,
  "storage": null,
  "current_backup": null,
  "history": []
}
EOF

# 4. 插入 SD 卡触发备份（生成真实状态）
```

---

### 问题 3：别名保存失败

**症状**：点击 "Save Alias" 后弹出 "Failed to save alias" 错误

**可能原因**：
- 文件系统只读
- 磁盘空间不足
- 权限问题

**解决方法**：

```bash
# 1. 检查文件系统
mount | grep /opt

# 2. 检查磁盘空间
df -h /opt

# 3. 检查文件权限
ls -la /opt/outdoor-backup/conf/
chmod 755 /opt/outdoor-backup/conf/

# 4. 手动测试写入
echo "test" > /opt/outdoor-backup/conf/test.txt
rm /opt/outdoor-backup/conf/test.txt
```

---

### 问题 4：批量清理卡住

**症状**：批量清理进度条停留在 50%，长时间无响应

**可能原因**：
- 清理脚本执行时间过长
- 后台进程阻塞

**解决方法**：

```bash
# 1. 检查清理进程
ps | grep cleanup-all.sh

# 2. 查看系统日志
logread | grep outdoor-backup

# 3. 手动执行清理脚本（调试）
/opt/outdoor-backup/scripts/cleanup-all.sh --force /mnt/ssd/SDMirrors 1

# 4. 如果卡死，刷新浏览器页面
```

---

### 问题 5：日志页面无内容

**症状**：日志页面显示 "Log file not found"

**可能原因**：
- 日志文件路径错误
- 备份从未运行过

**解决方法**：

```bash
# 1. 检查日志文件
ls -la /opt/outdoor-backup/log/backup.log

# 2. 创建日志目录
mkdir -p /opt/outdoor-backup/log
touch /opt/outdoor-backup/log/backup.log

# 3. 查看系统日志（备用）
logread | grep outdoor-backup
```

---

## 安全注意事项

### 1. 批量清理防护

WebUI 设计了多重安全机制防止误操作：

| 机制 | 说明 |
|------|------|
| **两步确认** | 预览 → 最终确认 |
| **输入确认文字** | 必须手动输入 "清空备份数据" |
| **复选框确认** | 必须勾选 "我已备份到 NAS" |
| **明确显示** | 列出所有将被删除的卡片和大小 |
| **保留别名** | aliases.json 永远不会被删除 |

### 2. 别名数据安全

- 别名存储在路由器本地（`/opt/outdoor-backup/conf/aliases.json`）
- 删除别名不会删除备份数据（职责分离）
- 建议定期备份 aliases.json：
  ```bash
  scp root@router:/opt/outdoor-backup/conf/aliases.json ~/backups/
  ```

### 3. 权限控制

WebUI 通过 RPCD 权限系统控制访问：

- 读取状态文件：只读权限
- 修改配置：需要管理员权限
- 批量清理：需要管理员权限

---

## 常见问题（FAQ）

### Q1：别名和备份数据是否绑定？

**A**：不绑定。别名只是显示名称，删除别名不会删除备份数据。备份数据始终通过 UUID 索引。

---

### Q2：批量清理后是否需要重新设置别名？

**A**：不需要。批量清理只删除备份数据，aliases.json 会保留。下次插入旧卡时仍然显示别名。

---

### Q3：如何导出所有别名数据？

**A**：通过 SSH 复制 aliases.json：

```bash
scp root@router:/opt/outdoor-backup/conf/aliases.json ~/aliases_backup.json
```

导入（覆盖）：

```bash
scp ~/aliases_backup.json root@router:/opt/outdoor-backup/conf/aliases.json
```

---

### Q4：WebUI 是否支持移动设备？

**A**：是的。WebUI 使用响应式设计，支持手机和平板浏览器访问。但批量清理建议在电脑上操作（防止误触）。

---

### Q5：如何禁用自动备份但保留 WebUI？

**A**：在配置页面关闭 "Enable Auto Backup" 选项：

```
Configuration → Basic Settings → Enable Auto Backup → 取消勾选 → Save & Apply
```

或通过 UCI：

```bash
uci set outdoor-backup.config.enabled='0'
uci commit outdoor-backup
```

---

## 性能说明

### 状态刷新频率

| 组件 | 刷新频率 | 说明 |
|------|---------|------|
| **backup-manager.sh** | 生命周期转换时 | 原子写入 running、completed 或 failed 快照；运行中计数为未知的 0 |
| **WebUI 前端** | 既有页面刷新频率 | 读取快照；刷新不产生实时进度或速率 |
| **日志页面** | 手动或自动（可选） | 用户控制 |

### 浏览器兼容性

| 浏览器 | 最低版本 | 说明 |
|--------|---------|------|
| Chrome | 80+ | 推荐 |
| Firefox | 75+ | 推荐 |
| Safari | 13+ | 支持 |
| Edge | 80+ | 支持 |
| IE | ❌ | 不支持 |

---

## 技术支持

### 日志收集

遇到问题时，请收集以下日志：

```bash
# 1. 系统日志
logread > /tmp/syslog.txt

# 2. 备份日志
cat /opt/outdoor-backup/log/backup.log > /tmp/backup.log

# 3. 状态文件
cat /opt/outdoor-backup/var/status.json > /tmp/status.json

# 4. 别名文件
cat /opt/outdoor-backup/conf/aliases.json > /tmp/aliases.json

# 5. UCI 配置
uci show outdoor-backup > /tmp/uci.txt
```

### 问题反馈

提交 Issue 时请提供：

1. OpenWrt 版本（`cat /etc/openwrt_release`）
2. 包版本（`opkg list-installed | grep outdoor-backup`）
3. 浏览器版本
4. 详细复现步骤
5. 相关日志文件

### 联系方式

- GitHub Issues: [项目仓库地址]
- 文档: [docs/ 目录]

---

## 附录

### A. 文件路径索引

| 文件 | 路径 | 说明 |
|------|------|------|
| 状态文件 | `/opt/outdoor-backup/var/status.json` | 备份进度和历史 |
| 别名文件 | `/opt/outdoor-backup/conf/aliases.json` | UUID 别名映射 |
| 日志文件 | `/opt/outdoor-backup/log/backup.log` | 备份详细日志 |
| UCI 配置 | `/etc/config/outdoor-backup` | 全局配置 |

### B. API 端点索引

| 端点 | 方法 | 功能 |
|------|------|------|
| `/api/status` | GET | 获取状态信息 |
| `/api/aliases` | GET | 获取所有别名 |
| `/api/alias/update` | POST | 创建/更新别名 |
| `/api/alias/delete` | DELETE | 删除别名 |
| `/api/cleanup/preview` | GET | 预览批量清理 |
| `/api/cleanup/execute` | POST | 执行批量清理 |

---

## 版本历史

### v1.0.0 (2024-01)
- 初始版本发布
- 状态监控功能
- 别名管理功能
- 批量清理功能
- 日志查看功能
