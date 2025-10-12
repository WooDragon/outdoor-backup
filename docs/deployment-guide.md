# 部署指南

## 1. 前置要求

### 1.1 硬件要求

- **路由器**: OpenWrt R5S 或类似ARM架构设备
- **存储**: 内置SSD或高速存储（建议≥256GB）
- **内存**: 建议≥2GB RAM
- **读卡器**: USB 3.0 SD卡读卡器

### 1.2 软件要求

- **OpenWrt版本**: 19.07或更高（推荐22.03+）
- **必需软件包**:
  - block-mount
  - kmod-usb-storage
  - rsync
  - kmod-fs-ext4
  - kmod-fs-exfat（可选）
  - kmod-fs-ntfs3（可选）

### 1.3 网络要求

- SSH访问到路由器
- 互联网连接（用于安装软件包）

## 2. 快速部署

### 2.1 一键部署脚本

```bash
#!/bin/sh
# 快速部署脚本 - 保存为 quick-deploy.sh

# 下载并执行安装
wget -O - https://raw.githubusercontent.com/your-repo/openwrt-sdcard-backup/main/deploy.sh | sh
```

### 2.2 手动部署步骤

#### 步骤1: SSH登录到路由器

```bash
ssh root@192.168.1.1
```

#### 步骤2: 更新软件包列表

```bash
opkg update
```

#### 步骤3: 安装必需软件包

```bash
# 核心包
opkg install block-mount kmod-usb-storage rsync

# 文件系统支持
opkg install kmod-fs-ext4 kmod-fs-vfat

# 可选：额外文件系统支持
opkg install kmod-fs-exfat kmod-fs-ntfs3
```

#### 步骤4: 下载项目文件

```bash
cd /opt
git clone https://github.com/your-repo/openwrt-sdcard-backup.git

# 或者使用wget下载压缩包
wget https://github.com/your-repo/openwrt-sdcard-backup/archive/main.tar.gz
tar xzf main.tar.gz
mv openwrt-sdcard-backup-main openwrt-sdcard-backup
```

#### 步骤5: 运行安装脚本

```bash
cd /opt/openwrt-sdcard-backup
chmod +x install.sh
./install.sh
```

## 3. 配置调整

### 3.1 验证LED路径

```bash
# 查找正确的LED路径
ls -la /sys/class/leds/

# 常见LED路径示例：
# R5S: /sys/class/leds/green:lan, /sys/class/leds/red:sys
# R4S: /sys/class/leds/green:lan1, /sys/class/leds/red:power
# x86: 可能没有LED，需要禁用LED功能
```

修改配置文件中的LED路径：
```bash
vi /opt/sdcard-backup/conf/backup.conf

# 修改LED_GREEN和LED_RED为实际路径
LED_GREEN="/sys/class/leds/你的绿色LED路径"
LED_RED="/sys/class/leds/你的红色LED路径"
```

### 3.2 调整备份路径

```bash
# 确认SSD挂载点
df -h | grep ssd

# 修改备份根目录
vi /opt/sdcard-backup/conf/backup.conf

# 修改BACKUP_ROOT为你的SSD路径
BACKUP_ROOT="/mnt/你的SSD路径/SDMirrors"
```

### 3.3 性能优化配置

```bash
# 编辑配置文件
vi /opt/sdcard-backup/conf/backup.conf

# 高性能设置（SSD + 充足内存）
BANDWIDTH_LIMIT=0        # 不限速
USE_COMPRESSION=no       # 不压缩，CPU换I/O
MAX_CONCURRENT=2         # 允许2个并发备份

# 保守设置（有限资源）
BANDWIDTH_LIMIT=50000    # 限制50MB/s
USE_COMPRESSION=yes      # 启用压缩
MAX_CONCURRENT=1         # 单任务
```

## 4. 功能验证

### 4.1 测试LED控制

```bash
# 测试绿色LED
echo "timer" > /sys/class/leds/green:lan/trigger
echo 100 > /sys/class/leds/green:lan/delay_on
echo 100 > /sys/class/leds/green:lan/delay_off
sleep 3
echo "none" > /sys/class/leds/green:lan/trigger

# 如果LED不闪烁，检查路径是否正确
```

### 4.2 测试热插拔检测

```bash
# 监控热插拔事件
logread -f | grep hotplug

# 插入SD卡，应该看到类似输出：
# hotplug[1234]: SD card detected: sda1
```

### 4.3 手动触发备份测试

```bash
# 直接运行备份脚本
/opt/sdcard-backup/scripts/backup-manager.sh add sda1 /dev/sda1

# 查看日志
tail -f /opt/sdcard-backup/log/backup.log
```

### 4.4 完整流程测试

1. 插入空白SD卡
2. 等待LED开始快闪
3. 查看日志确认配置文件创建
4. 拔出SD卡
5. 添加测试文件到SD卡
6. 重新插入SD卡
7. 等待LED变为常亮
8. 验证备份文件

```bash
# 验证备份
ls -la /mnt/ssd/SDMirrors/
ls -la /mnt/ssd/SDMirrors/*/
```

## 5. 日常使用

### 5.1 监控备份状态

```bash
# 实时查看备份日志
logread -f | grep sdcard-backup

# 查看历史备份记录
cat /opt/sdcard-backup/log/backup.log

# 查看特定SD卡的备份日志
ls -la /mnt/ssd/SDMirrors/.logs/
```

### 5.2 管理SD卡配置

每张SD卡根目录的`FieldBackup.conf`文件可以编辑：

```bash
# 在SD卡上编辑配置
vi /mnt/sdcard/FieldBackup.conf

# 修改友好名称
SD_NAME="我的Canon相机卡"

# 切换备份模式
BACKUP_MODE="REPLICA"  # 从SSD恢复到SD卡
```

### 5.3 查看备份统计

```bash
# 统计所有备份大小
du -sh /mnt/ssd/SDMirrors/*/

# 查看最近备份
ls -lt /mnt/ssd/SDMirrors/.logs/ | head -10

# 生成备份报告
cat /mnt/ssd/SDMirrors/.logs/report_*.txt
```

## 6. 故障排除

### 6.1 SD卡未被检测

**症状**: 插入SD卡后LED不闪烁

**排查步骤**:
```bash
# 1. 确认设备识别
dmesg | tail -20
lsusb
ls -la /dev/sd*

# 2. 手动挂载测试
mkdir -p /tmp/test
mount /dev/sda1 /tmp/test
ls -la /tmp/test
umount /tmp/test

# 3. 检查hotplug脚本
ls -la /etc/hotplug.d/block/
cat /etc/hotplug.d/block/90-sdcard-backup
```

### 6.2 备份失败

**症状**: LED红灯闪烁或备份中断

**排查步骤**:
```bash
# 1. 查看错误日志
grep ERROR /opt/sdcard-backup/log/backup.log

# 2. 检查存储空间
df -h /mnt/ssd

# 3. 检查文件权限
ls -la /mnt/ssd/SDMirrors/

# 4. 检查rsync错误
tail -50 /mnt/ssd/SDMirrors/.logs/backup_*.log
```

### 6.3 性能问题

**症状**: 备份速度慢

**优化方法**:
```bash
# 1. 监控系统资源
htop
iostat -x 1

# 2. 检查USB速度
lsusb -t  # 查看USB版本

# 3. 测试存储速度
dd if=/dev/zero of=/mnt/ssd/test bs=1M count=1000
dd if=/dev/sda1 of=/dev/null bs=1M count=1000

# 4. 优化rsync参数
vi /opt/sdcard-backup/conf/backup.conf
# 添加到RSYNC_EXTRA_OPTS
RSYNC_EXTRA_OPTS="--inplace --no-whole-file"
```

### 6.4 并发冲突

**症状**: 多张卡同时插入时有卡无法备份

**解决方法**:
```bash
# 1. 检查锁文件
ls -la /opt/sdcard-backup/var/lock/

# 2. 清理残留锁
rm -f /opt/sdcard-backup/var/lock/*.pid

# 3. 增加并发数（谨慎）
vi /opt/sdcard-backup/conf/backup.conf
MAX_CONCURRENT=2
```

## 7. 维护任务

### 7.1 日志清理

```bash
# 创建日志轮转脚本
cat > /etc/cron.daily/sdcard-backup-logrotate << 'EOF'
#!/bin/sh
LOG_DIR="/opt/sdcard-backup/log"
find $LOG_DIR -name "*.log" -mtime +30 -delete
find /mnt/ssd/SDMirrors/.logs -name "*.log" -mtime +60 -delete
EOF

chmod +x /etc/cron.daily/sdcard-backup-logrotate
```

### 7.2 备份验证

定期验证备份完整性：
```bash
#!/bin/sh
# 备份验证脚本
for dir in /mnt/ssd/SDMirrors/*/; do
    echo "Checking $dir"
    find "$dir" -type f -name "*.jpg" -o -name "*.raw" | wc -l
done
```

### 7.3 存储空间监控

```bash
# 添加到crontab
crontab -e

# 每天检查存储空间
0 2 * * * df -h /mnt/ssd | grep -q "9[0-9]%" && logger -t sdcard-backup "WARNING: Storage nearly full"
```

## 8. 卸载

### 8.1 完全卸载

```bash
cd /opt/openwrt-sdcard-backup
./uninstall.sh

# 手动清理（可选）
rm -rf /opt/openwrt-sdcard-backup
```

### 8.2 保留数据卸载

```bash
# 只删除程序，保留备份数据
rm -f /etc/hotplug.d/block/90-sdcard-backup
rm -rf /opt/openwrt-sdcard-backup

# 备份数据在 /mnt/ssd/SDMirrors/ 保留
```

## 9. 升级

### 9.1 在线升级

```bash
cd /opt/openwrt-sdcard-backup
git pull
./install.sh
```

### 9.2 手动升级

```bash
# 备份配置
cp /opt/openwrt-sdcard-backup/conf/backup.conf /tmp/

# 下载新版本
cd /opt
wget https://github.com/your-repo/openwrt-sdcard-backup/archive/main.tar.gz
tar xzf main.tar.gz

# 恢复配置
cp /tmp/backup.conf /opt/openwrt-sdcard-backup/conf/

# 重新安装
cd /opt/openwrt-sdcard-backup
./install.sh
```

## 10. 安全建议

### 10.1 权限设置

```bash
# 确保脚本权限正确
chmod 755 /etc/hotplug.d/block/90-sdcard-backup
chmod 755 /opt/openwrt-sdcard-backup/scripts/*.sh
chmod 644 /opt/openwrt-sdcard-backup/conf/*.conf
```

### 10.2 备份加密（可选）

```bash
# 使用LUKS加密备份分区
cryptsetup luksFormat /dev/sda2
cryptsetup open /dev/sda2 backup_crypt
mkfs.ext4 /dev/mapper/backup_crypt
mount /dev/mapper/backup_crypt /mnt/ssd
```

### 10.3 访问控制

```bash
# 限制备份目录访问
chmod 700 /mnt/ssd/SDMirrors
chown root:root /mnt/ssd/SDMirrors
```

## 11. 常见问题FAQ

**Q: 支持哪些SD卡格式？**
A: 支持FAT32、exFAT、NTFS、ext4等常见格式。

**Q: 可以同时备份多张SD卡吗？**
A: 默认不支持，可通过修改MAX_CONCURRENT配置启用。

**Q: 备份会删除已有文件吗？**
A: 不会，使用增量备份，只添加新文件。

**Q: 如何从备份恢复到SD卡？**
A: 修改SD卡上的FieldBackup.conf，设置BACKUP_MODE="REPLICA"。

**Q: 支持定时自动备份吗？**
A: 当前版本基于热插拔触发，不支持定时备份。

## 12. 获取帮助

- GitHub Issues: https://github.com/your-repo/openwrt-sdcard-backup/issues
- OpenWrt论坛: https://forum.openwrt.org/
- 项目文档: https://github.com/your-repo/openwrt-sdcard-backup/wiki