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
vim package/outdoor-backup/files/opt/outdoor-backup/scripts/backup-manager.sh

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
scp -r package/outdoor-backup/files/opt/outdoor-backup root@router:/tmp/test-backup/
ssh root@router "sh -x /tmp/test-backup/scripts/backup-manager.sh add sda1 /devices/test"

# 查看包内容（不安装）
tar -tzf outdoor-backup_*.ipk
tar -xzf outdoor-backup_*.ipk -C /tmp/inspect/

# 验证脚本 POSIX 兼容性
shellcheck --shell=sh files/opt/outdoor-backup/scripts/*.sh
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
ssh root@router "chmod 755 /opt/outdoor-backup/scripts/*.sh"
ssh root@router "chmod 755 /etc/hotplug.d/block/90-outdoor-backup"
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

### GitHub Actions 自动构建和发布

项目已集成完整的 GitHub Actions 工作流，实现自动构建、质量检查和发布管理。

**工作流文件**：`.github/workflows/build-and-release.yml`

#### 触发条件

1. **自动触发**（推荐）：
   ```bash
   # 推送版本 tag 时自动构建和发布
   git tag v1.0.0
   git push origin v1.0.0
   ```

2. **手动触发**：
   - GitHub 仓库页面 → Actions → Build and Release IPK → Run workflow
   - 可选择是否创建 Release

#### 构建流程

```
1. 代码检出和环境准备
   ├─ Checkout 代码
   ├─ 清理磁盘空间（删除 .NET/Android SDK）
   └─ 安装依赖（build-essential, shellcheck, etc.）

2. LEDE 源码准备
   ├─ Clone Lean's LEDE (--depth 1)
   ├─ 链接 outdoor-backup 包
   ├─ 链接 luci-app-outdoor-backup 包
   ├─ 更新 feeds
   └─ 安装 feeds

3. 编译包
   ├─ 配置包选项（.config）
   ├─ 编译 outdoor-backup
   └─ 编译 luci-app-outdoor-backup

4. 质量检查
   └─ ShellCheck 验证所有脚本

5. 发布（仅 tag 触发）
   ├─ 生成 Release Notes
   ├─ 创建 GitHub Release
   ├─ 上传 IPK 文件
   └─ 清理旧 Release（保留最新 5 个）
```

#### 如何发布新版本

**完整流程**（3 步）：

```bash
# 1. 更新版本号
vim Makefile
# 修改 PKG_VERSION 或 PKG_RELEASE

# 示例：
# PKG_VERSION:=1.1.0    # 新功能
# PKG_RELEASE:=1        # 重置为 1

# 2. 提交变更
git add Makefile
git commit -m "Bump version to 1.1.0"

# 3. 创建并推送 tag（触发自动构建）
git tag v1.1.0
git push origin main
git push origin v1.1.0

# GitHub Actions 会自动：
# - 构建两个 IPK 包
# - 运行 ShellCheck
# - 创建 GitHub Release
# - 上传 IPK 文件
# - 清理旧 Release
```

#### Release 管理

**自动清理策略**：
- **保留数量**：最新 5 个 release
- **清理范围**：Release 本身 + 资产 + Git tag
- **清理时机**：新 Release 创建成功后
- **匹配模式**：只清理 `v*.*.*` 格式的 tag

**手动管理**（如果需要）：
```bash
# 删除本地 tag
git tag -d v1.0.0

# 删除远程 tag
git push origin :refs/tags/v1.0.0

# 重新打 tag（比如修复错误）
git tag v1.0.0 <commit-hash>
git push origin v1.0.0 --force
```

#### 构建输出

**生成的包**：
```
artifacts/
├── outdoor-backup_1.0.0-1_all.ipk           # 核心备份系统
└── luci-app-outdoor-backup_1.0.0-1_all.ipk  # WebUI 管理界面
```

**包特性**：
- `PKGARCH:=all`：架构无关，支持 ARM64/x86_64/MIPS
- 大小：约 10-20 KB（纯脚本）
- 依赖：自动声明，由 opkg 解析

#### 架构支持说明

虽然包是 `PKGARCH:=all`，但依赖的内核模块是架构相关的：

| 架构 | 状态 | 说明 |
|------|------|------|
| ARM64 | ✅ 完全支持 | NanoPi R5S/R4S/R6S 等 |
| x86_64 | ✅ 完全支持 | 软路由、虚拟机 |
| MIPS | ⚠️ 理论支持 | 未测试，但应该可用 |

**安装时**，opkg 会自动从对应架构的 feeds 下载依赖：
```bash
opkg install outdoor-backup_1.0.0-1_all.ipk
# ↓ 自动解析
# - rsync (架构相关)
# - kmod-usb-storage-aarch64 (ARM64)
# - kmod-fs-ntfs3-aarch64 (ARM64)
# - ...
```

#### CI 故障排查

**构建失败**：
```bash
# 1. 查看 Actions 日志
GitHub → Actions → 失败的工作流 → 查看详细日志

# 2. 常见问题
- ShellCheck 失败 → 修复脚本语法错误
- LEDE 克隆超时 → 重新运行 workflow
- 编译错误 → 检查 Makefile 语法
- 找不到 IPK → 检查编译日志，确认包名
```

**Release 未创建**：
```bash
# 确认触发条件
git tag -l  # 查看本地 tag
git ls-remote --tags origin  # 查看远程 tag

# 确保 tag 格式正确
git tag v1.0.0  # ✅ 正确
git tag 1.0.0   # ❌ 不触发（缺少 v 前缀）
```

**手动重新构建**：
```bash
# 删除失败的 Release
gh release delete v1.0.0 --yes

# 删除 tag
git push origin :refs/tags/v1.0.0
git tag -d v1.0.0

# 重新打 tag
git tag v1.0.0
git push origin v1.0.0
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

Good luck! 有问题看日志：`logread -f | grep outdoor-backup`
