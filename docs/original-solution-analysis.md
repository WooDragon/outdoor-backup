# 原始FieldBackup方案分析

## 1. 系统概述

FieldBackup是为RAVPower FileHub Plus (RP-WD03)设备开发的自动SD卡备份系统，主要服务于摄影师在野外拍摄时的数据备份需求。

### 1.1 硬件环境

- **设备型号**: RAVPower FileHub Plus (RP-WD03)
- **处理器**: MIPS32 rel2 架构
- **内存**: 64MB (严重受限，需要swap)
- **Shell环境**: Ash (BusyBox shell)
- **存储路径**:
  - SD卡: `/data/UsbDisk1/Volume1`
  - USB硬盘: `/data/UsbDisk2/Volume1`

## 2. 触发机制

### 2.1 自动触发流程

系统通过特殊的文件检测机制触发备份：

```
USB硬盘插入 → 检测EnterRouterMode.sh → 自动执行备份脚本
```

关键代码位置：`EnterRouterMode.sh:184-228`

### 2.2 并发控制

使用PID文件机制防止多个备份进程同时运行：

```bash
PIDFILE="/tmp/EnterRouterMode.pid"

get_concurrency_lock() {
    # 最多等待6分钟获取锁
    # 检查PID文件是否存在且进程仍在运行
    # 获取锁后写入当前进程PID
}
```

## 3. 执行流程

### 3.1 主要步骤

1. **环境检查**:
   - 电池电量 ≥20%
   - SD卡是否插入
   - 读写权限检查

2. **配置管理**:
   - 设备配置: `EnterRouterMode/conf`
   - SD卡配置: `{SD_CARD}/FieldBackup.conf`

3. **核心操作**:
   ```
   设备设置 → SD卡设置 → 启用swap → rsync备份 → 禁用swap → LED状态更新
   ```

### 3.2 备份策略

#### 主备份模式 (Primary Mode)
- 条件: `SD_REPLICA=NO`
- 方向: SD卡 → USB硬盘
- 路径: `/SDMirrors/{SD_NAME}/`

#### 副本模式 (Replica Mode)
- 条件: `SD_REPLICA=YES`
- 方向: USB硬盘 → SD卡
- 用途: 创建SD卡副本

### 3.3 rsync参数

```bash
rsync \
    --recursive \           # 递归复制
    --times \              # 保留时间戳
    --prune-empty-dirs \   # 删除空目录
    --ignore-existing \    # 忽略已存在文件（增量备份）
    --stats \             # 显示统计信息
    --human-readable \    # 人类可读输出
    --log-file="$SYNC_LOG"  # 记录日志
```

## 4. 状态指示

### 4.1 LED控制

使用`pioctl`命令控制LED状态：

```bash
led_wink() {
    pioctl "status" "2"  # 闪烁
    pioctl "status" "3"  # 常亮
}
```

带重试机制，最多尝试3次。

## 5. 安全机制

### 5.1 数据安全

1. **只读检测**:
   ```bash
   sd_is_readonly() {
       # 检查/proc/mounts中的挂载选项
       # ro表示只读，rw表示可读写
   }
   ```

2. **写入确认**:
   ```bash
   sync         # 强制写入磁盘
   sleep 2      # 等待确保完成
   ```

3. **信号处理**:
   ```bash
   trap "cleanup" 0 1 2 3 6 14 15
   # 捕获SIGHUP SIGINT SIGQUIT等信号
   ```

### 5.2 错误处理

- 所有关键操作使用`|| true`防止脚本意外退出
- 详细的日志记录到`EnterRouterMode/log/`
- 异常时自动清理PID文件

## 6. 性能优化

### 6.1 内存管理

由于设备内存极其有限(64MB)，使用swap机制：

```bash
# rsync前启用swap
run bin/scripts/device-swapon.sh

# rsync后禁用swap
run bin/scripts/device-swapoff.sh
```

### 6.2 性能瓶颈

主要限制因素：
- MIPS单核CPU性能有限
- USB 2.0接口速度瓶颈 (~30MB/s理论值)
- 内存严重不足需要频繁swap

实测100GB数据备份约需60分钟。

## 7. 系统集成

### 7.1 文件修改

使用`add_mod()`辅助函数在系统文件中插入代码块：

- `/etc/passwd` - 用户管理
- `/etc/shadow` - 密码管理
- `/etc/init.d/` - 服务脚本

### 7.2 持久化

使用`/usr/sbin/etc_tools p`将修改提交到NVRAM，确保重启后保留。

## 8. 核心创新点

1. **自动化程度高**: 插入即备份，无需人工干预
2. **增量备份**: 使用rsync避免重复传输
3. **双向同步**: 支持Primary和Replica两种模式
4. **可靠性设计**: 完善的错误处理和状态指示

## 9. 存在的限制

1. **性能限制**: 受限于硬件性能，大容量备份耗时长
2. **单任务**: 不支持同时备份多张SD卡
3. **格式限制**: 主要支持FAT32/exFAT
4. **交互限制**: 无Web界面，仅通过LED指示状态

这些限制正是我们在OpenWrt R5S上改进的重点。