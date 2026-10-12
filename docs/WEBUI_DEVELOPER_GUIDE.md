# Outdoor Backup WebUI 开发者文档

## 架构概述

### 系统架构图

```
┌─────────────────────────────────────────────────────────────────┐
│                        用户浏览器                                 │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐        │
│  │ 状态页面  │  │ 配置页面  │  │ 日志页面  │  │ 模态框    │        │
│  └─────┬────┘  └─────┬────┘  └─────┬────┘  └─────┬────┘        │
│        │             │             │             │              │
│        └─────────────┴─────────────┴─────────────┘              │
│                          ↕ AJAX / HTTP                          │
└─────────────────────────┬───────────────────────────────────────┘
                          │
┌─────────────────────────┴───────────────────────────────────────┐
│                    LuCI 框架（OpenWrt 路由器）                    │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  outdoor-backup.lua (Controller)                         │  │
│  │  ┌────────────┐  ┌────────────┐  ┌────────────┐         │  │
│  │  │ Page Routes│  │ API Routes │  │ Action Fns │         │  │
│  │  └────────────┘  └────────────┘  └────────────┘         │  │
│  └──────────────────────┬───────────────────────────────────┘  │
│                         │                                       │
│  ┌──────────────────────┴───────────────────────────────────┐  │
│  │  View Templates                    CBI Models            │  │
│  │  ┌──────────┐  ┌──────────┐      ┌──────────┐           │  │
│  │  │status.htm│  │ log.htm  │      │config.lua│           │  │
│  │  └──────────┘  └──────────┘      └──────────┘           │  │
│  └──────────────────────┬───────────────────────────────────┘  │
│                         │                                       │
└─────────────────────────┴───────────────────────────────────────┘
                          ↕ File I/O
┌─────────────────────────┴───────────────────────────────────────┐
│                      文件系统（数据层）                           │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  /opt/outdoor-backup/                                    │  │
│  │  ├── var/status.json         (状态文件，备份脚本写入)     │  │
│  │  ├── conf/aliases.json       (别名文件，WebUI + 脚本)     │  │
│  │  ├── conf/backup.conf        (全局配置)                   │  │
│  │  └── log/backup.log          (日志文件)                   │  │
│  └──────────────────────────────────────────────────────────┘  │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  /etc/config/outdoor-backup  (UCI 配置)                  │  │
│  └──────────────────────────────────────────────────────────┘  │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  /mnt/ssd/SDMirrors/         (备份数据)                   │  │
│  │  ├── {uuid}/                 (按 UUID 组织)               │  │
│  │  └── .logs/                  (rsync 详细日志)             │  │
│  └──────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

### 组件职责

| 组件 | 职责 | 技术 |
|------|------|------|
| **Controller** | 路由分发、API 处理、业务逻辑 | Lua |
| **View Templates** | HTML 渲染、JavaScript 交互 | HTML5/JS/CSS |
| **CBI Models** | UCI 配置管理、表单生成 | Lua (CBI) |
| **Data Files** | 状态存储、别名映射 | JSON |
| **Backup Scripts** | 核心备份逻辑、状态更新 | POSIX Shell |

---

## 技术栈

### 后端技术

| 技术 | 版本 | 用途 |
|------|------|------|
| **LuCI** | OpenWrt 19.07+ | Web 框架 |
| **Lua** | 5.1 | 后端逻辑 |
| **nixio** | - | 文件 I/O 库 |
| **luci.jsonc** | - | JSON 解析 |
| **UCI** | - | 配置系统 |

### 前端技术

| 技术 | 版本 | 用途 |
|------|------|------|
| **HTML5** | - | 页面结构 |
| **CSS3** | - | 样式设计 |
| **JavaScript** | ES5 | 动态交互（无框架） |
| **XHR** | LuCI 提供 | AJAX 请求 |

### 数据格式

| 格式 | 用途 | 示例 |
|------|------|------|
| **JSON** | 状态文件、别名文件 | status.json, aliases.json |
| **UCI** | 全局配置 | /etc/config/outdoor-backup |

---

## 目录结构

```
luci-app-outdoor-backup/
├── Makefile                              # IPK 包定义（80 行）
├── luasrc/
│   ├── controller/
│   │   └── outdoor-backup.lua           # 路由控制器（470 行）
│   ├── model/
│   │   └── cbi/outdoor-backup/
│   │       └── config.lua               # 配置页面 CBI（55 行）
│   └── view/outdoor-backup/
│       ├── status.htm                   # 状态页面（911 行）
│       └── log.htm                      # 日志页面（243 行）
├── root/
│   └── usr/share/
│       ├── luci/menu.d/
│       │   └── luci-app-outdoor-backup.json  # 菜单入口（受版本跟踪）
│       └── rpcd/acl.d/
│           └── outdoor-backup.json      # 已交付 RPCD read/write 权限
└── po/                                   # 国际化（待添加）
    ├── zh_Hans/outdoor-backup.po        # 简体中文
    └── templates/outdoor-backup.pot     # 翻译模板
```

### 文件功能说明

| 文件 | 行数 | 功能 |
|------|------|------|
| `outdoor-backup.lua` | 470 | 页面路由、API 接口、业务逻辑 |
| `config.lua` | — | UCI 配置表单（CBI），包括虚拟 Target storage 选择器 |
| `target.lua` | — | 固定 helper，读取并验证 target-list JSON |
| `status.htm` | 911 | 状态监控页面（HTML+JS） |
| `log.htm` | 243 | 日志查看页面（HTML+JS） |
| **总计** | **1679** | |

---

## Target storage CBI contract

配置页的 **Target storage** 是 CBI 虚拟字段。它不是新 API，也不需要新 ACL，且页面不会轮询存储。页面 reload 时，`target.lua` 读取并验证 `target-list.sh` 的完整 JSON。候选项只显示 `device`、`uuid`、`mount` 和 `fstype`。

`target-list.sh` 只返回已挂载、读写、direct physical、非系统盘且 UUID 有效并可验证的存储。USB SSD、NVMe 和匿名 Btrfs `0:N` 映射属于支持输入。rotational 属性不是 SSD 判据。未挂载或不符合这些条件的设备不能进入 CBI 选择器。

manual 默认值为 `Manual / keep current`。它保留 `target_mount`、`target_uuid` 和 `backup_root` 的手工语义，包括 empty UUID 的 `rmempty` 行为。选择模式生成 mount、UUID 和镜像根三个目标 formvalues；日期根的显示与提交另遵循下方日期 CBI 合同。现有 `Map.parse()` 和 `Map.save()` 仍是唯一的持久化路径。

选择器使用原生 `<select>`。它的 `id` 和 `name` 均遵循 CBI `cbid`。CBI 根据 `keylist` 和 `vallist` 渲染选项。`attr()` 转义 HTML 属性值。`pcdata()` 转义标签文本。实现不依赖 widget 内部 ID。JavaScript 只负责预览和字段显隐。保存时，服务端仍会重新枚举候选。它按 UUID 与 mount 匹配选择。

保存前，CBI 必须重新枚举，并以 UUID 加 mount 验证选择仍然有效。验证失败时不得保存新 target 值。有效选择会依据 defaults < legacy < UCI 和路径正规化，从旧 `backup_root` 保留合法相对后缀；无后缀时使用 `SDMirrors`。CBI 必须拒绝 target 外的 backup root，以及与 SD source mount 相交的 target。runtime target guard 仍是最终安全边界，不可把 status 当作锁。

这项功能不自动格式化或挂载介质，不修改 `fstab`，不迁移旧数据。管理员应先按 [README.md 的 Configure target storage](../README.md#configure-target-storage) 挂载目标。完整组件边界、脚本入口和测试证据范围以 [component-implementation.md](component-implementation.md) 为权威来源。

测试入口为 [`test-target-list.sh`](../test-target-list.sh)、[`test-luci-target-fd.sh`](../test-luci-target-fd.sh)、[`test-luci-target-selection.sh`](../test-luci-target-selection.sh) 和 [`test-target-selection-ui.js`](../test-target-selection-ui.js)。`test-luci-target-fd.sh` 使用真实 Lua `io.popen` 验证父子 FD 继承和核心目标守卫。`test-luci-target-selection.sh` 使用真实 `Map`、UCI 和模板引擎；测试隔离外层未改动的 chrome include。`test-target-selection-ui.js` 运行生产脚本和 DOM double，不是真机或浏览器 E2E。现有 target-device 与 LuCI target-config 回归也应保持通过。

---

## API 接口文档

本节是现行 HTTP 接口的权威说明，面向 Lua LuCI 开发者。源码为 [`outdoor-backup.lua`](../luci-app-outdoor-backup/luasrc/controller/outdoor-backup.lua)、[`security.lua`](../luci-app-outdoor-backup/luasrc/model/outdoor-backup/security.lua)、[`media.lua`](../luci-app-outdoor-backup/luasrc/model/outdoor-backup/media.lua) 和 [`status.htm`](../luci-app-outdoor-backup/luasrc/view/outdoor-backup/status.htm)。修改接口前应先读取这些文件，不用下方历史教学示例推导新动作。

所有 `/api/...` 路径相对于 `/cgi-bin/luci/admin/services/outdoor-backup`。handler 独立校验 session，而非只依赖菜单 ACL。读取需要 session 的 `uci/outdoor-backup/read`，写入需要 `uci/outdoor-backup/write`。无有效会话或权限时返回 403。mutation 仅 POST；方法错误返回 405，响应包含 `Allow: POST`。POST 表单 token 应与当前 `dispatcher.context.authtoken` 精确匹配，否则 403。

| 相对端点 | 方法 / 表单字段 | 结果与边界 |
|---|---|---|
| `/api/status` | GET | 返回现行 status.json；缺文件 404。不能用旧 snapshot 授权写操作。 |
| `/api/aliases` | GET | 返回 alias 对象；缺文件返回 version 1.0 空映射。 |
| `/api/alias/update` | POST：`token,uuid,alias,notes` | UUID 必填；alias/notes 可空，分别最多 256/1024 字节。参数错误 400，写入失败 500。成功 `{success:true}`。 |
| `/api/alias/delete` | POST：`token,uuid` | 不是 GET/DELETE；缺失/非法 UUID 400，不存在 404，写入失败 500。只删显示映射，不删媒体或来源 identity。 |
| `/api/cleanup/preview` | GET；不接收任意 root | 固定 adapter 读取有效配置，调用 manager cleanup-preview。读取权限只允许预览，不授权删除。 |
| `/api/cleanup/execute` | POST：`token,confirm_text` | confirm_text 应精确为“清空备份数据”。adapter 使用当前有效镜像根及 keep=1；浏览器不能提交 shell、force、源设备或任意根。 |

LuCI XHR.post 的第二参数是表单对象，不能传 JSON.stringify 字符串。handler 使用 `http.formvalue`；mutation 的 Content-Type 为 `application/x-www-form-urlencoded`。应用前端从授权页面生成的 hidden token 字段取值。读取端点也不接受无权限绕过。

清理的 preview/execute 每次独立取得 manager service lease、owner 和 target-only FD 9。manager 在删除前检查精确当前镜像根、全部祖先及全部子树。preview 的 `version:1,layout:"mirror",backup_root,target_uuid,cards,total_size_bytes,total_cards` 经过 adapter 的 exact schema 校验；每个 card 含 `uuid,display_name,size_bytes,path`。`size_bytes` 来自 du 估算，不是删除后的释放字节承诺。preview 结束后释放 owner，execute 重新检查，不将旧 preview 当能力凭证。

清理失败返回 `{error,exit_code}`，代码 1/2 映射 HTTP 400，3 映射 500，4/5/130/143 映射 409。成功 execute 返回 `{success:true}`。date 当前布局、磁盘日期状态、date 根/bucket 和切回 mirror 后的受保护状态均由后端拒绝。CLI force 只确认意图，不跳过检查。删除集、保留项及 CLI 形状应先读取 [media-date-library-operations.md](media-date-library-operations.md#6-镜像清理的现行入口)。

没有 `/api/trigger`、WebUI initialize、手动 checksum endpoint、取消按钮或后台队列。manual/initialize 是 root CLI；修改这层边界属于独立功能，不把旧教学草图当现成接口。

### 日期任务与状态合同

status.json 保持 `version:"1.0"` 与既有 `current_backup/storage/history`。`status.sh` 仍是唯一 writer，按原子快照发布。旧 15 参数 write_status 兼容；第 16 参数为 live_progress，第 17 参数为可选 task。日期 task 使用下列 exact schema：

| 字段 | 形状 / 含义 |
|---|---|
| `version` | 数字 1，不是外层 version 字符串。 |
| `layout` | `mirror` 或 `date`；当前 date manager 写 date。 |
| `phase` | `planning`、`transferring`、`finalizing`。 |
| `comparison_mode` | `quick` 或 `checksum`；只代表本次任务。 |
| `archive` | `files_total,routes_total,excluded_total,undated_total`；非负计数或 null。routes_total 可含历史位置，不是复制完成数。 |
| `warnings` | 数组；每项为固定 `code,count`，无原始 metadata 或路径 payload。 |
| `replaced` | `files_count,path`；计数或路径可 null，表示未知。路径为稳定显示路径，不暴露 FD 内部路径。 |

planning/finalizing 不显示虚构进度或 ETA。transferring 从既有同步 runner wait loop 采样；live_progress 的 entries 包含目录，files_known 决定普通文件数是否可显示。运行百分比最高为 99，completed 只在 manager 最终门通过后发布。history 保持 UUID 唯一、最多 20 个最新终态；task 随终态保留。所有 history/task 文本字段应转义，不能把路径、别名或警告插入未转义 HTML。

`status.htm` 用生产 DOM renderer 分区显示“日期归档信息”“元数据提示”和“旧版本保留”，并把技术详情、保留路径及比较帮助折叠。Accepted files 是本次接受文件，Retained routes 包含历史固定位置，不是已复制完成数。null 计数显示 `Unknown / 未知`，不转为 0，也不转为任务错误。旧版本计数分别显示未知、0 或正数；保留目录存在不证明实际已有旧文件，保留文件也不证明内容不同。

Warning 和 Undated 是日期诊断，不等于任务失败；结果仍由主状态决定。已知 warning code 有友好说明；较新 producer 的未知非空 code 只在 text-safe 技术详情显示，不抹掉其余合法 task。畸形 task 显示信息不可用并保留来源身份，不捏造 phase 或进度。mirror、缺 task 的旧 snapshot 和历史刷新继续兼容，不残留日期分区。界面没有新增写操作。

默认 quick 可能跳过同 size/mtime 的内容变化。mtime-only 可产生同内容 retained old file。checksum 只核验当前 source 对应 target，不审计历史全库；配置/API snapshot 不改变正在运行的任务。

### 日期 CBI 与日志边界

[`config.lua`](../luci-app-outdoor-backup/luasrc/model/cbi/outdoor-backup/config.lua) 管理 backup_layout、library_root 和 archive_offset_minutes。date 保存时加载真实 helper 能力/schema，检查目标直接子根与隔离，读取既有 policy 并拒绝在线 offset 改变。新库空 offset 合法，显示默认值；既有库空 offset 显示并继承 policy，包括 `0`。原规范整数验证保持。默认值及运行期选取时机应先读取 [implementation 配置合同](media-date-library-implementation.md#1-配置合同)。

`library_root.cfgvalue` 可显示 `target_mount/MediaLibrary`，但显示不是持久 intent。没有日期 intent 的 mirror 保存应保持空 `library_root.formvalue`；不能把自动显示值写回 UCI 或据此拒绝合法同名镜像根。date 的默认根通过 `forcewrite` 正常保存。offset 未配置且提交值等于显示默认值时，`formvalue` 保持空，保留新库默认或既有 policy 的继承分支。

`target-selection.htm` 从已验证的 `selection_mounts` 与 `selection_roots` 预览路径。未被手工修改的常规日期根随目标选择或手工 mount 改变；常规镜像根随手工 mount 改变。自定义路径不由 JavaScript 覆盖。目标选择器仍按合法旧 mirror 后缀生成镜像根；服务端 `Map.parse()` 重新枚举并验证目标及完整表单，不能用预览替代安全校验。CBI 保存不创建目录、库或卡配置，不执行备份或迁移。CBI submit 的 write/session/POST/token 检查保持，运行时目标/来源守卫仍是最终准入权威。

[`log.htm`](../luci-app-outdoor-backup/luasrc/view/outdoor-backup/log.htm) 的 Download Full Log 标签保留旧名，但当前行为仅从已授权显示的 textContent 创建 text/plain Blob。没有原始 backup.log URL 或未经权限校验的全文件下载接口。日志页面的读取 handler 校验 read 权限，服务端 pcdata 和前端文本转义保留。

主体本地实现已有定向证据；有限范围 APPROVED 属于历史轮次，不扩大到本轮 Issue #65。修后全量、root CI、SDK 与固件尚未执行。隔离 guest 使用 root 启动的测试专属 ubusd/rpcd，并只清理自己拥有的 PID 和 socket。CI 准备真实 luci-compat、ubusd、ubus、rpcd 和 libuci-lua；权限验证使用真实 RPC session/access，不 mock 授权。已有 real RPC/CBI/XHR/DOM 场景不等于 browser/full CGI auth 或真机端到端。证据与 G1–G6 应先读取 [implementation 验证节](media-date-library-implementation.md#6-验收证据的边界)；本次范围不验收 PhotoPrism 自动 index。

---

## 数据结构

### status.json

**路径**：`/opt/outdoor-backup/var/status.json`

**更新频率**：manager 在阶段转换和同步 wait loop 采样时发布；旧示意对象未列出可选 live_progress/task，应先读取上方现行状态合同。

**字段说明**：

```json
{
  // 版本号（用于未来兼容性）
  "version": "1.0",

  // 最后更新时间（Unix 时间戳）
  "last_update": 1728825600,

  // 存储空间信息
  "storage": {
    "root": "/mnt/ssd/SDMirrors",       // 备份根目录
    "total_bytes": 512000000000,        // 总空间（字节）
    "used_bytes": 128000000000,         // 已用空间（字节）
    "free_bytes": 384000000000          // 可用空间（字节）
  },

  // 当前备份任务（如果没有则为 null）
  "current_backup": {
    "active": true,                     // 是否活跃
    "uuid": "550e8400-...",             // SD 卡 UUID
    "name": "Canon_5D4_Card1",          // 显示名称（别名或 UUID 前缀）
    "device": "sda1",                   // 设备名称
    "started_at": 1728825000,           // 开始时间（Unix 时间戳）
    "progress_percent": 45,             // 进度百分比（0-100）
    "files_total": 1200,                // 总文件数
    "files_done": 540,                  // 已完成文件数
    "bytes_total": 52428800000,         // 总大小（字节）
    "bytes_done": 23592960000,          // 已传输大小（字节）
    "speed_bytes_per_sec": 157286400    // 传输速度（字节/秒）
  },

  // 备份历史（数组，按时间倒序）
  "history": [
    {
      "uuid": "550e8400-...",           // SD 卡 UUID
      "name": "Canon_5D4_Card1",        // 显示名称
      "last_backup_at": 1728825000,     // 最后备份时间
      "status": "completed",            // 状态：completed/running/error
      "files_count": 1200,              // 文件数
      "bytes_total": 52428800000,       // 总大小
      "backup_path": "/mnt/ssd/...",    // 备份路径
      "error_message": null             // 错误信息（如果有）
    }
  ]
}
```

**状态值**：

| 字段 | 可能值 | 说明 |
|------|--------|------|
| `status` | `completed` | 备份成功完成 |
| | `running` | 正在备份 |
| | `error` | 备份失败 |

---

### aliases.json

**路径**：`/opt/outdoor-backup/conf/aliases.json`

**写入者**：
- WebUI（用户编辑别名）
- backup-manager.sh（更新 last_seen）

**字段说明**：

```json
{
  // 版本号
  "version": "1.0",

  // 别名映射（UUID 作为键）
  "aliases": {
    "550e8400-e29b-41d4-a716-446655440000": {
      "alias": "Canon_5D4_Card1",       // 用户设置的别名（可为空）
      "notes": "佳能相机主卡，128GB",    // 备注（可为空）
      "created_at": 1728825600,         // 创建时间（Unix 时间戳）
      "last_seen": 1728900000           // 最后插入时间（Unix 时间戳）
    }
  }
}
```

**设计原则**：
- **中心化管理**：存储在路由器，独立于 SD 卡
- **零依赖**：备份逻辑不依赖别名，删除文件不影响功能
- **数据 vs 配置**：别名是用户数据，不是系统配置（不用 UCI）

---

## 开发指南

### 如何添加新功能

#### 现行边界：root CLI 与 WebUI 分离

旧“添加手动触发”草图使用 UUID-only manual、GET mutation 和任意拼接命令，与现行 manager/HTTP 合同不符，不作为开发或设备操作示例。当前 WebUI 仅监控、配置、alias 和受管镜像 cleanup。需要手动任务时，应先读取 [root CLI 操作](media-date-library-operations.md#4-执行本次手动任务)。新增 WebUI 动作需独立定义权限、来源身份、任务快照和生命周期，不复用旧草图。

---

### 如何修改现有功能

#### 场景：修改状态刷新频率（从 10 秒改为 5 秒）

**文件**：`luasrc/view/outdoor-backup/status.htm`

**修改位置**：第 696 行

```javascript
// 修改前
XHR.poll(10, '<%=url("admin/services/outdoor-backup/api/status")%>', null,
    function(x, data) {
        if (data) {
            currentStatus = data;
            updateCurrentBackup(data.current_backup);
            updateStorageInfo(data.storage);
            updateHistoryTable(data.history);
        }
    }
);

// 修改后
XHR.poll(5, '<%=url("admin/services/outdoor-backup/api/status")%>', null,  // 10 → 5
    function(x, data) {
        if (data) {
            currentStatus = data;
            updateCurrentBackup(data.current_backup);
            updateStorageInfo(data.storage);
            updateHistoryTable(data.history);
        }
    }
);
```

**注意事项**：
- 过高的刷新频率会增加 CPU 负载
- 建议保持 5-10 秒之间
- 不要低于 3 秒（可能导致路由器卡顿）

---

### 代码规范

#### Lua 代码规范

```lua
-- 1. 缩进：4 空格
function api_status()
    local json = require "luci.jsonc"
    local fs = require "nixio.fs"

    -- 2. 变量命名：snake_case
    local status_file = "/opt/outdoor-backup/var/status.json"
    local content = fs.readfile(status_file)

    -- 3. 字符串：双引号
    luci.http.prepare_content("application/json")

    -- 4. 条件判断：空格分隔
    if content then
        luci.http.write(content)
    else
        luci.http.status(404)
        luci.http.write_json({error = "Status file not found"})
    end
end

-- 5. 函数注释：Lua Doc 风格
--[[
api_status - GET /api/status
Returns: status.json content with backup progress and history
Response: JSON object with current_backup, storage, history fields
]]--
```

#### JavaScript 代码规范

```javascript
// 1. 缩进：4 空格
function formatBytes(bytes) {
    // 2. 变量命名：camelCase
    var kiloByte = 1024;
    var sizes = ['B', 'KB', 'MB', 'GB', 'TB'];

    // 3. 字符串：单引号
    if (bytes === 0) return '0 B';

    // 4. 条件判断：空格分隔
    var index = Math.floor(Math.log(bytes) / Math.log(kiloByte));

    // 5. 返回值：清晰明确
    return (bytes / Math.pow(kiloByte, index)).toFixed(2) + ' ' + sizes[index];
}

// 6. 函数注释：JSDoc 风格
/**
 * Format bytes to human-readable string
 * @param {number} bytes - Byte count
 * @returns {string} Formatted string (e.g., "48.8 GB")
 */
```

#### HTML 代码规范

```html
<!-- 1. 缩进：4 空格 -->
<fieldset class="cbi-section">
    <legend><%:Current Backup%></legend>

    <!-- 2. 属性：双引号 -->
    <div id="current-backup" class="info-box">
        <!-- 3. LuCI 翻译：<%: ... %> -->
        <p><%:No backup in progress%></p>
    </div>
</fieldset>

<!-- 4. 注释：简洁清晰 -->
<!-- Modal: Edit Alias -->
<div id="alias-modal" class="outdoor-backup-modal">
    <!-- ... -->
</div>
```

---

### 测试方法

#### 单元测试（Lua）

```lua
-- 测试文件：tests/test_controller.lua

local controller = require "luci.controller.outdoor-backup"

-- 测试 UUID 格式验证
function test_uuid_format()
    local valid_uuid = "550e8400-e29b-41d4-a716-446655440000"
    local invalid_uuid = "550e8400"

    assert(valid_uuid:match("^%x%x%x%x%x%x%x%x%-..."), "Valid UUID should match")
    assert(not invalid_uuid:match("^%x%x%x%x%x%x%x%x%-..."), "Invalid UUID should not match")
end

-- 运行测试
test_uuid_format()
print("All tests passed!")
```

#### 集成测试（Shell）

```bash
#!/bin/sh
# 测试脚本：tests/test_api.sh

# 测试 API 端点
test_api_status() {
    echo "Testing GET /api/status..."

    curl -s "http://192.168.1.1/cgi-bin/luci/admin/services/outdoor-backup/api/status" \
        | jq -e '.version == "1.0"' > /dev/null

    if [ $? -eq 0 ]; then
        echo "✓ API status works"
    else
        echo "✗ API status failed"
        exit 1
    fi
}

# 运行测试
test_api_status
echo "All API tests passed!"
```

#### 前端测试（浏览器控制台）

```javascript
// 测试 AJAX 请求
function testStatusAPI() {
    XHR.get('/cgi-bin/luci/admin/services/outdoor-backup/api/status', null,
        function(x, data) {
            console.log('Status API response:', data);
            if (data && data.version === '1.0') {
                console.log('✓ Status API works');
            } else {
                console.error('✗ Status API failed');
            }
        }
    );
}

testStatusAPI();

// 测试别名更新
function testAliasUpdate() {
    var testData = {
        uuid: '550e8400-e29b-41d4-a716-446655440000',
        alias: 'Test Card',
        notes: 'Test notes'
    };

    XHR.post('/cgi-bin/luci/admin/services/outdoor-backup/api/alias/update',
        {token: csrfToken(), uuid: testData.uuid, alias: testData.alias, notes: testData.notes},
        function(x, result) {
            console.log('Alias update result:', result);
            if (result && result.success) {
                console.log('✓ Alias update works');
            } else {
                console.error('✗ Alias update failed');
            }
        }
    );
}

testAliasUpdate();
```

### 状态页弹框样式与交互契约

`status.htm` 的四个弹框应使用 `outdoor-backup-modal`、`outdoor-backup-modal-content`、`outdoor-backup-modal-header` 和 `outdoor-backup-modal-body` 专属 class，不依赖 LuCI 主题的通用 `modal*` class。移动端规则也应使用专属 class。

别名编辑、清理预览和清理确认弹框还应使用 `outdoor-backup-modal-close` 与 `outdoor-backup-modal-footer`。进度弹框没有关闭控件或 footer，必须保持该结构。四个弹框共用遮罩点击关闭行为。点击弹框内容不应关闭弹框。弹框 ID、显示/关闭方式及清理确认流程应保持原样。

`node test-status-modal.js` 直接执行页面脚本并检查 CSS 隔离与交互。该测试不验证真实 LuCI 主题的视觉效果。真实主题下的视觉验收和真机浏览器 E2E 尚未执行。

---

## 部署指南

### 编译 IPK 包

#### 1. 配置构建环境（Lean's LEDE）

```bash
# 进入 OpenWrt 源码目录
cd ~/lede

# 克隆 WebUI 包到 feeds
cd package
git clone https://github.com/your-repo/luci-app-outdoor-backup.git

# 更新 feeds
cd ~/lede
./scripts/feeds update -a
./scripts/feeds install -a
```

#### 2. 编译包

```bash
# 方法 1：单独编译（推荐）
make package/luci-app-outdoor-backup/compile V=s

# 方法 2：包含在固件编译中
make menuconfig
# 选择：LuCI → Applications → luci-app-outdoor-backup
make -j$(nproc)
```

#### 3. 查找生成的 IPK

```bash
find bin/packages -name "luci-app-outdoor-backup*.ipk"

# 示例输出
bin/packages/aarch64_generic/luci/luci-app-outdoor-backup_1.0-1_all.ipk
```

---

### 安装到设备

#### 方法 1：通过 SCP 安装

```bash
# 1. 复制到路由器
scp bin/packages/.../luci-app-outdoor-backup_*.ipk root@192.168.1.1:/tmp/

# 2. SSH 登录并安装
ssh root@192.168.1.1
opkg install /tmp/luci-app-outdoor-backup_*.ipk

# 3. 重启 LuCI 服务（可选）
/etc/init.d/uhttpd restart
```

#### 方法 2：通过 LuCI 安装

```
1. 访问 LuCI Web 界面
2. System → Software
3. Upload Package...
4. 选择 IPK 文件并上传
5. 等待安装完成
```

---

### 调试方法

#### 1. Lua 后端调试

```bash
# 查看 LuCI 日志
logread -f | grep luci

# 手动测试 Controller
lua -l luci.controller.outdoor-backup -e 'print("Controller loaded")'

# 查看 UCI 配置
uci show outdoor-backup
```

#### 2. 前端 JavaScript 调试

```javascript
// 在浏览器控制台执行

// 查看当前状态
console.log(currentStatus);

// 手动刷新数据
refreshData();

// 查看 XHR 请求
XHR.get('/cgi-bin/luci/admin/services/outdoor-backup/api/status', null,
    function(x, data) {
        console.log('Status:', data);
    }
);
```

#### 3. API 调试（curl）

调用前应从实际 LuCI 登录流程取得授权 session 与当前 token。读接口仍需要 read 权限。写接口只提交表单字段及 token；旧 JSON 请求体、硬编码密码与未认证 curl 不作为现行示例。字段及状态码以本文件 API 合同为准。

---

## 安全机制

### 1. XSS 防护

**输入转义**：所有用户输入在插入 HTML 前都经过转义

```javascript
// 转义函数（status.htm:344-349）
function escapeHtml(str) {
    if (!str) return '';
    var div = document.createElement('div');
    div.textContent = str;  // 使用 textContent 自动转义
    return div.innerHTML;
}

// 使用示例
html += '<td>' + escapeHtml(item.name) + '</td>';
```

**输出验证**：LuCI 模板自动转义 `<%: ... %>` 标签

---

### 2. 命令注入防护

**Shell 参数转义**：使用 `luci.util.shellquote`

```lua
-- 错误写法（易受注入攻击）
local cmd = string.format("%s %s", script, backup_root)

-- 正确写法
local util = require "luci.util"
local cmd = string.format("%s %s", script, util.shellquote(backup_root))
```

**示例攻击向量**（已防护）：
```
备份根目录输入：/mnt/ssd; rm -rf /
经过 shellquote 后：'/mnt/ssd; rm -rf /'
```

---

### 3. 文件锁机制

**原子写入**：防止并发写入导致数据损坏

```lua
-- 1. 写入临时文件
local temp_file = alias_file .. ".tmp"
fs.writefile(temp_file, new_content)

-- 2. 原子重命名（操作系统级别原子性）
fs.rename(temp_file, alias_file)

-- 3. 失败时清理
fs.unlink(temp_file)
```

**并发场景**：
- backup-manager.sh 更新 `last_seen`（每次插卡）
- WebUI 更新 `alias` 和 `notes`（用户编辑）
- 原子写入保证最多"后写覆盖先写"，不会导致文件损坏

---

### 4. 批量清理确认机制

**多重安全保护**：

| 保护层 | 机制 | 说明 |
|--------|------|------|
| **第一层** | 预览对话框 | 显示将删除的数据，用户确认 |
| **第二层** | 输入确认文字 | 必须手动输入 "清空备份数据" |
| **第三层** | 复选框确认 | 必须勾选 "我已备份到 NAS" |
| **第四层** | 按钮禁用 | 前两步未完成时按钮灰色不可点击 |
| **第五层** | manager 后端准入 | 共享租约/owner、target-only FD 9、exact root 与全树预检；force 不是绕过 |

**代码实现**（status.htm:641-651）：

```javascript
function validateCleanupConfirm() {
    var text = document.getElementById('confirm-text-input').value;
    var checkbox = document.getElementById('confirm-checkbox').checked;
    var button = document.getElementById('execute-cleanup-btn');

    // 只有两个条件都满足时才启用按钮
    if (text === '清空备份数据' && checkbox) {
        button.disabled = false;
    } else {
        button.disabled = true;
    }
}
```

---

## 已知问题和限制

### 1. 性能限制

| 场景 | 限制 | 影响 |
|------|------|------|
| **大目录扫描** | 批量清理预览需要扫描所有备份目录 | 如果有 100+ 卡片，耗时 5-10 秒 |
| **日志文件过大** | 日志页面读取最后 100 行 | 超过 1MB 的日志加载较慢 |
| **状态更新延迟** | 10 秒刷新频率 | 进度条不是完全实时 |

**优化方案**：
- 批量清理：使用后台任务 + 进度回调
- 日志：增加分页功能
- 状态：降低到 5 秒刷新（权衡 CPU 负载）

---

### 2. 浏览器兼容性

| 浏览器 | 兼容性 | 说明 |
|--------|--------|------|
| Chrome 80+ | ✅ 完全支持 | 推荐 |
| Firefox 75+ | ✅ 完全支持 | 推荐 |
| Safari 13+ | ⚠️ 部分支持 | 模态框样式略有差异 |
| Edge 80+ | ✅ 完全支持 | |
| IE 11 | ❌ 不支持 | 不支持 ES5+ 特性 |

**已知问题**：
- Safari：模态框关闭动画卡顿
- IE：不支持 `textContent`（已弃用 IE 支持）

---

### 3. LuCI 版本差异

| LuCI 版本 | 兼容性 | 说明 |
|-----------|--------|------|
| LuCI (Lua) | ✅ 完全支持 | 标准版本 |
| LuCI2 (JS) | ❌ 不支持 | 需要完全重写 |
| LuCI ngx | ⚠️ 未测试 | 理论兼容，需要测试 |

---

## 后续改进方向

### 短期改进（1-2 周）

1. **国际化支持**
   - 添加 `po/zh_Hans/outdoor-backup.po`（简体中文）
   - 添加 `po/en/outdoor-backup.po`（英语）

2. **权限回归**
   - 已交付 ACL 与 handler 级 read/write 检查；维护时保持 session.access 的真实 UCI shape。
   - 浏览器/CGI 端到端尚未验收。

3. **错误日志下载**
   - 添加 "下载错误日志" 按钮
   - 过滤只包含 ERROR 的日志行

---

### 中期改进（1-2 月）

1. **实时进度更新**
   - 使用 Server-Sent Events (SSE) 推送进度
   - 或使用 WebSocket（需要额外依赖）

2. **批量操作**
   - 批量删除别名
   - 批量导出/导入别名

3. **高级搜索**
   - 日志页面支持关键词搜索
   - 备份历史支持过滤

---

### 长期改进（3+ 月）

1. **移动端 App**
   - 使用 Cordova 封装 WebUI
   - 推送通知（备份完成）

2. **云备份集成**
   - rclone 二级同步到 NAS/云盘
   - 配置页面添加云盘设置

3. **备份版本管理**
   - 增量快照（类似 Git）
   - 回滚到历史版本

---

## 参考资源

### LuCI 官方文档

- LuCI Development: https://openwrt.org/docs/guide-developer/luci
- CBI Framework: https://github.com/openwrt/luci/wiki/CBI
- LuCI RPC: https://github.com/openwrt/luci/wiki/JsonRpcHowTo

### Lua 文档

- Lua 5.1 Reference: https://www.lua.org/manual/5.1/
- nixio Library: https://luci.subsignal.org/api/nixio/

### OpenWrt 文档

- Package Development: https://openwrt.org/docs/guide-developer/packages
- UCI Configuration: https://openwrt.org/docs/guide-user/base-system/uci

---

## 贡献指南

### 代码提交流程

1. **Fork 仓库**
2. **创建功能分支**：`git checkout -b feature/my-feature`
3. **提交代码**：`git commit -m "feat: add my feature"`
4. **推送分支**：`git push origin feature/my-feature`
5. **创建 Pull Request**

### 提交信息规范

```
<type>(<scope>): <subject>

<body>

<footer>
```

**示例**：

```
feat(webui): add manual backup trigger button

- Add API endpoint /api/trigger
- Add JavaScript function triggerBackup()
- Update status.htm template

Closes #123
```

**Type 类型**：
- `feat`：新功能
- `fix`：Bug 修复
- `docs`：文档更新
- `style`：代码格式（不影响功能）
- `refactor`：重构
- `test`：测试
- `chore`：构建/工具

---

## 联系方式

- GitHub Issues: [项目仓库]
- 文档: [docs/ 目录]
- 邮箱: [维护者邮箱]

---

## 许可证

GPL-2.0-only (与 OpenWrt 兼容)
