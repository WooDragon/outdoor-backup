# IPK 打包详解 - OpenWrt 包管理系统

深入理解 OpenWrt IPK 包的结构、原理和最佳实践。

## IPK 包本质（Linus 思维）

### 数据结构
```
IPK = control.tar.gz + data.tar.gz + debian-binary
```

- **control.tar.gz**: 元数据（依赖、版本、脚本）
- **data.tar.gz**: 实际文件（目标系统的文件树）
- **debian-binary**: 版本标识（固定为 "2.0"）

### 为什么这样设计？

**好品味** - 简单、可验证、向后兼容：
1. tar.gz 是最基础的压缩格式，任何 Unix 系统都能处理
2. 分离元数据和数据，便于依赖检查而无需解压全部内容
3. 兼容 Debian 的 dpkg 设计，减少学习成本

## Makefile 剖析

### 最小化 Makefile（只解决真实问题）

```makefile
include $(TOPDIR)/rules.mk          # 引入构建规则

# 包标识（核心数据）
PKG_NAME:=my-package
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk   # 引入包构建逻辑

# 包定义（告诉系统这是什么）
define Package/my-package
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=My Package
  DEPENDS:=+dependency1 +dependency2
endef

# 安装步骤（数据结构 → 目标位置）
define Package/my-package/install
  $(INSTALL_DIR) $(1)/usr/bin
  $(INSTALL_BIN) $(PKG_BUILD_DIR)/binary $(1)/usr/bin/
endef

$(eval $(call BuildPackage,my-package))
```

### 关键变量解析

| 变量 | 作用 | 示例 |
|------|------|------|
| `PKG_NAME` | 包名 | `openwrt-sdcard-backup` |
| `PKG_VERSION` | 上游版本 | `1.0.0` |
| `PKG_RELEASE` | 打包版本 | `1` (Makefile 变更递增) |
| `PKG_SOURCE` | 源码文件 | `app-v1.0.0.tar.gz` |
| `PKG_SOURCE_URL` | 下载地址 | `https://github.com/.../releases` |
| `PKG_HASH` | 校验和 | `sha256:abc123...` |

### 依赖语法

```makefile
DEPENDS:=+rsync                    # 运行时必需
DEPENDS:=+rsync +@IPV6             # 需要 IPv6 支持
DEPENDS:=+rsync +PACKAGE_curl:curl # 条件依赖
```

**规则**:
- `+package`: 必需依赖，自动安装
- `@feature`: 内核特性依赖
- `+PACKAGE_foo:bar`: 如果 foo 已安装，则依赖 bar

## 文件安装函数

### INSTALL_* 宏（消除特殊情况）

```makefile
# 创建目录
$(INSTALL_DIR) $(1)/etc/config

# 安装可执行文件（755 权限）
$(INSTALL_BIN) ./files/script.sh $(1)/usr/bin/

# 安装数据文件（644 权限）
$(INSTALL_DATA) ./files/config $(1)/etc/

# 安装配置文件（标记为 conffile）
$(INSTALL_CONF) ./files/app.conf $(1)/etc/config/
```

**为什么要用宏？**
- 自动处理权限（不需要手动 chmod）
- 自动处理所有者（避免打包机器的 uid/gid 泄露）
- 自动处理路径（$(1) 是临时安装目录）

### $(1) 的奥秘

```makefile
define Package/my-package/install
  $(INSTALL_DIR) $(1)/usr/bin      # $(1) = /tmp/staging_dir/target-xxx/my-package/
endef
```

**数据流**:
1. 文件安装到 `$(1)/usr/bin/app`
2. 打包时移除 `$(1)` 前缀
3. 设备上安装到 `/usr/bin/app`

## 安装/卸载脚本

### 生命周期钩子

```makefile
# 安装前执行（很少用）
define Package/my-package/preinst
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0  # 镜像构建时跳过
echo "Preparing installation..."
exit 0
endef

# 安装后执行（常用：初始化配置）
define Package/my-package/postinst
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/my-service enable
exit 0
endef

# 卸载前执行（常用：停止服务）
define Package/my-package/prerm
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/my-service stop
/etc/init.d/my-service disable
exit 0
endef

# 卸载后执行（清理数据）
define Package/my-package/postrm
#!/bin/sh
rm -rf /var/lib/my-package
exit 0
endef
```

**重要**:
- 必须以 `exit 0` 结束（否则安装失败）
- `[ -n "${IPKG_INSTROOT}" ]` 检测镜像构建环境
- 在镜像构建时跳过服务操作（因为没有运行的系统）

## Build/ 函数（编译控制）

### 纯脚本包（无需编译）

```makefile
define Build/Prepare
	# 空函数 - 没有源码需要准备
endef

define Build/Compile
	# 空函数 - 没有代码需要编译
endef
```

### 编译型包

```makefile
define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/* $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(MAKE) -C $(PKG_BUILD_DIR) \
		CC="$(TARGET_CC)" \
		CFLAGS="$(TARGET_CFLAGS)" \
		LDFLAGS="$(TARGET_LDFLAGS)"
endef
```

## 配置文件保护

### conffiles 机制

```makefile
define Package/my-package/conffiles
/etc/config/my-package
/opt/my-package/conf/settings.conf
endef
```

**效果**:
1. 升级时保留用户修改
2. 卸载时询问是否删除
3. 备份/恢复系统时自动包含

## 包分类和架构

### SECTION 和 CATEGORY

```makefile
SECTION:=net          # 内部分类（feed 组织）
CATEGORY:=Network     # menuconfig 显示位置
SUBMENU:=Firewall     # 子菜单（可选）
```

### 架构标识

```makefile
PKGARCH:=all          # 纯脚本/数据包，无架构依赖
# 或者不指定，自动为当前架构（如 aarch64_generic）
```

**规则**:
- `all`: Shell 脚本、配置文件、纯数据
- 架构相关: C/C++ 编译的二进制文件

## 调试技巧

### 查看包内容

```bash
# IPK 是 ar 归档
ar -t package.ipk
# 输出：
# debian-binary
# control.tar.gz
# data.tar.gz

# 解压查看
mkdir /tmp/inspect
cd /tmp/inspect
ar -x package.ipk
tar -tzf control.tar.gz  # 查看元数据
tar -tzf data.tar.gz     # 查看文件列表
```

### 模拟安装

```bash
# 解压到测试目录
tar -xzf data.tar.gz -C /tmp/test-install/

# 检查文件权限
find /tmp/test-install -ls

# 验证脚本语法
sh -n /tmp/test-install/etc/init.d/service
```

## 最佳实践（实用主义）

### 1. 简化复杂度

**坏**（过度设计）:
```makefile
define Build/Prepare
	$(call Build/Prepare/Default)  # 引入复杂逻辑
	custom_step_1
	custom_step_2
	...
endef
```

**好**（直接明了）:
```makefile
define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/* $(PKG_BUILD_DIR)/
endef
```

### 2. 消除特殊情况

**坏**（分支太多）:
```makefile
define Package/install
	if [ -f file1 ]; then
		install file1
	fi
	if [ -f file2 ]; then
		install file2
	fi
endef
```

**好**（统一处理）:
```makefile
define Package/install
	$(INSTALL_BIN) ./files/*.sh $(1)/usr/bin/
endef
```

### 3. 向后兼容优先

- 配置文件格式稳定（不要轻易改变）
- 路径不要变（`/opt/app` → `/usr/app` 会破坏用户环境）
- 依赖只增不减（新功能可选依赖，不要强制）

### 4. 错误处理

```makefile
define Package/postinst
#!/bin/sh
set -e  # 任何错误立即退出

# 但关键步骤允许失败
/etc/init.d/service enable || true

exit 0
endef
```

## 常见陷阱

### 陷阱 1: 路径硬编码

**错误**:
```makefile
$(INSTALL_BIN) /home/builder/files/app $(1)/usr/bin/
```

**正确**:
```makefile
$(INSTALL_BIN) ./files/app $(1)/usr/bin/
```

### 陷阱 2: 权限错误

**错误**:
```bash
cp ./script.sh $(1)/usr/bin/  # 继承源文件权限
```

**正确**:
```makefile
$(INSTALL_BIN) ./script.sh $(1)/usr/bin/  # 自动 755
```

### 陷阱 3: 忘记 exit 0

```makefile
define Package/postinst
#!/bin/sh
do_something
# 忘记 exit 0 → 安装失败！
endef
```

## 包版本演进示例

```
v1.0.0-1: 初始版本
  - 基础功能

v1.0.0-2: Makefile 修正
  - 修复依赖项
  - 代码不变，只改 Makefile

v1.0.1-1: Bugfix 版本
  - 修复脚本 bug
  - 增加错误处理

v1.1.0-1: 功能版本
  - 新增备份恢复功能
  - 新增配置选项

v2.0.0-1: 重大版本
  - 重写核心逻辑
  - 不兼容旧配置
```

## 参考资源

- [OpenWrt 包开发文档](https://openwrt.org/docs/guide-developer/packages)
- [procd init 脚本](https://openwrt.org/docs/guide-developer/procd-init-scripts)
- [UCI 配置系统](https://openwrt.org/docs/guide-user/base-system/uci)

## 总结

**IPK 打包的本质**：
1. 数据结构：Makefile 定义如何从源码到文件树
2. 无特殊情况：统一的安装宏，统一的路径处理
3. 向后兼容：配置保护，依赖声明，平滑升级

**记住**：
- 简洁胜于复杂
- 明确胜于隐晦
- 实用胜于理论

这就是好品味。
