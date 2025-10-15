# GitHub Actions CI/CD for OpenWrt IPK Packages

**通用指南：适用于所有 OpenWrt 包项目的 GitHub Actions 自动化构建**

本文档总结了从 12 次测试迭代中提炼的最佳实践，涵盖构建策略、ShellCheck 配置、权限管理和 Rate Limit 规避。

## 目录

1. [核心决策：SDK vs 完整源码](#核心决策sdk-vs-完整源码)
2. [Workflow 配置要点](#workflow-配置要点)
3. [ShellCheck 配置](#shellcheck-配置)
4. [常见问题解决](#常见问题解决)
5. [完整 Workflow 示例](#完整-workflow-示例)

---

## 核心决策：SDK vs 完整源码

### 问题
完整 OpenWrt 源码构建：
- 耗时 50+ 分钟（超过 GitHub Actions 免费配额）
- 下载 3GB+ 源码和依赖
- 编译整个工具链和系统

### 解决方案：使用 OpenWrt SDK

**OpenWrt SDK** 是预编译的交叉编译工具链，专为打包第三方应用设计：

| 指标 | 完整源码 | SDK |
|------|---------|-----|
| 下载大小 | 3GB+ | ~50MB |
| 构建时间 | 50+ 分钟 | 5-10 分钟 |
| 适用场景 | 内核开发、系统定制 | 应用打包 |

**SDK 下载示例**：
```bash
SDK_URL="https://downloads.openwrt.org/releases/23.05.5/targets/rockchip/armv8/openwrt-sdk-23.05.5-rockchip-armv8_gcc-12.3.0_musl.Linux-x86_64.tar.xz"
wget -q "$SDK_URL" -O sdk.tar.xz
tar -xf sdk.tar.xz
```

**SDK 目录结构**：
```
sdk/
├── package/          # 放置自定义包的 Makefile 和 files
├── scripts/feeds     # 管理外部软件源
├── bin/packages/     # 编译产物（IPK 文件）
└── staging_dir/      # 交叉编译工具链
```

---

## Workflow 配置要点

### 1. 权限配置（必需）

**问题**：从 2023 年起，GitHub Actions 的 `GITHUB_TOKEN` 默认为只读，创建 Release 会报 `403 Forbidden`。

**解决方案**：在需要写操作的 job 中显式声明权限：

```yaml
jobs:
  release:
    permissions:
      contents: write  # 允许创建 Release 和删除旧 Release
```

**完整权限列表**：
- `contents: write` - 创建/删除 Release、推送代码
- `issues: write` - 创建/关闭 Issue
- `pull-requests: write` - 创建/合并 PR

### 2. Artifacts 过滤（关键）

**问题**：使用 SDK 编译后，`sdk/bin/packages/` 会包含**所有依赖包**（100+ 个，94MB+），导致：
- 上传到 GitHub Release 时触发 **secondary rate limit**（403 错误）
- 污染 Release 资产列表

**错误示例**（收集所有 IPK）：
```bash
find sdk/bin/packages/ -name "*.ipk" -exec cp {} artifacts/ \;
# 结果：amdgpu-firmware.ipk, rsync.ipk, luci-base.ipk...（100+ 个）
```

**正确示例**（只收集目标包）：
```bash
find sdk/bin/packages/ \( -name "your-package_*.ipk" -o -name "luci-app-your-package_*.ipk" \) -exec cp {} artifacts/ \;
# 结果：仅你的包（2-3 个）
```

**完整过滤逻辑**：
```yaml
- name: Collect artifacts
  run: |
    mkdir -p artifacts
    # 只收集目标包，不收集依赖
    find sdk/bin/packages/ \( -name "outdoor-backup_*.ipk" -o -name "luci-app-outdoor-backup_*.ipk" \) -exec cp {} artifacts/ \;

    # 添加架构后缀
    cd artifacts
    for ipk in *.ipk; do
      mv "$ipk" "${ipk%.ipk}_${{ matrix.arch }}.ipk"
    done
```

### 3. 多架构构建矩阵

使用 GitHub Actions matrix 策略并行构建多架构：

```yaml
strategy:
  matrix:
    include:
      - arch: x86-64
        target: x86
        subtarget: 64
      - arch: aarch64_cortex-a53
        target: rockchip
        subtarget: armv8
```

**架构命名映射**：
| 硬件平台 | target | subtarget | arch 标识 |
|---------|--------|-----------|----------|
| NanoPi R5S/R4S | rockchip | armv8 | aarch64_cortex-a53 |
| x86_64 软路由 | x86 | 64 | x86-64 |
| MT7621 路由器 | ramips | mt7621 | mipsel_24kc |

---

## ShellCheck 配置

### 问题：BusyBox ash 不是 POSIX dash

OpenWrt 使用 **BusyBox ash**，它支持 bash 扩展特性：
- `exec 200>&-`（文件描述符 >9）
- `${var:0:8}`（字符串索引）

但 ShellCheck 的 `shell=ash` 模式基于 **dash**（严格 POSIX），会误报：
```
SC3023 (error): In dash, FDs outside 0-9 are not supported.
SC3057 (error): In dash, string indexing is not supported.
```

### 解决方案：使用 bash 模式

**`.shellcheckrc` 配置**：
```ini
# BusyBox ash 更接近 bash，不是 dash
shell=bash

# 禁用 OpenWrt 环境的误报
disable=SC2034  # START/STOP/USE_PROCD 由 procd 使用
disable=SC1090  # 动态 source 路径
disable=SC1091  # 不跟踪 source 文件
```

**Workflow 中使用**：
```yaml
- name: Run ShellCheck validation
  run: |
    # 只在 error 级别失败，忽略 style 建议
    shellcheck --severity=error \
      files/opt/outdoor-backup/scripts/*.sh \
      files/etc/hotplug.d/block/90-outdoor-backup \
      files/etc/init.d/outdoor-backup
```

**关键参数**：
- `--severity=error` - 只报告错误，不报告样式建议（SC2250, SC2248）
- `.shellcheckrc` - 自动读取项目根目录配置

---

## 常见问题解决

### 1. 403 Forbidden: Permission denied

**症状**：
```
⚠️ GitHub release failed with status: 403
Error: Too many retries.
```

**原因**：
- **权限不足**：未声明 `contents: write`
- **Rate limit**：短时间上传太多文件（>50 个）

**诊断**：
```bash
# 检查上传了多少文件
gh run view <RUN_ID> --log | grep "upload.*ipk"
```

**解决方案**：
1. 添加 `permissions: contents: write`
2. 过滤 artifacts，只收集目标包
3. 等待 5-10 分钟后重试（rate limit 重置）

### 2. ShellCheck 报告 SC3023/SC3057

**症状**：
```
SC3023 (error): In dash, FDs outside 0-9 are not supported.
SC3057 (error): In dash, string indexing is not supported.
```

**原因**：`.shellcheckrc` 使用 `shell=ash`（基于 dash）

**解决方案**：改用 `shell=bash`（BusyBox ash 的实际特性）

### 3. 构建超时（>50 分钟）

**原因**：使用完整 OpenWrt 源码

**解决方案**：改用 OpenWrt SDK

### 4. LuCI 应用打包失败

**症状**：
```
No rule to make target '../../luci.mk'
```

**原因**：试图使用 `luci.mk`（需要完整 LuCI feeds）

**解决方案**：使用标准 `package.mk`，手动安装文件：
```makefile
include $(INCLUDE_DIR)/package.mk  # 不是 ../../luci.mk

define Package/luci-app-xxx/install
    $(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
    $(INSTALL_DATA) ./luasrc/controller/*.lua $(1)/usr/lib/lua/luci/controller/
    # ... 手动安装所有文件
endef
```

---

## 完整 Workflow 示例

以下是经过 12 次迭代优化的完整 workflow：

```yaml
name: Build and Release IPK

on:
  push:
    tags:
      - 'v*.*.*'
  workflow_dispatch:

env:
  PACKAGE_NAME: your-package
  LUCI_PACKAGE_NAME: luci-app-your-package
  OPENWRT_VERSION: 23.05.5

jobs:
  build:
    name: Build IPK Packages
    runs-on: ubuntu-22.04
    strategy:
      matrix:
        include:
          - arch: x86-64
            target: x86
            subtarget: 64
          - arch: aarch64_cortex-a53
            target: rockchip
            subtarget: armv8

    steps:
      - name: Checkout code
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Install dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y build-essential libncurses5-dev gawk git libssl-dev gettext unzip file wget

      - name: Download OpenWrt SDK
        run: |
          SDK_URL="https://downloads.openwrt.org/releases/${{ env.OPENWRT_VERSION }}/targets/${{ matrix.target }}/${{ matrix.subtarget }}/openwrt-sdk-${{ env.OPENWRT_VERSION }}-${{ matrix.target }}-${{ matrix.subtarget}}_gcc-12.3.0_musl.Linux-x86_64.tar.xz"
          echo "Downloading SDK from: $SDK_URL"
          wget -q "$SDK_URL" -O sdk.tar.xz
          tar -xf sdk.tar.xz
          SDK_DIR=$(ls -d openwrt-sdk-* | head -1)
          mv "$SDK_DIR" sdk

      - name: Prepare packages
        run: |
          mkdir -p sdk/package/$PACKAGE_NAME
          cp Makefile sdk/package/$PACKAGE_NAME/
          cp -r files sdk/package/$PACKAGE_NAME/

          mkdir -p sdk/package/$LUCI_PACKAGE_NAME
          cp -r $LUCI_PACKAGE_NAME/* sdk/package/$LUCI_PACKAGE_NAME/

      - name: Update and install feeds
        run: |
          cd sdk
          ./scripts/feeds update -a
          ./scripts/feeds install -a

      - name: Configure SDK
        run: |
          cd sdk
          make defconfig

      - name: Build packages
        run: |
          cd sdk
          make package/$PACKAGE_NAME/compile V=s -j$(nproc)
          make package/$LUCI_PACKAGE_NAME/compile V=s -j$(nproc)

      - name: Run ShellCheck validation
        run: |
          shellcheck --severity=error \
            files/opt/$PACKAGE_NAME/scripts/*.sh \
            files/etc/hotplug.d/block/* \
            files/etc/init.d/$PACKAGE_NAME

      - name: Collect artifacts
        run: |
          mkdir -p artifacts
          # 只收集目标包，不收集依赖
          find sdk/bin/packages/ \( -name "${PACKAGE_NAME}_*.ipk" -o -name "${LUCI_PACKAGE_NAME}_*.ipk" \) -exec cp {} artifacts/ \;

          # 添加架构后缀
          cd artifacts
          for ipk in *.ipk; do
            mv "$ipk" "${ipk%.ipk}_${{ matrix.arch }}.ipk"
          done
          ls -lh

      - name: Upload build artifacts
        uses: actions/upload-artifact@v4
        with:
          name: openwrt-packages-${{ matrix.arch }}
          path: artifacts/*.ipk
          retention-days: 30

  release:
    name: Create Release
    needs: build
    if: startsWith(github.ref, 'refs/tags/')
    runs-on: ubuntu-22.04
    permissions:
      contents: write  # 必需：创建 Release

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Download all artifacts
        uses: actions/download-artifact@v4
        with:
          path: artifacts

      - name: Organize artifacts
        run: |
          mkdir -p release-assets
          # 只收集目标包
          find artifacts \( -name "${PACKAGE_NAME}_*.ipk" -o -name "${LUCI_PACKAGE_NAME}_*.ipk" \) -exec cp {} release-assets/ \;
          ls -lh release-assets/

      - name: Extract version from Makefile
        id: version
        run: |
          VERSION=$(grep "^PKG_VERSION:=" Makefile | cut -d'=' -f2)
          RELEASE=$(grep "^PKG_RELEASE:=" Makefile | cut -d'=' -f2)
          echo "version=${VERSION}-${RELEASE}" >> $GITHUB_OUTPUT

      - name: Create GitHub Release
        uses: softprops/action-gh-release@v1
        with:
          files: release-assets/*.ipk
          draft: false
          prerelease: false
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}

      - name: Clean up old releases
        uses: dev-drprasad/delete-older-releases@v0.3.0
        with:
          keep_latest: 5
          delete_tags: true
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

---

## 测试迭代总结

| 测试版本 | 问题 | 解决方案 |
|---------|------|---------|
| test1-4 | 完整源码构建超时 | 改用 OpenWrt SDK |
| test5-6 | 网络偶发故障 | 重试（外部问题） |
| test7 | ShellCheck 样式警告 | 添加 `--severity=error` |
| test8 | ash 模式太严格 | 改用 `shell=bash` |
| test9 | 403 权限不足 | 添加 `contents: write` |
| test10-11 | Rate limit（94MB） | 过滤 artifacts，只收集目标包 |
| test12 | ✅ 成功 | - |

---

## 参考资源

- [OpenWrt SDK 官方文档](https://openwrt.org/docs/guide-developer/toolchain/using_the_sdk)
- [GitHub Actions 权限文档](https://docs.github.com/en/actions/security-guides/automatic-token-authentication#permissions-for-the-github_token)
- [ShellCheck Wiki](https://www.shellcheck.net/wiki/)
- [GitHub API Rate Limits](https://docs.github.com/en/rest/overview/resources-in-the-rest-api#rate-limiting)

---

**维护者**：本文档总结自 outdoor-backup 项目的实际经验（test1-test12）
**最后更新**：2025-10-15
**适用版本**：OpenWrt 23.05+, GitHub Actions 2025
