# OpenWrt SD Card Backup - Build Guide

快速构建和部署 IPK 包的完整指南，专为 Lean's LEDE 优化。

## 可选日期包与 provider 边界

主体本地日期实现已有定向证据；有限范围 APPROVED 属于历史轮次，不扩大到本轮 Issue #65。本轮修后本地全量已通过，GitHub CI/SDK/IPK 和固件仍待验证（见 [implementation §6.6](docs/media-date-library-implementation.md#66-issue-65warning默认配置与日期状态展示)）；G1–G6 验收门槛仍未全部完成；不能据局部结果称为发布通过。以下是现行 recipe 接口，不是 SDK/IPK 或目标设备验收。修改或选择日期包前，应先读取 [现行实现与 G1–G6 边界](docs/media-date-library-implementation.md)。

本轮 [Issue #65](https://github.com/WooDragon/outdoor-backup/issues/65) 的源码配方版本为 core/date `1.5.0-r3`、LuCI `1.2.0-r3`；两份 recipe 的 `PKG_RELEASE` 均为 `3`。ExifTool provider 本轮未改变。该版本记录是当前配方事实，不证明 IPK 已构建或发布。旧 r1/r2 过程记录保持历史含义，不回写测试结果。新增行为、局部证据与未完成项应先读取 [implementation 的 Issue #65 验证节](docs/media-date-library-implementation.md#66-issue-65warning默认配置与日期状态展示)。

`outdoor-backup/Makefile` 同时定义 core 与可选 `outdoor-backup-media-date`。core 安装 shell runtime，镜像安装不引入 Perl。可选包安装 `media-date-plan.pl` 和 `lib/OutdoorBackup/MediaDate/` 下九个 `.pm`。其依赖为 core、外部 `exiftool` provider、`perl` 以及 recipe 声明的 `perlbase-essential/findbin/json-pp/digest/encode/fcntl/time/cwd/b/storable`。应核对目标 feed 的真实模块归属，不用宿主 Perl 的“核心模块”判断替代目标依赖。

ExifTool provider 应提供完整 `Image::ExifTool` 与 `File` 模块树，CLI 存在不充分。现有 guest 的 ExifTool 13.59 是经过 source hash 核验的源码模块加载证据，不是实际 provider IPK 安装或 SDK 交付。stock SDK 没有该外部 provider 时，可选 date 包构建仍 blocked；core mirror 包不因此拉入 Perl。provider 的真实 IPK/SDK 与 R5S rsync 3.4.1、目标 ext4/btrfs 和资源验收仍需独立证据。

在已注册本 feed 且外部 provider 可发现的 OpenWrt 构建树中，可核对以下形状。此文档任务没有执行它们。

```sh
./scripts/feeds update outdoor
grep -F -x 'Package: outdoor-backup-media-date' feeds/outdoor.index
./scripts/feeds install outdoor-backup-media-date
make menuconfig
# 显式选中 outdoor-backup-media-date；core/LuCI 的原有选择保持。
make package/feeds/outdoor/outdoor-backup/compile V=s
```

预期：可选包由与 core 相同的 canonical recipe 编译，不存在独立 `package/feeds/outdoor/outdoor-backup-media-date/compile` recipe 路径。应分别核对生成 IPK 的文件清单、运行依赖和实际目标模块加载。日期源码加载、synthetic install 或 feed 索引成功都不能代替真实 provider/IPK 验收。

构建前应保持 core 的 BusyBox setsid/flock 合同；既有 IPK 不能补齐缺失 applet。设备命令与日期启用流程应先读取 [media-date-library-operations.md](docs/media-date-library-operations.md)。下方旧构建输出及发布示例属于一般构建说明，不构成本地日期实现的 publish 授权。

## 前置要求

- 已配置好的 Lean's LEDE 构建环境
- 构建主机：Ubuntu 20.04+ 或 Debian 11+
- 至少 25GB 可用磁盘空间

## 构建流程（Linus 风格 - 直截了当）

### 1. 以本仓库作为本地 feed 集成

工作副本应位于 SDK 或 OpenWrt 源码树外。该工作副本不得包含 SDK 子树。`outdoor-backup/Makefile` 是核心包的唯一配方。`outdoor-backup/files` 是指向根目录 `files/` 的相对链接，根目录 `files/` 是唯一运行时源树。开发者应编辑这两个规范路径，不应编辑或复制第二份运行时内容。

```bash
# 在 SDK 或 OpenWrt 源码树外克隆干净工作副本。
git clone https://github.com/your-repo/outdoor-backup.git ~/src/outdoor-backup

# 将该工作副本注册为本地 feed。
cd ~/lede
printf 'src-link outdoor %s\n' "$HOME/src/outdoor-backup" >> feeds.conf.default

# 更新 feed，并确认两个包已被索引。
./scripts/feeds update outdoor
grep -F -x 'Package: outdoor-backup' feeds/outdoor.index
grep -F -x 'Package: luci-app-outdoor-backup' feeds/outdoor.index

# 安装 feed 中的两个包。
./scripts/feeds install outdoor-backup
./scripts/feeds install luci-app-outdoor-backup
```

### 2. 配置包

```bash
cd ~/lede

# 确认 feed 安装的配方可读。
test -r package/feeds/outdoor/outdoor-backup/Makefile
test -r package/feeds/outdoor/luci-app-outdoor-backup/Makefile

# 配置 menuconfig。
make menuconfig

# 导航路径：
#   Utilities --->
#     <*> outdoor-backup
#
# 按 Y 选中，保存退出。
```

### 3. 编译

```bash
# 编译 feed 安装的核心包和 LuCI 包。
make package/feeds/outdoor/outdoor-backup/compile V=s
make package/feeds/outdoor/luci-app-outdoor-backup/compile V=s

# 完整编译（首次构建）。
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
# 1. 在干净工作副本中修改规范源文件。
cd ~/src/outdoor-backup
vim files/opt/outdoor-backup/scripts/backup-manager.sh

# 2. 修改核心包的规范配方。
vim outdoor-backup/Makefile
# PKG_RELEASE:=$(PKG_RELEASE + 1)

# 3. 在 OpenWrt 树中清理并重新编译 feed 安装的核心包。
cd ~/lede
make package/feeds/outdoor/outdoor-backup/clean
make package/feeds/outdoor/outdoor-backup/compile V=s

# 4. 测试部署。
scp $(find bin/packages/ -name "outdoor-backup*.ipk" | head -1) root@router:/tmp/
ssh root@router "opkg upgrade /tmp/outdoor-backup*.ipk"
```

### 调试技巧

```bash
# 在干净工作副本中直接测试规范运行时源文件。
cd ~/src/outdoor-backup
scp -r files/opt/outdoor-backup root@router:/tmp/test-backup/
# 旧任意 add 路径不作为实际设备操作示例。
# 已安装 runtime 的 manual/initialize 形状以 docs/media-date-library-operations.md 为准。

# 查看包内容（不安装）
tar -tzf outdoor-backup_*.ipk
tar -xzf outdoor-backup_*.ipk -C /tmp/inspect/

# 验证脚本 POSIX 兼容性
shellcheck --shell=sh files/opt/outdoor-backup/scripts/*.sh
```

## 常见问题

### 编译失败

**问题**: `ERROR: package/feeds/outdoor/outdoor-backup failed to build`

```bash
# 解决方案：
# 1. 检查 Makefile 语法
make package/feeds/outdoor/outdoor-backup/compile V=s 2>&1 | less

# 2. 清理重建
make package/feeds/outdoor/outdoor-backup/clean
rm -rf build_dir/target-*/outdoor-backup*
make package/feeds/outdoor/outdoor-backup/compile V=s
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

编辑 `outdoor-backup/Makefile`:

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
make package/feeds/outdoor/outdoor-backup/compile V=s

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
make -j$(nproc) package/feeds/outdoor/outdoor-backup/compile
```

## CI/CD 集成

### GitHub Actions 自动构建和发布

项目已集成完整的 GitHub Actions 工作流，基于 **OpenWrt SDK**（而非完整源码）实现自动构建、质量检查和发布管理。

**完整指南**：详见 [GitHub Actions CI/CD 指南](docs/github-actions-ci-cd.md)（通用流程，适用于所有 OpenWrt 包项目）

#### 快速开始

**发布新版本**（3 步）：

```bash
# 1. 更新核心包版本号
vim outdoor-backup/Makefile
# PKG_VERSION:=1.1.0  # 新功能
# PKG_RELEASE:=1      # 重置为 1

# 2. 提交变更
git add outdoor-backup/Makefile
git commit -m "Bump version to 1.1.0"
git push

# 3. 创建并推送 tag（触发自动构建）
git tag v1.1.0
git push origin v1.1.0
```

**GitHub Actions 会自动**：
- 使用 OpenWrt SDK 构建两个架构的 IPK 包（ARM64, x86_64）
- 运行 ShellCheck 验证所有脚本
- 创建 GitHub Release 并上传 IPK 文件
- 清理旧 Release（保留最新 5 个）

#### 构建输出

**生成的包**（每个架构）：
```
- outdoor-backup_1.0.0-1_aarch64_cortex-a53.ipk  # ARM64 核心包
- outdoor-backup_1.0.0-1_x86-64.ipk              # x86_64 核心包
- luci-app-outdoor-backup_1.0.0-1_all.ipk        # WebUI（架构无关）
```

#### 关键配置

**构建策略**：
- ✅ 使用 **OpenWrt SDK**（~50MB, 5-10 分钟）
- ❌ ~~完整源码~~（3GB+, 50+ 分钟，已弃用）

**权限配置**（必需）：
```yaml
release:
  permissions:
    contents: write  # 创建 Release 和删除旧 Release
```

**Artifacts 过滤**（避免 rate limit）：
```bash
# 只收集目标包，不收集依赖（避免 94MB+ 文件上传）
find sdk/bin/packages/ \( -name "outdoor-backup_*.ipk" -o -name "luci-app-outdoor-backup_*.ipk" \) -exec cp {} artifacts/ \;
```

**ShellCheck 配置**：
```ini
# .shellcheckrc - BusyBox ash 使用 bash 模式
shell=bash          # 不是 ash（基于 dash，太严格）
disable=SC2034      # OpenWrt init 变量
disable=SC1090,SC1091  # 动态 source
```

#### 故障排查

**常见问题速查**：

| 错误 | 原因 | 解决方案 |
|------|------|---------|
| `403 Forbidden` | 权限不足或 rate limit | 添加 `contents: write`；过滤 artifacts |
| `SC3023/SC3057` | ShellCheck ash 模式太严格 | 改用 `shell=bash` |
| 构建超时 (>50分钟) | 使用完整源码 | 改用 OpenWrt SDK |
| `No rule to make target 'luci.mk'` | LuCI 应用依赖不存在 | 使用标准 `package.mk` |

**详细故障排查**：见 [CI/CD 指南 - 常见问题](docs/github-actions-ci-cd.md#常见问题解决)

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
1. make package/feeds/outdoor/outdoor-backup/compile V=s
2. scp bin/packages/*/base/outdoor-backup*.ipk root@router:/tmp/
3. ssh root@router "opkg install /tmp/outdoor-backup*.ipk"
```

**记住**：
- ✅ 每次修改递增 `PKG_RELEASE`
- ✅ 用 `V=s` 查看详细错误
- ✅ 测试前先 `shellcheck` 验证
- ✅ 保持 POSIX 兼容（ash shell）

Good luck! 有问题看日志：`logread -f | grep outdoor-backup`
