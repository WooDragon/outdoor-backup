# OpenWrt SD Card Backup - Build Guide

快速构建和部署 IPK 包的完整指南，专为 Lean's LEDE 优化。

## 前置要求

- 已配置好的 Lean's LEDE 构建环境
- 构建主机：Ubuntu 20.04+ 或 Debian 11+
- 至少 25GB 可用磁盘空间

## 构建流程（Linus 风格 - 直截了当）

### 1. 集成到构建系统

```bash
# 克隆到 package 目录
cd ~/lede/package
git clone https://github.com/your-repo/outdoor-backup.git

# 或者使用软链接（便于开发）
ln -s /path/to/outdoor-backup ~/lede/package/
```

### 2. 配置包

```bash
cd ~/lede

# 更新 feeds（如果添加了新包）
./scripts/feeds update -a
./scripts/feeds install -a

# 配置 menuconfig
make menuconfig

# 导航路径：
#   Utilities --->
#     <*> outdoor-backup
#
# 按 Y 选中，保存退出
```

### 3. 编译

```bash
# 单包编译（推荐，快速）
make package/outdoor-backup/compile V=s

# 完整编译（首次构建）
make -j$(nproc) V=s
```

### 4. 查找生成的 IPK

```bash
# 查找包位置
find bin/packages/ -name "outdoor-backup*.ipk"

# 典型路径：
# bin/packages/aarch64_generic/base/outdoor-backup_1.0.0-1_all.ipk
```

### 5. 部署到设备

```bash
# 方法 1：直接 SCP 安装
IPK_PATH=$(find bin/packages/ -name "outdoor-backup*.ipk" | head -1)
scp $IPK_PATH root@192.168.1.1:/tmp/
ssh root@192.168.1.1 "opkg install /tmp/outdoor-backup*.ipk"

# 方法 2：通过 Web 界面
# LuCI -> System -> Software -> Upload Package
```

## 开发工作流

### 快速迭代循环

```bash
# 1. 修改脚本
vim package/outdoor-backup/files/opt/sdcard-backup/scripts/backup-manager.sh

# 2. 增加版本号
vim package/outdoor-backup/Makefile
# PKG_RELEASE:=$(PKG_RELEASE + 1)

# 3. 重新编译
make package/outdoor-backup/clean
make package/outdoor-backup/compile V=s

# 4. 测试部署
scp $(find bin/packages/ -name "outdoor-backup*.ipk" | head -1) root@router:/tmp/
ssh root@router "opkg upgrade /tmp/outdoor-backup*.ipk"
```

### 调试技巧

```bash
# 不安装，直接测试脚本
scp -r package/outdoor-backup/files/opt/sdcard-backup root@router:/tmp/test-backup/
ssh root@router "sh -x /tmp/test-backup/scripts/backup-manager.sh add sda1 /devices/test"

# 查看包内容（不安装）
tar -tzf outdoor-backup_*.ipk
tar -xzf outdoor-backup_*.ipk -C /tmp/inspect/

# 验证脚本 POSIX 兼容性
shellcheck --shell=sh files/opt/sdcard-backup/scripts/*.sh
```

## 常见问题

### 编译失败

**问题**: `ERROR: package/outdoor-backup failed to build`

```bash
# 解决方案：
# 1. 检查 Makefile 语法
make package/outdoor-backup/compile V=s 2>&1 | less

# 2. 清理重建
make package/outdoor-backup/clean
rm -rf build_dir/target-*/outdoor-backup*
make package/outdoor-backup/compile V=s
```

### 依赖包缺失

**问题**: 安装时提示 `rsync not found`

```bash
# 原因：依赖包未编译进固件

# 解决方案 1：编译时包含依赖
make menuconfig
# Utilities -> rsync -> 选中

# 解决方案 2：设备上手动安装
ssh root@router "opkg update && opkg install rsync block-mount kmod-usb-storage"
```

### 脚本权限问题

**问题**: 脚本无法执行

```bash
# 检查 Makefile 中的 INSTALL_BIN
# 确保使用 $(INSTALL_BIN) 而不是 $(INSTALL_DATA)

# 手动修复（临时）
ssh root@router "chmod 755 /opt/sdcard-backup/scripts/*.sh"
ssh root@router "chmod 755 /etc/hotplug.d/block/90-sdcard-backup"
```

## 版本管理

### 修改版本号

编辑 `Makefile`:

```makefile
PKG_VERSION:=1.0.0    # 主版本.次版本.修订号
PKG_RELEASE:=1        # 包发布号（Makefile 变更递增）
```

**规则**:
- 功能变更：递增 `PKG_VERSION`
- Makefile/打包变更：递增 `PKG_RELEASE`
- 脚本 bugfix：递增 `PKG_VERSION` 修订号

### 构建不同架构

```bash
# ARM64 (R5S)
make package/outdoor-backup/compile V=s

# MIPS (老路由器)
# 需要在 menuconfig 中切换目标架构

# x86_64 (软路由)
# 同上切换架构
```

## 性能优化

### 减小包体积

1. **移除调试信息**（已默认）:
   ```makefile
   PKGARCH:=all  # 纯脚本包，无架构依赖
   ```

2. **移除不必要的文件**:
   ```bash
   # 不要打包 docs/ 和 .git/
   # Makefile 已自动排除
   ```

### 加速编译

```bash
# 使用 ccache
make menuconfig
# Advanced -> ccache -> enable

# 并行编译
make -j$(nproc) package/outdoor-backup/compile
```

## CI/CD 集成

### GitHub Actions 示例

```yaml
name: Build IPK

on: [push, pull_request]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Setup LEDE
        run: |
          git clone https://github.com/coolsnowwolf/lede.git
          cd lede
          ln -s $GITHUB_WORKSPACE package/outdoor-backup

      - name: Update Feeds
        run: |
          cd lede
          ./scripts/feeds update -a
          ./scripts/feeds install -a

      - name: Build Package
        run: |
          cd lede
          make package/outdoor-backup/compile V=s

      - name: Upload Artifact
        uses: actions/upload-artifact@v3
        with:
          name: ipk-package
          path: lede/bin/packages/*/base/outdoor-backup*.ipk
```

## 分发

### 创建本地 Feed

```bash
# 1. 生成包索引
cd ~/lede/bin/packages/aarch64_generic/base
~/lede/scripts/ipkg-make-index.sh . > Packages
gzip -c Packages > Packages.gz

# 2. 配置设备使用本地源
ssh root@router "cat >> /etc/opkg/customfeeds.conf" <<EOF
src/gz custom_feed http://your-server/packages
EOF

# 3. 安装
ssh root@router "opkg update && opkg install outdoor-backup"
```

## 总结

**核心流程（3 步）**:
```bash
1. make package/outdoor-backup/compile V=s
2. scp bin/packages/*/base/outdoor-backup*.ipk root@router:/tmp/
3. ssh root@router "opkg install /tmp/outdoor-backup*.ipk"
```

**记住**：
- ✅ 每次修改递增 `PKG_RELEASE`
- ✅ 用 `V=s` 查看详细错误
- ✅ 测试前先 `shellcheck` 验证
- ✅ 保持 POSIX 兼容（ash shell）

Good luck! 有问题看日志：`logread -f | grep sdcard-backup`
