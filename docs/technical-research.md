# 技术调研与验证清单

本文档列出了在实施过程中需要进一步调研和验证的技术点。

## 1. 硬件相关

### 1.1 R5S LED控制接口

**不确定点**: R5S的LED具体路径和控制方式

**需要验证**:
- LED设备在`/sys/class/leds/`下的确切路径
- 是否支持trigger模式（timer, heartbeat等）
- 亮度控制范围（0-255还是0-1）

**验证方法**:
```bash
# 列出所有LED设备
ls -la /sys/class/leds/

# 查看LED支持的触发器
cat /sys/class/leds/*/trigger

# 测试LED控制
echo "timer" > /sys/class/leds/green:lan/trigger
echo 100 > /sys/class/leds/green:lan/delay_on
echo 100 > /sys/class/leds/green:lan/delay_off
```

**备选方案**:
- 如果没有标准LED接口，考虑使用GPIO直接控制
- 可以通过`/sys/class/gpio/`导出GPIO并控制

### 1.2 SD卡识别机制

**不确定点**: 如何准确区分SD卡和其他USB存储设备

**需要验证**:
- USB读卡器在`/sys/block/`下的设备属性
- 是否有可靠的方法识别SD卡读卡器

**验证方法**:
```bash
# 插入SD卡后查看设备信息
udevadm info -a -p $(udevadm info -q path -n /dev/sda)

# 查看设备型号
cat /sys/block/sda/device/model
cat /sys/block/sda/device/vendor

# 使用lsusb查看USB设备信息
lsusb -v | grep -A 10 "Mass Storage"
```

**备选方案**:
- 基于设备大小判断（SD卡通常≤512GB）
- 让用户手动指定SD卡设备路径模式
- 使用设备UUID白名单机制

### 1.3 存储性能基准

**不确定点**: R5S实际的存储性能表现

**需要测试**:
- SSD顺序读写速度
- USB 3.0读卡器实际传输速度
- rsync在不同参数下的性能

**测试方法**:
```bash
# 测试SSD写入速度
dd if=/dev/zero of=/mnt/ssd/test.img bs=1M count=1000 conv=fdatasync

# 测试SD卡读取速度
dd if=/dev/sda1 of=/dev/null bs=1M count=1000

# 测试rsync传输速度
time rsync -av --progress /mnt/sdcard/ /mnt/ssd/test/
```

## 2. 软件兼容性

### 2.1 OpenWrt版本差异

**不确定点**: 不同OpenWrt版本间的兼容性

**需要验证**:
- hotplug.d机制在新版本中的变化
- block-mount包的版本差异
- udev规则的支持情况

**验证方法**:
```bash
# 查看OpenWrt版本
cat /etc/openwrt_release

# 检查hotplug支持
ls -la /etc/hotplug.d/

# 查看block-mount版本
opkg list-installed | grep block-mount
```

### 2.2 文件系统支持

**不确定点**: 各种文件系统的内核模块可用性

**需要验证**:
- exFAT支持（专利问题）
- NTFS写入支持（ntfs-3g vs kernel ntfs3）
- 特殊相机格式支持

**验证方法**:
```bash
# 列出可用的文件系统模块
opkg list | grep kmod-fs-

# 检查已加载的文件系统
cat /proc/filesystems

# 测试挂载不同格式
mount -t exfat /dev/sda1 /mnt/test
mount -t ntfs-3g /dev/sda1 /mnt/test
```

### 2.3 rsync版本和功能

**不确定点**: OpenWrt仓库中rsync的版本和编译选项

**需要验证**:
- rsync版本是否支持所需功能
- 是否需要自行编译优化版本
- 内存使用情况

**验证方法**:
```bash
# 查看rsync版本和功能
rsync --version

# 测试rsync内存使用
/usr/bin/time -v rsync -av /source/ /dest/

# 检查可用的rsync参数
rsync --help | grep -E "ignore-existing|stats|progress"
```

## 3. 系统集成

### 3.1 UCI配置集成

**不确定点**: 如何最佳地集成到OpenWrt的UCI系统

**需要研究**:
- 创建自定义UCI配置文件
- 集成到LuCI界面的方法
- 配置持久化机制

**验证方法**:
```bash
# 创建UCI配置
touch /etc/config/sdbackup

# 设置配置项
uci set sdbackup.global=config
uci set sdbackup.global.enabled='1'
uci set sdbackup.global.backup_path='/mnt/ssd/SDMirrors'
uci commit
```

### 3.2 日志集成

**不确定点**: 最佳的日志记录方式

**需要验证**:
- syslog vs 独立日志文件
- logread缓冲区大小
- 日志轮转机制

**验证方法**:
```bash
# 查看系统日志配置
cat /etc/config/system | grep log

# 测试logger输出
logger -t test "Test message"
logread | grep test

# 检查日志轮转
ls -la /etc/logrotate.d/
```

## 4. 性能优化

### 4.1 并发备份可行性

**不确定点**: R5S是否能处理多个并发备份

**需要测试**:
- CPU使用率
- 内存消耗
- I/O瓶颈

**测试方法**:
```bash
# 监控系统资源
htop

# I/O性能监控
iostat -x 1

# 并发rsync测试
rsync /source1/ /dest1/ &
rsync /source2/ /dest2/ &
```

### 4.2 内存管理

**不确定点**: 大文件传输时的内存使用

**需要验证**:
- rsync缓冲区大小优化
- 是否需要调整系统参数
- OOM killer行为

**验证方法**:
```bash
# 查看内存使用
free -m
cat /proc/meminfo

# 调整rsync缓冲区
rsync --sockopts=SO_SNDBUF=1048576,SO_RCVBUF=1048576

# 监控内存使用
watch -n 1 'free -m; ps aux | grep rsync'
```

## 5. 安全性考虑

### 5.1 权限和安全

**不确定点**: 脚本执行权限的最佳实践

**需要验证**:
- hotplug脚本的执行用户
- 文件权限设置
- SELinux/AppArmor影响

**验证方法**:
```bash
# 检查hotplug执行环境
echo "id: $(id)" > /tmp/hotplug_test.log

# 文件权限测试
ls -la /etc/hotplug.d/block/

# 检查安全模块
sestatus 2>/dev/null || echo "No SELinux"
```

### 5.2 并发安全

**不确定点**: PID文件锁的可靠性

**需要验证**:
- 文件锁在意外退出时的行为
- NFS/网络文件系统上的锁行为
- 死锁检测

**验证方法**:
```bash
# 测试PID文件锁
(echo $$ > /tmp/test.lock; sleep 100) &
cat /tmp/test.lock
kill -9 $(cat /tmp/test.lock)
# 检查锁文件是否残留
```

## 6. 用户体验

### 6.1 进度显示

**不确定点**: 如何最佳地显示备份进度

**需要研究**:
- rsync --progress输出解析
- 进度信息写入临时文件
- Web界面实时更新机制

**验证方法**:
```bash
# 解析rsync进度
rsync -av --progress /source/ /dest/ | \
    grep -o '[0-9]*%' | tail -1
```

### 6.2 错误报告

**不确定点**: 用户友好的错误提示

**需要设计**:
- 错误代码体系
- 错误恢复建议
- 通知机制

## 7. 测试计划

### 7.1 功能测试

- [ ] SD卡插入检测
- [ ] 自动挂载各种文件系统
- [ ] 配置文件创建和读取
- [ ] rsync基本备份功能
- [ ] LED状态指示
- [ ] 并发控制
- [ ] SD卡移除处理
- [ ] 错误恢复

### 7.2 性能测试

- [ ] 10GB数据备份时间
- [ ] 100GB数据备份时间
- [ ] CPU/内存使用监控
- [ ] 并发备份测试

### 7.3 压力测试

- [ ] 连续插拔SD卡
- [ ] 备份中断恢复
- [ ] 存储空间不足处理
- [ ] 只读SD卡处理
- [ ] 损坏的文件系统

### 7.4 兼容性测试

- [ ] 不同OpenWrt版本
- [ ] 不同文件系统格式
- [ ] 各种SD卡容量
- [ ] 不同读卡器型号

## 8. 后续改进方向

### 8.1 短期改进

1. **通知系统**: 备份完成后发送通知
2. **Web界面**: 基础的状态查看页面
3. **性能监控**: 实时速度显示
4. **日志分析**: 自动生成备份报告

### 8.2 长期规划

1. **云备份**: 二级备份到云存储
2. **增量压缩**: 节省存储空间
3. **版本管理**: 保留多个备份版本
4. **智能调度**: 根据系统负载调整备份策略
5. **手机App**: 远程监控和管理

## 9. 参考资源

- [OpenWrt Hotplug Documentation](https://openwrt.org/docs/guide-user/base-system/hotplug)
- [OpenWrt UCI System](https://openwrt.org/docs/guide-user/base-system/uci)
- [Block Mount Configuration](https://openwrt.org/docs/guide-user/storage/fstab)
- [LED Configuration](https://openwrt.org/docs/guide-user/base-system/led)

## 10. 验证清单总结

高优先级验证项：
1. R5S LED路径和控制方式
2. SD卡识别准确性
3. hotplug触发可靠性
4. rsync性能表现
5. 并发锁机制可靠性

这些项目需要在实际R5S硬件上验证后，根据结果调整实现方案。