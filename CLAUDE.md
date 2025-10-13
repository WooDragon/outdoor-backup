# Outdoor Backup - OpenWrt SD Card Backup System

## 项目概述

**项目名称**: Outdoor Backup
**项目类型**: OpenWrt IPK 包 - SD 卡自动备份系统
**适用场景**: 户外摄影、无人机航拍、现场数据采集等需要可靠备份的场景
**核心价值**: 利用 OpenWrt 路由器（如 NanoPi R5S）的内置存储，实现 SD 卡插入即自动备份

## 技术栈

- **操作系统**: OpenWrt 19.07+，兼容 Lean's LEDE
- **硬件平台**: ARM/MIPS 路由器，需内置存储（SSD/HDD/eMMC）
- **Shell**: POSIX 兼容 Shell (ash)
- **备份引擎**: rsync 3.x
- **触发机制**: hotplug.d 事件系统
- **状态指示**: LED 控制接口（/sys/class/leds/）
- **包格式**: OpenWrt IPK

## 依赖包（已验证）

项目的 OpenWrt 包依赖已在 Lean's LEDE 主线版本（支持 kmod-fs-ntfs3）上完成验证：

| 包名 | 作用 | 类型 |
|------|------|------|
| `rsync` | 增量备份引擎 | 必需 |
| `block-mount` | 块设备管理和 hotplug 事件触发 | 必需 |
| `kmod-usb-storage` | USB 大容量存储设备驱动 | 必需 |
| `kmod-fs-ext4` | ext4 文件系统支持（专业相机/Linux 格式化） | 推荐 |
| `kmod-fs-vfat` | FAT32 文件系统支持（≤32GB SD 卡标准格式） | 必需 |
| `kmod-fs-exfat` | exFAT 文件系统支持（>32GB SD 卡标准格式） | 必需 |
| `kmod-fs-ntfs3` | NTFS 文件系统支持（内核原生驱动，5.15+） | 推荐 |

**环境确认**：
- 当前使用的 Lean's LEDE 主线版本已确认包含 `kmod-fs-ntfs3` 内核模块
- 文件系统挂载逻辑使用 `ntfs3`（内核原生驱动），无需 FUSE 层
- 支持的文件系统：exFAT / NTFS / ext4 / ext3 / ext2 / FAT32

**Makefile 依赖声明**（Makefile:24）：
```makefile
DEPENDS:=+rsync +block-mount +kmod-usb-storage +kmod-fs-ext4 +kmod-fs-vfat +kmod-fs-exfat +kmod-fs-ntfs3
```

**挂载尝试顺序**（backup-manager.sh:107）：
```bash
for fs in auto exfat ntfs3 ext4 ext3 ext2 vfat; do
```

## 核心设计原则（Linus 风格）

### 1. 数据结构优先
- **files/ 目录直接映射目标系统**: 所见即所得，无隐藏转换
- **Makefile 只定义"是什么"**: 避免复杂的构建逻辑
- **配置文件分层**: 全局配置 + 每卡配置

### 2. 消除特殊情况
- **单一入口**: hotplug 统一触发
- **统一处理**: 所有文件系统用相同流程挂载
- **无分支安装**: INSTALL_BIN/INSTALL_DATA 宏自动处理权限

### 3. 向后兼容
- **固定路径**: /opt/outdoor-backup 不变
- **配置保护**: conffiles 机制保留用户修改
- **数据保留**: 卸载不删除备份数据

### 4. 实用主义
- **解决真实问题**: SD 卡自动备份，不做假想功能
- **零侵入**: 使用 OpenWrt 原生机制，不修改系统文件
- **可恢复**: 任何错误都能通过删除包恢复

## 包结构

```
outdoor-backup/
├── Makefile                      # OpenWrt 包定义（126 行）
├── files/                        # 安装文件树
│   ├── etc/
│   │   ├── config/outdoor-backup         # UCI 配置
│   │   ├── hotplug.d/block/90-outdoor-backup  # 热插拔触发器
│   │   └── init.d/outdoor-backup         # procd 服务脚本
│   └── opt/outdoor-backup/
│       ├── conf/backup.conf             # 全局配置
│       └── scripts/
│           ├── backup-manager.sh        # 主备份逻辑（303 行）
│           └── common.sh                # 公共函数（155 行）
├── docs/                         # 设计文档
├── README.md                     # 用户手册
├── BUILD.md                      # 构建指南
└── IPK_PACKAGING.md              # 打包原理

总代码量: ~700 行 (含注释)
```

## 核心组件

### 1. Hotplug 触发器 (`/etc/hotplug.d/block/90-outdoor-backup`)
**职责**: 监听块设备事件，识别 SD 卡，触发备份
**输入**: `$ACTION`, `$DEVNAME`, `$DEVPATH`
**输出**: 后台启动 backup-manager.sh

**SD 卡识别逻辑**:
- 检查设备路径包含 "usb.*card|reader|SD|mmc"
- 检查设备 model 文件
- 检查设备大小（≤512GB）

### 2. 备份管理器 (`backup-manager.sh`)
**职责**: 执行完整备份流程，处理所有错误情况
**执行流程**:
```
获取 PID 锁 → 挂载 SD 卡 → 读取/创建配置 → rsync 备份 → 更新状态 → 释放锁
```

**关键函数**:
- `acquire_lock()`: 防并发，最多等待 5 分钟
- `mount_sdcard()`: 尝试多种文件系统
- `setup_sdcard_config()`: 生成/读取 `FieldBackup.conf`
- `perform_backup()`: 执行 rsync，记录日志
- `cleanup()`: 信号处理，确保资源释放

### 3. 公共函数库 (`common.sh`)
**职责**: LED 控制、日志函数、工具函数
**核心函数**:
- `led_backup_start/done/error/stop()`: LED 状态控制
- `log_info/error/warn/debug()`: 统一日志接口
- `is_safe_path()`: 路径安全检查
- `generate_uuid()`: UUID 生成（兼容无 uuidgen 的系统）

### 4. 服务脚本 (`/etc/init.d/outdoor-backup`)
**职责**: procd 服务管理，目录初始化
**功能**: enable/disable/start/stop/reload

## 配置系统

### 全局配置 (`/opt/outdoor-backup/conf/backup.conf`)
```bash
BACKUP_ROOT="/mnt/ssd/SDMirrors"   # 备份存储位置
DEBUG=0                             # 调试开关
LED_GREEN="/sys/class/leds/green:lan"
LED_RED="/sys/class/leds/red:sys"
```

### UCI 配置 (`/etc/config/outdoor-backup`)
```uci
config outdoor-backup 'config'
    option enabled '1'
    option backup_root '/mnt/ssd/SDMirrors'
    option debug '0'
```

### SD 卡配置 (`{SD_ROOT}/FieldBackup.conf`)
```bash
SD_UUID="550e8400-e29b-41d4-a716-446655440000"
SD_NAME="Canon_5D4_Card1"      # 用户可编辑
BACKUP_MODE="PRIMARY"           # PRIMARY 或 REPLICA
```

**备份模式**:
- `PRIMARY`: SD → 内置存储（默认）
- `REPLICA`: 内置存储 → SD（恢复模式）

## 数据流

```
[SD 卡插入]
    ↓
[hotplug 检测] → /etc/hotplug.d/block/90-outdoor-backup
    ↓
[启动备份管理器] → backup-manager.sh add sda1 /devices/...
    ↓
[获取 PID 锁] → /opt/outdoor-backup/var/lock/backup.pid
    ↓
[挂载 SD 卡] → /mnt/sdcard/
    ↓
[读取配置] → /mnt/sdcard/FieldBackup.conf
    ↓
[rsync 增量备份] → /mnt/ssd/SDMirrors/{UUID}/
    ↓
[记录日志] → /mnt/ssd/SDMirrors/.logs/{UUID}.log
    ↓
[LED 指示完成] → 绿灯常亮 30 秒
    ↓
[释放锁并清理]
```

## 安全机制

### 并发控制
- **PID 锁文件**: `/opt/outdoor-backup/var/lock/backup.pid`
- **活跃进程检查**: `kill -0 $pid`
- **超时机制**: 5 分钟未获取锁则放弃
- **僵尸锁清理**: 自动检测并移除无效锁

### 数据安全
- **增量备份**: `rsync --ignore-existing` 不覆盖已有文件
- **只读检测**: 无法写入 SD 卡时终止
- **完整性保证**: 备份后执行 `sync`
- **错误恢复**: 信号处理确保清理

### 路径安全
- **目录遍历防护**: `is_safe_path()` 检查 `../`
- **绝对路径**: 避免相对路径引起的歧义
- **UUID 隔离**: 每张 SD 卡独立目录

## 开发规范

### Shell 编程
- **POSIX 兼容**: 可在 ash/dash/bash 运行
- **错误处理**: 关键操作 `|| true`，主流程 `set -e`
- **信号处理**: `trap cleanup EXIT INT TERM`
- **日志完整**: 所有操作记录到 syslog 和本地日志

### 代码质量
- **ShellCheck 验证**: `shellcheck --shell=sh *.sh`
- **行长度**: ≤100 字符
- **函数长度**: ≤50 行
- **注释**: 关键逻辑必须注释

### Makefile 规范
- **依赖明确**: `DEPENDS:=+rsync +block-mount ...`
- **架构标识**: `PKGARCH:=all` (纯脚本包)
- **版本递增**: 功能变更递增 `PKG_VERSION`，打包变更递增 `PKG_RELEASE`
- **安装脚本**: postinst 创建目录，prerm 清理进程

## 性能指标

**目标硬件**: NanoPi R5S (ARM64, 4核, 4GB RAM, SATA SSD)

| 数据量 | 预期时间 | 预期速度 |
|-------|---------|---------|
| 10GB  | ~1 分钟  | ~170 MB/s |
| 50GB  | ~5 分钟  | ~170 MB/s |
| 100GB | ~10 分钟 | ~170 MB/s |

*实际性能取决于 SD 卡速度、文件系统、文件数量*

## 测试清单

### 功能测试
- [ ] SD 卡热插拔检测（sda1, mmcblk0p1）
- [ ] 多文件系统挂载（ext4/exFAT/NTFS/FAT32）
- [ ] 配置文件自动生成
- [ ] rsync 增量备份正确性
- [ ] LED 状态指示
- [ ] 并发锁机制

### 错误恢复
- [ ] SD 卡读写错误处理
- [ ] 存储空间不足处理
- [ ] 备份过程中断恢复
- [ ] 僵尸锁清理

### 性能测试
- [ ] 100GB 数据备份时间
- [ ] CPU/内存占用
- [ ] 多卡并发（如果启用）

### 兼容性测试
- [ ] Lean's LEDE 22.03
- [ ] OpenWrt 23.05
- [ ] ARM64/MIPS 架构

## 维护指南

### 日志位置
```bash
# 系统日志
logread | grep outdoor-backup

# 本地日志
/opt/outdoor-backup/log/backup.log

# rsync 详细日志
/mnt/ssd/SDMirrors/.logs/backup_{UUID}_{timestamp}.log
```

### 常见问题
**SD 卡未检测**: 检查 `logread | grep hotplug`，验证设备路径
**备份卡住**: 检查锁文件 `cat /opt/outdoor-backup/var/lock/backup.pid`
**LED 不工作**: `ls /sys/class/leds/`，调整配置中的路径
**性能慢**: 检查 SD 卡速度、文件系统类型、rsync 参数

### 手动测试
```bash
# 直接运行备份管理器
/opt/outdoor-backup/scripts/backup-manager.sh add sda1 /devices/test

# 启用调试
uci set outdoor-backup.config.debug='1'
uci commit

# 查看实时日志
logread -f | grep outdoor-backup
```

## WebUI 管理界面（已完成）

**luci-app-outdoor-backup** - LuCI 网页管理界面

### 已实现功能
- ✅ **实时状态监控**：进度条、文件数、速度、ETA
- ✅ **别名管理系统**：解决 UUID 可读性问题（如 "三星TF卡Pro128G"）
- ✅ **批量清理功能**：多重确认机制，防止误删
- ✅ **日志查看**：过滤、高亮、下载
- ✅ **RESTful API**：6 个端点，完整文档
- ✅ **安全机制**：XSS 防护、命令注入防护、文件锁

### 技术实现
- **后端**：Lua 5.1 + LuCI Framework
- **前端**：HTML5/CSS3 + JavaScript (ES5)
- **数据格式**：JSON (status.json, aliases.json)
- **配置系统**：UCI 集成
- **文档**：2562 行完整文档（用户手册 + 开发者指南）

### 代码规模
- Controller: 420 行（API 路由）
- Config CBI: 60 行（配置页面）
- Status View: 893 行（状态页面）
- Log View: 242 行（日志页面）
- Shell 集成: ~800 行（别名支持 + 批量清理）

### 文档
- [docs/WEBUI_USER_GUIDE.md](docs/WEBUI_USER_GUIDE.md) - 用户手册（634 行）
- [docs/WEBUI_DEVELOPER_GUIDE.md](docs/WEBUI_DEVELOPER_GUIDE.md) - 开发者文档（1466 行）
- [docs/webui-design.md](docs/webui-design.md) - 设计文档

## 后续改进方向

### 短期（可选）
- 备份完成推送通知（邮件/Telegram）
- 多卡并发支持（配置开关）
- 国际化支持（多语言）

### 长期（未规划）
- 云备份二级同步（rclone 集成）
- 备份版本管理（增量快照）
- 移动端控制 App

## 文档索引

### 用户文档
- **[README.md](README.md)**: 用户手册和快速开始指南
  - 功能特性、安装方法、配置说明
  - 故障排查、性能指标、兼容性列表

### 开发文档
- **[BUILD.md](BUILD.md)**: 构建指南（Lean's LEDE）
  - 编译流程、开发工作流、调试技巧
  - 版本管理、CI/CD 集成、常见问题

- **[IPK_PACKAGING.md](IPK_PACKAGING.md)**: IPK 打包原理详解
  - OpenWrt 包结构、Makefile 语法、最佳实践
  - 数据结构设计、安装脚本编写、调试方法

### 设计文档（docs/）

**核心系统设计**：
- **[docs/architecture-design.md](docs/architecture-design.md)**: 系统架构设计
  - 组件划分、数据流、接口定义
- **[docs/component-implementation.md](docs/component-implementation.md)**: 组件实现细节
  - 核心脚本代码、函数说明
- **[docs/technical-research.md](docs/technical-research.md)**: 技术调研
  - 待验证技术点、硬件兼容性
- **[docs/deployment-guide.md](docs/deployment-guide.md)**: 部署指南
  - 生产环境部署、配置优化
- **[docs/original-solution-analysis.md](docs/original-solution-analysis.md)**: 原始方案分析
  - FieldBackup 项目研究（仅作参考）

**WebUI 系统文档**：
- **[docs/webui-design.md](docs/webui-design.md)**: WebUI 设计文档（1400 行）⭐
  - UI 界面设计（状态/配置/日志三页面）
  - UUID 别名管理系统（解决 UUID 可读性问题）
  - 批量清理功能（多重确认机制，防误触发）
  - API 接口定义、数据结构设计、代码示例
- **[docs/WEBUI_USER_GUIDE.md](docs/WEBUI_USER_GUIDE.md)**: WebUI 用户手册（634 行）
  - 功能概览、访问方式、使用指南
  - 别名管理操作步骤、批量清理流程
  - 故障排查、FAQ、性能说明
- **[docs/WEBUI_DEVELOPER_GUIDE.md](docs/WEBUI_DEVELOPER_GUIDE.md)**: WebUI 开发者文档（1466 行）
  - 架构概述、技术栈、目录结构
  - API 完整文档（6 个端点，含请求/响应示例）
  - 数据结构规范（status.json, aliases.json）
  - 开发指南（添加新功能示例）
  - 安全机制（XSS 防护、命令注入防护、文件锁）
  - 部署指南、已知限制、改进方向

### 核心代码

**Shell 脚本（核心备份系统）**：
- **[files/opt/outdoor-backup/scripts/backup-manager.sh](files/opt/outdoor-backup/scripts/backup-manager.sh)**: 主备份逻辑（310 行）
  - 包含别名集成、状态更新
- **[files/opt/outdoor-backup/scripts/common.sh](files/opt/outdoor-backup/scripts/common.sh)**: 公共函数库（420 行）
  - 包含别名支持函数、批量清理辅助函数
- **[files/opt/outdoor-backup/scripts/cleanup-all.sh](files/opt/outdoor-backup/scripts/cleanup-all.sh)**: 批量清理脚本（165 行）
  - 独立可执行，带 --force 安全检查
- **[files/etc/hotplug.d/block/90-outdoor-backup](files/etc/hotplug.d/block/90-outdoor-backup)**: 热插拔触发器（82 行）
- **[files/etc/init.d/outdoor-backup](files/etc/init.d/outdoor-backup)**: 服务管理脚本（41 行）
- **[Makefile](Makefile)**: OpenWrt 包定义（128 行）

**WebUI 应用（luci-app-outdoor-backup）**：
- **[luci-app-outdoor-backup/luasrc/controller/outdoor-backup.lua](luci-app-outdoor-backup/luasrc/controller/outdoor-backup.lua)**: Controller（420 行）
  - 路由定义、6 个 API 端点
- **[luci-app-outdoor-backup/luasrc/model/cbi/outdoor-backup/config.lua](luci-app-outdoor-backup/luasrc/model/cbi/outdoor-backup/config.lua)**: 配置页面（60 行）
  - CBI 表单，UCI 绑定
- **[luci-app-outdoor-backup/luasrc/view/outdoor-backup/status.htm](luci-app-outdoor-backup/luasrc/view/outdoor-backup/status.htm)**: 状态页面（893 行）
  - 实时监控、别名管理、批量清理
- **[luci-app-outdoor-backup/luasrc/view/outdoor-backup/log.htm](luci-app-outdoor-backup/luasrc/view/outdoor-backup/log.htm)**: 日志页面（242 行）
  - 日志查看、过滤、高亮、下载
- **[luci-app-outdoor-backup/Makefile](luci-app-outdoor-backup/Makefile)**: LuCI 包定义（24 行）
- **[luci-app-outdoor-backup/root/usr/share/rpcd/acl.d/outdoor-backup.json](luci-app-outdoor-backup/root/usr/share/rpcd/acl.d/outdoor-backup.json)**: RPCD 权限配置（24 行）

### 配置文件
- **[files/opt/outdoor-backup/conf/backup.conf](files/opt/outdoor-backup/conf/backup.conf)**: 全局配置模板
- **[files/etc/config/outdoor-backup](files/etc/config/outdoor-backup)**: UCI 配置模板

## 参考项目

- **FieldBackup**: https://github.com/xyu/FieldBackup (原始灵感来源)
- **OpenWrt Packages**: https://openwrt.org/docs/guide-developer/packages
- **Lean's LEDE**: https://github.com/coolsnowwolf/lede (目标构建系统)

## 许可证

GPL-2.0-only (与 OpenWrt 兼容)
