# GitHub Actions 构建 IPK 包 - 经验总结

## 目标

**核心目标**：
- 自动构建 `outdoor-backup` 和 `luci-app-outdoor-backup` 两个 IPK 包
- 支持架构：x86_64 (软路由) + ARM64 (NanoPi R5S)
- 触发方式：推送 `v*.*.*` tag 时自动构建和发布
- 时间要求：< 10 分钟

**包的特点**：
- `PKGARCH:=all`：纯 Shell 脚本包，架构无关
- 依赖：`+rsync +block-mount +kmod-usb-storage +kmod-fs-*`
- 构建环境：OpenWrt/Lean's LEDE

## 核心问题

### 问题 1：包是纯脚本，但依赖 kmod

**矛盾**：
- 包本身不需要编译（纯 Shell）
- 但 Makefile 声明了 kmod 依赖
- 这些 kmod 在**编译时**不存在（只在目标设备的 feeds 中）

**表现**：
```makefile
DEPENDS:=+rsync +block-mount +kmod-usb-storage \
         +kmod-fs-ext4 +kmod-fs-vfat +kmod-fs-exfat +kmod-fs-ntfs3
```
- 构建系统尝试解析这些依赖
- kmod 包不在 SDK 的 feeds 中 → 构建失败

### 问题 2：构建环境复杂度

**OpenWrt 构建链**：
```
源码构建: LEDE 完整源码 → tools → toolchain → packages (50+ 分钟)
SDK 构建: 预编译 SDK → feeds → packages (5-10 分钟)
```

**实际情况**：
- 完整源码构建太慢（53 分钟+）
- SDK 构建需要正确的包结构

## 尝试的方案

### 方案 A：Lean's LEDE 完整源码构建

**实施**：
```yaml
- Clone Lean's LEDE 源码
- 链接包到 lede/package/
- 构建 tools → toolchain → package
```

**失败原因**：
1. **循环链接**：在项目内克隆 LEDE，然后链接项目到 LEDE → 循环
2. **缺少 toolchain**：跳过 tools/toolchain 构建 → 缺少 `flock` 等工具
3. **时间**：构建 tools + toolchain 需要 50+ 分钟

**关键错误**：
```
find: File system loop detected
bash: /lede/staging_dir/host/bin/flock: No such file or directory
```

### 方案 B：添加 tools/toolchain 构建

**实施**：
```yaml
- make tools/install
- make toolchain/install
- make package/outdoor-backup/compile
```

**失败原因**：
- **时间过长**：53 分钟后超时失败
- tools/toolchain 构建涉及大量依赖（perl, ncurses, etc.）

### 方案 C：官方 openwrt/gh-action-sdk

**实施**：
```yaml
- uses: openwrt/gh-action-sdk@v7
  env:
    ARCH: x86_64
    PACKAGES: outdoor-backup
```

**失败原因**：
1. **目录结构不匹配**：
   - SDK action 期望包在 `feeds/action/PACKAGE/Makefile`
   - 我们的包在根目录 `Makefile`
2. **无法自定义 feed 位置**

**关键错误**：
```
make: *** No rule to make target 'package/outdoor-backup/download'.  Stop.
grep: feeds/action/Makefile: No such file or directory
```

### 方案 D：手动下载 OpenWrt SDK（当前）

**实施**：
```yaml
- wget OpenWrt SDK 23.05.5
- 复制包到 sdk/package/
- 标准构建流程
```

**进度**：
- ✅ 下载 SDK 成功
- ✅ 准备包成功
- ✅ feeds 更新成功
- 🔄 编译中失败（12 分钟）

**待查错误**：编译阶段失败（具体错误未分析）

## 关键发现

### 1. 纯脚本包 vs 运行时依赖

**问题本质**：
- kmod 依赖是**运行时依赖**，不是**编译时依赖**
- 但 OpenWrt Makefile 的 `DEPENDS:=` 在编译时解析

**解决思路**：
1. **临时 Makefile**：构建时移除 kmod 依赖，只保留 `+rsync +block-mount`
2. **postinst 脚本**：在安装后检查并提示安装 kmod
3. **Release Notes**：明确说明手动安装依赖

### 2. SDK vs 完整源码

| 方式 | 时间 | 优势 | 劣势 |
|------|------|------|------|
| 完整源码 | 50+ min | 完全控制 | 太慢，CI 超时 |
| SDK | 5-10 min | 快速 | 包结构要求严格 |

**结论**：必须用 SDK，但需要适配包结构。

### 3. OpenWrt 包结构要求

**标准结构**（SDK 期望）：
```
package/
└── outdoor-backup/
    ├── Makefile
    └── files/
        └── ...
```

**我们的结构**（根目录）：
```
outdoor-backup/
├── Makefile
├── files/
├── luci-app-outdoor-backup/
└── ...
```

**冲突**：直接复制到 `sdk/package/` 应该可以工作（方案 D 在尝试）。

## 下一步方案

### 推荐方案：修复手动 SDK 方案

**步骤**：
1. **查看方案 D 的具体错误**：
   ```bash
   gh run view 18466278384 --log-failed
   ```

2. **可能的问题和修复**：

   **问题 2.1：kmod 依赖缺失**
   ```
   ERROR: package/outdoor-backup depends on kmod-fs-ntfs3, which does not exist
   ```
   **修复**：创建临时 Makefile，移除 kmod 依赖
   ```makefile
   DEPENDS:=+rsync +block-mount
   # kmod dependencies moved to postinst check
   ```

   **问题 2.2：luci 依赖缺失**
   ```
   ERROR: luci-app-outdoor-backup depends on luci-base
   ```
   **修复**：先只构建 `outdoor-backup`，成功后再添加 luci-app

   **问题 2.3：Makefile 语法错误**
   ```
   Makefile:XX: *** missing separator
   ```
   **修复**：检查 Makefile tab vs spaces

3. **验证构建**：
   - 构建成功后，在 R5S 上测试安装
   - 验证功能正常（手动安装 kmod 依赖）

### 备选方案：本地构建 + 手动上传

如果 CI 始终失败，可以：
1. 本地搭建 Lean's LEDE 环境
2. 本地编译 IPK
3. 手动创建 GitHub Release
4. 上传 IPK 文件

**优势**：
- 完全可控
- 可以调试

**劣势**：
- 不自动化
- 需要本地环境

## 关键教训

### 1. 简化数据结构优先

**错误做法**：
```yaml
# 复杂的 feed 配置
FEEDNAME: custom_feed
FEED_DIR: /custom/path
```

**正确做法**：
```bash
# 直接复制到标准位置
cp Makefile sdk/package/outdoor-backup/
```

### 2. 逐步验证，不要跳步

**错误做法**：
- 一次性添加两个包 + ShellCheck + Release

**正确做法**：
1. 先构建 outdoor-backup（核心包）
2. 成功后添加 luci-app
3. 成功后添加 ShellCheck
4. 最后添加 Release

### 3. 理解依赖的本质

**纯脚本包的依赖分两类**：
1. **打包时依赖**：无（不需要编译）
2. **运行时依赖**：rsync, kmod-*（用户安装时需要）

**处理方式**：
- Makefile 只声明编译时可用的依赖
- 运行时依赖在 postinst 检查或 README 说明

## 立即行动

1. ✅ **查看方案 D 错误日志**
2. ⏸️ **修复具体错误**（等待用户确认方向）
3. ⏸️ **决策**：继续修复 CI 还是切换到本地构建

---

**文档创建时间**：2025-10-13
**状态**：方案 D 失败（12 min），待查错误
**下一步**：查看日志 → 针对性修复
