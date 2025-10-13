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
│   └── usr/share/rpcd/acl.d/
│       └── outdoor-backup.json          # RPCD 权限（待添加）
└── po/                                   # 国际化（待添加）
    ├── zh_Hans/outdoor-backup.po        # 简体中文
    └── templates/outdoor-backup.pot     # 翻译模板
```

### 文件功能说明

| 文件 | 行数 | 功能 |
|------|------|------|
| `outdoor-backup.lua` | 470 | 页面路由、API 接口、业务逻辑 |
| `config.lua` | 55 | UCI 配置表单（CBI） |
| `status.htm` | 911 | 状态监控页面（HTML+JS） |
| `log.htm` | 243 | 日志查看页面（HTML+JS） |
| **总计** | **1679** | |

---

## API 接口文档

### 1. GET /api/status

**功能**：获取当前备份状态和历史记录

**请求**：
```http
GET /admin/services/outdoor-backup/api/status HTTP/1.1
```

**响应**（成功）：
```json
{
  "version": "1.0",
  "last_update": 1728825600,
  "storage": {
    "root": "/mnt/ssd/SDMirrors",
    "total_bytes": 512000000000,
    "used_bytes": 128000000000,
    "free_bytes": 384000000000
  },
  "current_backup": {
    "active": true,
    "uuid": "550e8400-e29b-41d4-a716-446655440000",
    "name": "Canon_5D4_Card1",
    "device": "sda1",
    "started_at": 1728825000,
    "progress_percent": 45,
    "files_total": 1200,
    "files_done": 540,
    "bytes_total": 52428800000,
    "bytes_done": 23592960000,
    "speed_bytes_per_sec": 157286400
  },
  "history": [
    {
      "uuid": "550e8400-e29b-41d4-a716-446655440000",
      "name": "Canon_5D4_Card1",
      "last_backup_at": 1728825000,
      "status": "completed",
      "files_count": 1200,
      "bytes_total": 52428800000,
      "backup_path": "/mnt/ssd/SDMirrors/550e8400-...",
      "error_message": null
    }
  ]
}
```

**响应**（失败）：
```json
{
  "error": "Status file not found"
}
```

**HTTP 状态码**：
- `200 OK`：成功
- `404 Not Found`：状态文件不存在

**实现位置**：`outdoor-backup.lua:94-108`

---

### 2. GET /api/aliases

**功能**：获取所有 UUID 别名映射

**请求**：
```http
GET /admin/services/outdoor-backup/api/aliases HTTP/1.1
```

**响应**（成功）：
```json
{
  "version": "1.0",
  "aliases": {
    "550e8400-e29b-41d4-a716-446655440000": {
      "alias": "Canon_5D4_Card1",
      "notes": "佳能相机主卡",
      "created_at": 1728825600,
      "last_seen": 1728900000
    },
    "7c9e6679-7425-40de-944b-e07fc1f90ae7": {
      "alias": "Sony A7R5 Backup",
      "notes": "",
      "created_at": 1728800000,
      "last_seen": 1728900000
    }
  }
}
```

**响应**（文件不存在）：
```json
{
  "version": "1.0",
  "aliases": {}
}
```

**HTTP 状态码**：
- `200 OK`：始终成功（空别名表也是合法响应）

**实现位置**：`outdoor-backup.lua:115-129`

---

### 3. POST /api/alias/update

**功能**：创建或更新 UUID 别名

**请求**：
```http
POST /admin/services/outdoor-backup/api/alias/update HTTP/1.1
Content-Type: application/json

{
  "uuid": "550e8400-e29b-41d4-a716-446655440000",
  "alias": "Canon_5D4_Card1",
  "notes": "佳能相机主卡，128GB"
}
```

**请求字段**：

| 字段 | 类型 | 必需 | 说明 |
|------|------|------|------|
| `uuid` | string | ✅ | 完整 UUID（36 字符，带连字符） |
| `alias` | string | ❌ | 别名（可为空） |
| `notes` | string | ❌ | 备注（可为空） |

**响应**（成功）：
```json
{
  "success": true
}
```

**响应**（失败）：
```json
{
  "error": "Missing or empty uuid field"
}
```

或

```json
{
  "error": "Invalid UUID format"
}
```

或

```json
{
  "error": "Failed to write alias file"
}
```

**HTTP 状态码**：
- `200 OK`：成功
- `400 Bad Request`：参数错误
- `500 Internal Server Error`：写入失败

**UUID 格式验证**：
```lua
-- 正则表达式
^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$
```

**实现位置**：`outdoor-backup.lua:140-225`

**原子写入机制**：
```lua
-- 1. 写入临时文件
fs.writefile(temp_file, new_content)

-- 2. 原子重命名
fs.rename(temp_file, alias_file)

-- 3. 失败时清理
fs.unlink(temp_file)
```

---

### 4. DELETE /api/alias/delete

**功能**：删除 UUID 别名映射（不删除备份数据）

**请求**：
```http
DELETE /admin/services/outdoor-backup/api/alias/delete?uuid=550e8400-e29b-41d4-a716-446655440000 HTTP/1.1
```

**请求参数**：

| 参数 | 类型 | 必需 | 说明 |
|------|------|------|------|
| `uuid` | string | ✅ | 完整 UUID |

**响应**（成功）：
```json
{
  "success": true
}
```

**响应**（失败）：
```json
{
  "error": "Missing uuid parameter"
}
```

或

```json
{
  "error": "Alias not found"
}
```

或

```json
{
  "error": "Failed to write alias file"
}
```

**HTTP 状态码**：
- `200 OK`：成功
- `400 Bad Request`：参数错误
- `404 Not Found`：别名不存在
- `500 Internal Server Error`：写入失败

**实现位置**：`outdoor-backup.lua:232-291`

**重要说明**：
- 删除别名**不会**删除备份数据
- 备份数据路径：`/mnt/ssd/SDMirrors/{uuid}/`
- 如需删除备份数据，使用批量清理功能

---

### 5. GET /api/cleanup/preview

**功能**：预览批量清理（列出所有卡片和大小）

**请求**：
```http
GET /admin/services/outdoor-backup/api/cleanup/preview HTTP/1.1
```

**响应**（成功）：
```json
{
  "cards": [
    {
      "uuid": "550e8400-e29b-41d4-a716-446655440000",
      "display_name": "Canon_5D4_Card1",
      "size_bytes": 52428800000,
      "path": "/mnt/ssd/SDMirrors/550e8400-..."
    },
    {
      "uuid": "7c9e6679-7425-40de-944b-e07fc1f90ae7",
      "display_name": "Sony A7R5 Backup",
      "size_bytes": 34359738368,
      "path": "/mnt/ssd/SDMirrors/7c9e6679-..."
    }
  ],
  "total_size_bytes": 86788538368,
  "total_cards": 2,
  "backup_root": "/mnt/ssd/SDMirrors"
}
```

**响应**（失败）：
```json
{
  "error": "Backup root directory not found"
}
```

**HTTP 状态码**：
- `200 OK`：成功
- `404 Not Found`：备份根目录不存在

**实现位置**：`outdoor-backup.lua:303-386`

**大小计算方法**：
```lua
-- 递归计算目录大小
local function calculate_dir_size(path)
    local total = 0
    for entry in fs.dir(path) do
        if entry ~= "." and entry ~= ".." then
            total = total + calculate_dir_size(path .. "/" .. entry)
        end
    end
    return total
end
```

---

### 6. POST /api/cleanup/execute

**功能**：执行批量清理（需要确认文字）

**请求**：
```http
POST /admin/services/outdoor-backup/api/cleanup/execute HTTP/1.1
Content-Type: application/json

{
  "confirm_text": "清空备份数据"
}
```

**请求字段**：

| 字段 | 类型 | 必需 | 说明 |
|------|------|------|------|
| `confirm_text` | string | ✅ | 必须完全匹配 "清空备份数据" |

**响应**（成功）：
```json
{
  "success": true,
  "message": "Backup data cleaned successfully"
}
```

**响应**（失败）：
```json
{
  "error": "Invalid confirmation text"
}
```

或

```json
{
  "error": "Backup root directory not found"
}
```

或

```json
{
  "error": "Cleanup script not found or not executable"
}
```

或

```json
{
  "success": false,
  "error": "Cleanup failed",
  "exit_code": 1
}
```

**HTTP 状态码**：
- `200 OK`：成功
- `400 Bad Request`：参数错误
- `404 Not Found`：备份根目录不存在
- `500 Internal Server Error`：执行失败

**实现位置**：`outdoor-backup.lua:395-469`

**执行命令**：
```lua
local cmd = string.format("%s --force %s 1 2>&1",
                          cleanup_script,
                          util.shellquote(backup_root))
```

**参数说明**：
- `--force`：跳过安全检查（WebUI 已完成确认）
- `backup_root`：备份根目录路径（shell 转义）
- `1`：保留别名标志（1 = 保留，0 = 删除）

**清理脚本**：`/opt/outdoor-backup/scripts/cleanup-all.sh`

---

## 数据结构

### status.json

**路径**：`/opt/outdoor-backup/var/status.json`

**更新频率**：backup-manager.sh 每 60 秒更新一次

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

#### 场景：添加 "手动触发备份" 按钮

**步骤**：

1. **修改 Controller（outdoor-backup.lua）**

```lua
-- 添加 API 路由
entry({"admin", "services", "outdoor-backup", "api", "trigger"},
      call("api_trigger_backup"))

-- 实现 API 函数
function api_trigger_backup()
    local uuid = luci.http.formvalue("uuid")

    -- 验证参数
    if not uuid then
        luci.http.status(400)
        return luci.http.write_json({error = "Missing uuid"})
    end

    -- 调用 Shell 脚本
    local cmd = string.format("/opt/outdoor-backup/scripts/manual-backup.sh '%s'", uuid)
    local result = luci.sys.call(cmd)

    -- 返回结果
    luci.http.prepare_content("application/json")
    if result == 0 then
        luci.http.write_json({success = true})
    else
        luci.http.status(500)
        luci.http.write_json({error = "Backup failed", exit_code = result})
    end
end
```

2. **修改 View Template（status.htm）**

```html
<!-- 添加按钮 -->
<button class="btn btn-primary" onclick="triggerBackup('550e8400-...')">
    Manual Backup
</button>

<!-- 添加 JavaScript 函数 -->
<script>
function triggerBackup(uuid) {
    if (!confirm('Trigger backup for UUID: ' + uuid + '?')) return;

    XHR.get('<%=url("admin/services/outdoor-backup/api/trigger")%>',
        {uuid: uuid},
        function(x, result) {
            if (result && result.success) {
                alert('Backup triggered successfully');
                refreshData();
            } else {
                alert('Backup failed: ' + (result ? result.error : 'Unknown error'));
            }
        }
    );
}
</script>
```

3. **创建 Shell 脚本（manual-backup.sh）**

```bash
#!/bin/sh
# Manual backup trigger script

UUID="$1"

if [ -z "$UUID" ]; then
    echo "Usage: $0 <uuid>" >&2
    exit 1
fi

# 调用 backup-manager.sh
/opt/outdoor-backup/scripts/backup-manager.sh manual "$UUID"
```

4. **测试**

```bash
# 编译包
make package/luci-app-outdoor-backup/compile V=s

# 安装测试
scp bin/packages/.../luci-app-outdoor-backup_*.ipk root@router:/tmp/
ssh root@router "opkg install --force-reinstall /tmp/luci-app-outdoor-backup_*.ipk"

# 访问 WebUI 测试按钮
```

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
<div id="alias-modal" class="modal">
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
        JSON.stringify(testData),
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

```bash
# 测试状态 API
curl -s "http://192.168.1.1/cgi-bin/luci/admin/services/outdoor-backup/api/status" | jq

# 测试别名更新（需要认证）
curl -s -b cookies.txt -X POST \
    -H "Content-Type: application/json" \
    -d '{"uuid":"550e8400-...","alias":"Test"}' \
    "http://192.168.1.1/cgi-bin/luci/admin/services/outdoor-backup/api/alias/update"

# 获取认证 Cookie
curl -c cookies.txt -d "luci_username=root&luci_password=password" \
    "http://192.168.1.1/cgi-bin/luci"
```

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
| **第五层** | Shell 脚本安全检查 | cleanup-all.sh 检查 `--force` 标志 |

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

2. **RPCD 权限控制**
   - 创建 `root/usr/share/rpcd/acl.d/outdoor-backup.json`
   - 细化权限（只读 vs 读写）

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
