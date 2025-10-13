# WebUI 设计文档

## 数据结构

### 1. 状态文件格式（status.json）

**路径**：`/opt/outdoor-backup/var/status.json`

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

**说明**：
- `name` 字段由 `get_display_name()` 函数生成，优先使用别名

### 2. 别名映射文件（aliases.json）

**路径**：`/opt/outdoor-backup/conf/aliases.json`

**设计原则**：
- **数据 vs 配置**：别名是用户数据，不是系统配置，因此不用 UCI
- **中心化管理**：存储在路由器上，独立于 SD 卡
- **零依赖**：备份逻辑不依赖别名，删除 aliases.json 不影响功能

```json
{
  "version": "1.0",
  "aliases": {
    "550e8400-e29b-41d4-a716-446655440000": {
      "alias": "三星TF卡Pro128G",
      "notes": "户外摄影专用卡",
      "created_at": 1728825600,
      "last_seen": 1728825600
    },
    "7c9e6679-7425-40de-944b-e07fc1f90ae7": {
      "alias": "Sony A7R5 备用卡",
      "notes": "索尼相机专用，128GB",
      "created_at": 1728800000,
      "last_seen": 1728900000
    }
  }
}
```

**字段说明**：
- `alias`：用户设置的别名（可为空）
- `notes`：可选的备注信息
- `created_at`：首次创建时间戳
- `last_seen`：最后插入时间戳（backup-manager.sh 自动更新）

### 3. 显示名称优先级

**get_display_name() 逻辑**（简化版）：
```
1. 查询 aliases.json 中的 alias 字段
   ├─ 如果有别名 → 返回别名
   └─ 如果没有别名 ↓
2. 回退到 "SD_" + UUID前8位
```

**设计简化说明**：
- ~~原计划支持卡上的 SD_NAME（FieldBackup.conf）~~ → 不存在此字段，已移除
- 只保留两级：别名（用户明确设置）→ UUID前8位（自动生成）
- 消除了不必要的中间层，更简单清晰

### 状态更新时机

backup-manager.sh 在以下时机更新状态文件：

1. **备份开始时**：写入 `current_backup` 基本信息
2. **进度更新时**：每传输 10% 或每 60 秒更新一次
3. **备份完成时**：清空 `current_backup`，追加到 `history`
4. **备份失败时**：记录错误到 `history`

## UI 界面设计

### 页面布局

```
╔══════════════════════════════════════════════════════╗
║  Outdoor Backup - SD Card Auto Backup System         ║
╠══════════════════════════════════════════════════════╣
║  [状态] [配置] [日志]                                 ║
╠══════════════════════════════════════════════════════╣
║                                                       ║
║  【状态页面内容】                                      ║
║                                                       ║
╚══════════════════════════════════════════════════════╝
```

### 1. 状态页面（Status）

#### 当前备份（如果有）

```
┌─ 正在备份 ─────────────────────────────────────┐
│ 卡名称: Canon_5D4_Card1                         │
│ UUID: 550e8400-e29b-41d4-a716-446655440000      │
│ 设备: /dev/sda1                                 │
│                                                 │
│ 进度: [████████████░░░░░░░░░░░░░░] 45%        │
│                                                 │
│ 文件: 540 / 1200                                │
│ 大小: 22 GB / 48.8 GB                           │
│ 速度: 150 MB/s                                  │
│ 预计剩余: 3 分钟                                │
│                                                 │
│ 开始时间: 2024-10-13 14:30:00                   │
└─────────────────────────────────────────────────┘
```

#### 存储空间

```
┌─ 存储空间 ─────────────────────────────────────┐
│ 备份位置: /mnt/ssd/SDMirrors                    │
│ 已用: 119 GB / 476 GB (25%)                     │
│ 可用: 357 GB                                    │
│                                                 │
│ [████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░] 25%    │
└─────────────────────────────────────────────────┘
```

#### 备份历史

```
┌─ 备份历史 ─────────────────────────────────────────────────┐
│ 卡名称              | UUID (前8位) | 最后备份      | 大小   | 操作   │
│ ────────────────────────────────────────────────────────────│
│ 三星TF卡Pro128G     | 550e8400     | 2分钟前       | 48.8GB | [编辑] │
│ Sony A7R5 备用卡    | 7c9e6679     | 1小时前       | 32.1GB | [编辑] │
│ DJI_Mavic3_Card1    | 3b1e7a9f     | 昨天 18:30    | 12.5GB | [编辑] │
└─────────────────────────────────────────────────────────────┘
```

**点击"编辑"弹出模态框**：

```
╔═══════════════════════════════════════════════════════════╗
║  编辑卡片别名                                     [✕]      ║
╠═══════════════════════════════════════════════════════════╣
║                                                            ║
║  UUID: 550e8400-e29b-41d4-a716-446655440000               ║
║                                                            ║
║  别名:                                                     ║
║  ┌──────────────────────────────────────────────┐         ║
║  │ 三星TF卡Pro128G                               │         ║
║  └──────────────────────────────────────────────┘         ║
║                                                            ║
║  备注:                                                     ║
║  ┌──────────────────────────────────────────────┐         ║
║  │ 户外摄影专用卡                                │         ║
║  │                                               │         ║
║  └──────────────────────────────────────────────┘         ║
║                                                            ║
║  ┌─ 卡片信息 ──────────────────────────────────┐          ║
║  │ 备份路径: /mnt/ssd/SDMirrors/550e8400-...    │          ║
║  │ 文件数: 1200                                 │          ║
║  │ 大小: 48.8 GB                                │          ║
║  │ 首次备份: 2024-10-10 08:30:00                │          ║
║  │ 最后插入: 2024-10-13 14:30:00                │          ║
║  └──────────────────────────────────────────────┘          ║
║                                                            ║
║  [保存别名]  [删除映射]  [取消]                            ║
║                                                            ║
║  ⚠️ 删除映射不会删除备份数据                               ║
╚═══════════════════════════════════════════════════════════╝
```

**删除映射确认对话框**：

```
╔═══════════════════════════════════════════════════════════╗
║  确认删除别名映射                                 [✕]      ║
╠═══════════════════════════════════════════════════════════╣
║                                                            ║
║  确定要删除 "三星TF卡Pro128G" 的别名映射吗？               ║
║                                                            ║
║  UUID: 550e8400-e29b-41d4-a716-446655440000               ║
║                                                            ║
║  ⚠️ 注意：                                                  ║
║  - 删除映射不会删除备份数据                                ║
║  - 备份数据将保留在：/mnt/ssd/SDMirrors/550e8400-...      ║
║  - 如需清理备份数据，请使用"批量清理"功能                   ║
║                                                            ║
║  [确认删除]  [取消]                                        ║
╚═══════════════════════════════════════════════════════════╝
```

### 2. 配置页面（Configuration）

```
┌─ 基本设置 ─────────────────────────────────────┐
│ 启用自动备份:     [✓] 已启用                     │
│ 备份根目录:       /mnt/ssd/SDMirrors [浏览...]   │
│ 调试模式:         [ ] 禁用                       │
└─────────────────────────────────────────────────┘

┌─ LED 指示灯设置 ───────────────────────────────┐
│ 绿灯（成功）:     /sys/class/leds/green:lan     │
│ 红灯（错误）:     /sys/class/leds/red:sys       │
└─────────────────────────────────────────────────┘

┌─ 高级设置 ─────────────────────────────────────┐
│ 默认备份模式:     [PRIMARY ▼]                   │
│                   - PRIMARY: SD卡 → 内置存储    │
│                   - REPLICA: 内置存储 → SD卡    │
└─────────────────────────────────────────────────┘

┌─ 危险操作 ─────────────────────────────────────┐
│ ⚠️  批量清理备份数据                             │
│                                                 │
│ 将清空所有已备份的存储卡数据，但保留别名映射。    │
│ 此操作用于将数据备份到 NAS 后释放本地存储空间。   │
│                                                 │
│ [批量清理...]                                   │
└─────────────────────────────────────────────────┘

[保存配置] [恢复默认]
```

**批量清理确认对话框（第一步）**：

```
╔═══════════════════════════════════════════════════════════╗
║  批量清理备份数据                                 [✕]      ║
╠═══════════════════════════════════════════════════════════╣
║                                                            ║
║  ⚠️ 警告：此操作将删除所有备份数据！                        ║
║                                                            ║
║  即将清理的数据：                                           ║
║                                                            ║
║  卡名称              | UUID (前8位) | 大小                 │
║  ──────────────────────────────────────────────           ║
║  三星TF卡Pro128G     | 550e8400     | 48.8 GB             │
║  Sony A7R5 备用卡    | 7c9e6679     | 32.1 GB             │
║  DJI_Mavic3_Card1    | 3b1e7a9f     | 12.5 GB             │
║                                                            ║
║  总计：3 张卡，93.4 GB                                      │
║                                                            ║
║  将被保留的内容：                                           ║
║  ✓ 别名映射表（aliases.json）                              ║
║  ✓ 配置文件                                                ║
║  ✓ 日志文件                                                ║
║                                                            ║
║  将被删除的内容：                                           ║
║  ✗ /mnt/ssd/SDMirrors/550e8400-.../*                      ║
║  ✗ /mnt/ssd/SDMirrors/7c9e6679-.../*                      ║
║  ✗ /mnt/ssd/SDMirrors/3b1e7a9f-.../*                      ║
║                                                            ║
║  [下一步]  [取消]                                          ║
╚═══════════════════════════════════════════════════════════╝
```

**批量清理确认对话框（第二步 - 输入确认）**：

```
╔═══════════════════════════════════════════════════════════╗
║  最终确认 - 批量清理备份数据                      [✕]      ║
╠═══════════════════════════════════════════════════════════╣
║                                                            ║
║  ⚠️ 最后确认：此操作不可撤销！                              ║
║                                                            ║
║  将删除 93.4 GB 数据（3 张存储卡）                          ║
║                                                            ║
║  请输入以下文字以确认操作：                                 ║
║                                                            ║
║      清空备份数据                                          ║
║                                                            ║
║  输入确认文字:                                             ║
║  ┌──────────────────────────────────────────────┐         ║
║  │                                               │         ║
║  └──────────────────────────────────────────────┘         ║
║                                                            ║
║  [ ] 我已经将数据备份到 NAS，确认清空                      ║
║                                                            ║
║  [确认清空]  [取消]                                        ║
║                                                            ║
║  注意："确认清空"按钮将在输入正确文字并勾选复选框后启用      ║
╚═══════════════════════════════════════════════════════════╝
```

**清理进度对话框**：

```
╔═══════════════════════════════════════════════════════════╗
║  正在清理备份数据...                              [✕]      ║
╠═══════════════════════════════════════════════════════════╣
║                                                            ║
║  正在删除：/mnt/ssd/SDMirrors/550e8400-...                ║
║                                                            ║
║  进度: [████████████████░░░░░░░░░░░░] 2/3 (66%)          ║
║                                                            ║
║  已清理：61.9 GB / 93.4 GB                                 ║
║                                                            ║
║  请勿关闭此窗口...                                          ║
╚═══════════════════════════════════════════════════════════╝
```

**清理完成对话框**：

```
╔═══════════════════════════════════════════════════════════╗
║  清理完成                                         [✕]      ║
╠═══════════════════════════════════════════════════════════╣
║                                                            ║
║  ✓ 备份数据已清理完成                                      ║
║                                                            ║
║  已清理：93.4 GB（3 张存储卡）                              ║
║                                                            ║
║  保留内容：                                                ║
║  ✓ 别名映射表（3 条记录）                                  ║
║  ✓ 配置文件                                                ║
║  ✓ 日志文件                                                ║
║                                                            ║
║  存储空间：                                                ║
║  已用: 5 GB / 476 GB (1%)                                  ║
║  可用: 471 GB                                              ║
║                                                            ║
║  [关闭]                                                    ║
╚═══════════════════════════════════════════════════════════╝
```

### 3. 日志页面（Logs）

```
┌─ 系统日志（最近100行）─────────────────────────┐
│ [实时刷新 ▼] [下载完整日志]                      │
│                                                 │
│ 2024-10-13 14:30:00 [INFO] SD卡插入: /dev/sda1  │
│ 2024-10-13 14:30:01 [INFO] 挂载成功: exFAT      │
│ 2024-10-13 14:30:02 [INFO] 读取配置: Canon_5D... │
│ 2024-10-13 14:30:03 [INFO] 开始备份: 1200 文件  │
│ 2024-10-13 14:32:15 [INFO] 备份完成: 48.8 GB    │
│ ...                                             │
└─────────────────────────────────────────────────┘
```

## LuCI 框架技术选型

### 组件映射

| UI 元素 | LuCI CBI 组件 | 说明 |
|---------|---------------|------|
| 开关按钮 | `Flag` | UCI 配置的布尔值 |
| 文本输入 | `Value` | UCI 配置的字符串 |
| 下拉选择 | `ListValue` | UCI 配置的枚举 |
| 表格 | `SimpleTable` 或自定义 HTML | 状态数据展示 |
| 进度条 | 自定义 HTML + JavaScript | 动态刷新 |

### 文件结构

```
luci-app-outdoor-backup/
├── Makefile                              # IPK 包定义
├── luasrc/
│   ├── controller/outdoor-backup.lua     # 路由控制器
│   └── model/cbi/outdoor-backup/
│       ├── config.lua                    # 配置页面（CBI）
│       └── status.lua                    # 状态页面（自定义 View）
├── root/
│   └── usr/share/rpcd/acl.d/
│       └── outdoor-backup.json           # RPCD 权限定义
└── po/                                   # 国际化
    ├── zh_Hans/outdoor-backup.po         # 简体中文
    └── templates/outdoor-backup.pot      # 翻译模板
```

## 实现细节

### controller/outdoor-backup.lua

```lua
module("luci.controller.outdoor-backup", package.seeall)

function index()
    entry({"admin", "services", "outdoor-backup"}, firstchild(), _("Outdoor Backup"), 60).dependent = false

    -- 状态页面（默认首页）
    entry({"admin", "services", "outdoor-backup", "status"},
          template("outdoor-backup/status"), _("Status"), 1)

    -- 配置页面
    entry({"admin", "services", "outdoor-backup", "config"},
          cbi("outdoor-backup/config"), _("Configuration"), 2)

    -- 日志页面
    entry({"admin", "services", "outdoor-backup", "log"},
          call("action_log"), _("Logs"), 3)

    -- API 接口（用于 AJAX 获取状态）
    entry({"admin", "services", "outdoor-backup", "api", "status"},
          call("api_status"))

    -- 别名管理 API
    entry({"admin", "services", "outdoor-backup", "api", "aliases"},
          call("api_aliases"))
    entry({"admin", "services", "outdoor-backup", "api", "alias", "update"},
          call("api_update_alias"))
    entry({"admin", "services", "outdoor-backup", "api", "alias", "delete"},
          call("api_delete_alias"))
end

function action_log()
    local log_file = "/opt/outdoor-backup/log/backup.log"
    local cmd = string.format("tail -n 100 %s", log_file)
    luci.template.render("outdoor-backup/log", {
        log_content = luci.sys.exec(cmd)
    })
end

function api_status()
    local json = require "luci.jsonc"
    local fs = require "nixio.fs"

    local status_file = "/opt/outdoor-backup/var/status.json"
    local content = fs.readfile(status_file)

    if content then
        luci.http.prepare_content("application/json")
        luci.http.write(content)
    else
        luci.http.status(404)
        luci.http.write_json({error = "Status file not found"})
    end
end

-- GET /api/aliases - 获取所有别名
function api_aliases()
    local json = require "luci.jsonc"
    local fs = require "nixio.fs"

    local alias_file = "/opt/outdoor-backup/conf/aliases.json"
    local content = fs.readfile(alias_file)

    if content then
        luci.http.prepare_content("application/json")
        luci.http.write(content)
    else
        -- 返回空别名表
        luci.http.prepare_content("application/json")
        luci.http.write_json({version = "1.0", aliases = {}})
    end
end

-- POST /api/alias/update - 创建/更新别名
function api_update_alias()
    local json = require "luci.jsonc"
    local fs = require "nixio.fs"

    -- 读取 POST 数据
    luci.http.setfilehandler()
    local content_length = tonumber(luci.http.getenv("CONTENT_LENGTH")) or 0
    if content_length == 0 then
        luci.http.status(400)
        return luci.http.write_json({error = "Empty request body"})
    end

    local post_data = luci.http.content()
    local data = json.parse(post_data)

    if not data or not data.uuid then
        luci.http.status(400)
        return luci.http.write_json({error = "Missing uuid field"})
    end

    -- 读取现有别名
    local alias_file = "/opt/outdoor-backup/conf/aliases.json"
    local aliases = {}
    local existing_content = fs.readfile(alias_file)
    if existing_content then
        local parsed = json.parse(existing_content)
        aliases = parsed.aliases or {}
    end

    -- 更新/创建别名
    local now = os.time()
    if not aliases[data.uuid] then
        aliases[data.uuid] = {
            created_at = now,
            last_seen = now
        }
    end

    aliases[data.uuid].alias = data.alias or ""
    aliases[data.uuid].notes = data.notes or ""

    -- 原子写入
    local temp_file = alias_file .. ".tmp"
    local new_content = json.stringify({
        version = "1.0",
        aliases = aliases
    }, true)  -- true = pretty print

    if fs.writefile(temp_file, new_content) then
        fs.rename(temp_file, alias_file)
        luci.http.prepare_content("application/json")
        luci.http.write_json({success = true})
    else
        luci.http.status(500)
        luci.http.write_json({error = "Failed to write alias file"})
    end
end

-- DELETE /api/alias/delete?uuid=xxx
function api_delete_alias()
    local json = require "luci.jsonc"
    local fs = require "nixio.fs"

    local uuid = luci.http.formvalue("uuid")

    if not uuid then
        luci.http.status(400)
        return luci.http.write_json({error = "Missing uuid parameter"})
    end

    -- 读取现有别名
    local alias_file = "/opt/outdoor-backup/conf/aliases.json"
    local aliases = {}
    local existing_content = fs.readfile(alias_file)
    if existing_content then
        local parsed = json.parse(existing_content)
        aliases = parsed.aliases or {}
    end

    -- 删除别名（不删除备份数据）
    aliases[uuid] = nil

    -- 原子写入
    local temp_file = alias_file .. ".tmp"
    local new_content = json.stringify({
        version = "1.0",
        aliases = aliases
    }, true)

    if not fs.writefile(temp_file, new_content) then
        luci.http.status(500)
        return luci.http.write_json({error = "Failed to write alias file"})
    end

    fs.rename(temp_file, alias_file)

    luci.http.prepare_content("application/json")
    luci.http.write_json({success = true})
end

-- GET /api/cleanup/preview - 预览批量清理
function api_cleanup_preview()
    local json = require "luci.jsonc"
    local fs = require "nixio.fs"

    -- 获取备份根目录
    local backup_root = luci.sys.exec("uci get outdoor-backup.config.backup_root"):gsub("%s+", "")
    if backup_root == "" then
        backup_root = "/mnt/ssd/SDMirrors"
    end

    -- 获取别名映射
    local alias_file = "/opt/outdoor-backup/conf/aliases.json"
    local aliases = {}
    local existing_content = fs.readfile(alias_file)
    if existing_content then
        local parsed = json.parse(existing_content)
        aliases = parsed.aliases or {}
    end

    -- 遍历备份目录，收集所有卡片信息
    local cards = {}
    local total_size = 0

    for uuid_dir in fs.dir(backup_root) do
        local full_path = backup_root .. "/" .. uuid_dir
        local stat = fs.stat(full_path)

        if stat and stat.type == "dir" and uuid_dir:match("^%x%x%x%x%x%x%x%x%-") then
            -- 计算目录大小（调用系统命令）
            local size_cmd = string.format("du -sb '%s' | awk '{print $1}'", full_path)
            local size_str = luci.sys.exec(size_cmd):gsub("%s+", "")
            local size = tonumber(size_str) or 0

            -- 获取显示名称
            local display_name = "SD_" .. uuid_dir:sub(1, 8)
            if aliases[uuid_dir] and aliases[uuid_dir].alias ~= "" then
                display_name = aliases[uuid_dir].alias
            end

            table.insert(cards, {
                uuid = uuid_dir,
                display_name = display_name,
                size_bytes = size,
                path = full_path
            })

            total_size = total_size + size
        end
    end

    luci.http.prepare_content("application/json")
    luci.http.write_json({
        cards = cards,
        total_size_bytes = total_size,
        total_cards = #cards,
        backup_root = backup_root
    })
end

-- POST /api/cleanup/execute - 执行批量清理
function api_cleanup_execute()
    local json = require "luci.jsonc"
    local fs = require "nixio.fs"

    -- 读取 POST 数据
    luci.http.setfilehandler()
    local content_length = tonumber(luci.http.getenv("CONTENT_LENGTH")) or 0
    if content_length == 0 then
        luci.http.status(400)
        return luci.http.write_json({error = "Empty request body"})
    end

    local post_data = luci.http.content()
    local data = json.parse(post_data)

    -- 验证确认文字
    if not data or data.confirm_text ~= "清空备份数据" then
        luci.http.status(400)
        return luci.http.write_json({error = "Invalid confirmation text"})
    end

    -- 获取备份根目录
    local backup_root = luci.sys.exec("uci get outdoor-backup.config.backup_root"):gsub("%s+", "")
    if backup_root == "" then
        backup_root = "/mnt/ssd/SDMirrors"
    end

    -- 执行清理（调用 Shell 脚本）
    local cleanup_script = "/opt/outdoor-backup/scripts/cleanup-all.sh"
    local cmd = string.format("%s '%s' 1", cleanup_script, backup_root)  -- 1 = 保留别名
    local result = luci.sys.exec(cmd)

    -- 返回结果
    luci.http.prepare_content("application/json")
    luci.http.write_json({
        success = true,
        message = "Backup data cleaned successfully"
    })
end
```

### model/cbi/outdoor-backup/config.lua

```lua
local m, s, o

m = Map("outdoor-backup",
        translate("Outdoor Backup Configuration"),
        translate("SD card automatic backup system for outdoor photography"))

-- 基本设置
s = m:section(TypedSection, "outdoor-backup", translate("Basic Settings"))
s.anonymous = true
s.addremove = false

o = s:option(Flag, "enabled", translate("Enable Auto Backup"))
o.default = "1"

o = s:option(Value, "backup_root", translate("Backup Root Directory"))
o.default = "/mnt/ssd/SDMirrors"
o.placeholder = "/mnt/ssd/SDMirrors"

o = s:option(Flag, "debug", translate("Debug Mode"))
o.default = "0"

-- LED 设置
s = m:section(TypedSection, "outdoor-backup", translate("LED Settings"))
s.anonymous = true

o = s:option(Value, "led_green", translate("Green LED Path"))
o.default = "/sys/class/leds/green:lan"

o = s:option(Value, "led_red", translate("Red LED Path"))
o.default = "/sys/class/leds/red:sys"

-- 高级设置
s = m:section(TypedSection, "outdoor-backup", translate("Advanced Settings"))
s.anonymous = true

o = s:option(ListValue, "default_mode", translate("Default Backup Mode"))
o:value("PRIMARY", translate("PRIMARY (SD → Storage)"))
o:value("REPLICA", translate("REPLICA (Storage → SD)"))
o.default = "PRIMARY"

return m
```

### view/outdoor-backup/status.htm

```html
<%+header%>

<script type="text/javascript">
    function refresh_status() {
        XHR.get('<%=url("admin/services/outdoor-backup/api/status")%>', null,
            function(x, data) {
                if (data) {
                    update_ui(data);
                }
            }
        );
    }

    function update_ui(status) {
        // 更新当前备份进度
        if (status.current_backup && status.current_backup.active) {
            var percent = status.current_backup.progress_percent;
            document.getElementById('progress-bar').style.width = percent + '%';
            document.getElementById('progress-text').innerText = percent + '%';
            // ... 更新其他字段
        } else {
            // 隐藏当前备份区域
        }

        // 更新存储空间
        // ...

        // 更新备份历史
        // ...
    }

    // 每10秒刷新一次
    XHR.poll(10, '<%=url("admin/services/outdoor-backup/api/status")%>', null,
        function(x, data) {
            if (data) update_ui(data);
        }
    );
</script>

<h2 name="content"><%:Status%></h2>

<!-- 当前备份 -->
<fieldset class="cbi-section">
    <legend><%:Current Backup%></legend>
    <div id="current-backup">
        <!-- 动态内容 -->
    </div>
</fieldset>

<!-- 存储空间 -->
<fieldset class="cbi-section">
    <legend><%:Storage Space%></legend>
    <div id="storage-info">
        <!-- 动态内容 -->
    </div>
</fieldset>

<!-- 备份历史 -->
<fieldset class="cbi-section">
    <legend><%:Backup History%></legend>
    <table class="cbi-section-table">
        <tr class="cbi-section-table-titles">
            <th><%:Card Name%></th>
            <th><%:UUID%></th>
            <th><%:Last Backup%></th>
            <th><%:Status%></th>
        </tr>
        <tbody id="history-table">
            <!-- 动态内容 -->
        </tbody>
    </table>
</fieldset>

<%+footer%>
```

## iStoreOS 适配注意事项

### LuCI 版本检测

iStoreOS 可能使用以下版本之一：

1. **LuCI (Lua)** - 标准版本，上述代码直接可用
2. **LuCI2 (JavaScript)** - 需要重写为 JavaScript 视图
3. **LuCI ngx** - 基于 Nginx 的变体

**检测方法**：
```bash
# SSH 到 iStoreOS 设备
ls -la /usr/lib/lua/luci/
# 如果存在 controller/ 和 model/ 目录，说明是标准 LuCI
```

### 主题兼容性

- 使用标准 CBI 组件确保自动适配
- 避免自定义 CSS（除非必要）
- 测试常见主题：bootstrap, material, argon

### RPCD 权限

iStoreOS 可能启用了更严格的权限控制，需要正确配置：

```json
{
  "outdoor-backup": {
    "description": "Outdoor backup management",
    "read": {
      "uci": ["outdoor-backup"],
      "file": {
        "/opt/outdoor-backup/var/status.json": ["read"],
        "/opt/outdoor-backup/log/backup.log": ["read"]
      }
    },
    "write": {
      "uci": ["outdoor-backup"]
    }
  }
}
```

## 别名管理功能总结

### API 接口

| 方法 | 路径 | 功能 | 参数 |
|------|------|------|------|
| GET | `/api/aliases` | 获取所有别名 | 无 |
| POST | `/api/alias/update` | 创建/更新别名 | `{uuid, alias, notes}` (JSON body) |
| DELETE | `/api/alias/delete` | 删除别名（不删除数据） | `uuid` (query param) |
| GET | `/api/cleanup/preview` | 预览批量清理（列出所有卡和大小） | 无 |
| POST | `/api/cleanup/execute` | 执行批量清理（需要确认文字） | `{confirm_text}` (JSON body) |

### Shell 脚本修改

**common.sh 新增函数**（~70 行）：

1. **读取别名**
```bash
get_alias() {
    local uuid="$1"
    local alias_file="/opt/outdoor-backup/conf/aliases.json"

    # 使用 awk/grep 解析 JSON（避免依赖 jq）
    # 示例：awk -v uuid="$uuid" '/"'$uuid'":/{getline; if($0 ~ /"alias":/) {gsub(/.*"alias": *"|",.*/, ""); print}}'
    # 返回别名字符串（如果不存在则返回空）
}
```

2. **更新最后插入时间**
```bash
update_alias_last_seen() {
    local uuid="$1"
    local alias_file="/opt/outdoor-backup/conf/aliases.json"
    local temp_file="${alias_file}.tmp"

    # 原子更新 last_seen 字段
    # 使用 sed/awk 更新指定 UUID 的 last_seen
    # 原子写入：写入 tmp 文件后 mv
    # 如果 UUID 不存在，则创建新条目
}
```

3. **获取显示名称（简化版）**
```bash
get_display_name() {
    local uuid="$1"

    # 1. 优先使用路由器别名
    local alias=$(get_alias "$uuid")
    if [ -n "$alias" ]; then
        echo "$alias"
        return 0
    fi

    # 2. 回退到 UUID 前8位
    echo "SD_${uuid:0:8}"
}
```

4. **批量清理备份数据**
```bash
cleanup_all_backup_data() {
    local backup_root="$1"
    local keep_aliases="${2:-1}"  # 默认保留别名

    # 获取所有备份目录（UUID 格式）
    for dir in "$backup_root"/*; do
        if [ -d "$dir" ]; then
            local uuid=$(basename "$dir")
            # 验证是否为有效 UUID 格式
            if is_valid_uuid "$uuid"; then
                log_info "Cleaning up backup data for UUID: $uuid"
                rm -rf "$dir"/*  # 只删除内容，保留目录结构
            fi
        fi
    done

    # 如果不保留别名，删除 aliases.json
    if [ "$keep_aliases" = "0" ]; then
        local alias_file="/opt/outdoor-backup/conf/aliases.json"
        echo '{"version":"1.0","aliases":{}}' > "$alias_file"
    fi

    log_info "Batch cleanup completed"
}
```

5. **计算所有备份数据大小**
```bash
get_total_backup_size() {
    local backup_root="$1"

    # 使用 du 计算总大小（单位：字节）
    du -sb "$backup_root" | awk '{print $1}'
}
```

**backup-manager.sh 修改**（~10 行）：

```bash
# 在备份开始时调用
update_alias_last_seen "$SD_UUID"

# 生成 status.json 时使用（简化，不再需要 SD_NAME 参数）
local display_name=$(get_display_name "$SD_UUID")
```

### WebUI 前端 JavaScript

**view/outdoor-backup/status.htm 新增**（~80 行）：

```javascript
// 编辑别名模态框
function show_edit_alias_modal(uuid, current_alias, current_notes) {
    // 显示模态框，填充当前值
}

// 保存别名
function save_alias(uuid, alias, notes) {
    XHR.post('<%=url("admin/services/outdoor-backup/api/alias/update")%>',
        JSON.stringify({uuid: uuid, alias: alias, notes: notes}),
        function(x, data) {
            if (data && data.success) {
                // 刷新页面
                refresh_status();
            } else {
                alert('保存失败');
            }
        }
    );
}

// 删除别名
function delete_alias(uuid, delete_data) {
    if (!confirm('确定要删除此别名映射吗？')) return;

    XHR.get('<%=url("admin/services/outdoor-backup/api/alias/delete")%>',
        {uuid: uuid, delete_data: delete_data},
        function(x, data) {
            if (data && data.success) {
                refresh_status();
            } else {
                alert('删除失败');
            }
        }
    );
}
```

### 用户体验流程

**首次使用新卡**：
1. 插入新卡 → 自动备份 → WebUI 显示 "SD_550e8400"（UUID 前8位）
2. 用户点击"编辑" → 输入别名"三星TF卡Pro128G" → 保存
3. 刷新页面 → 显示"三星TF卡Pro128G"

**日常使用**：
1. 插入已有别名的卡 → WebUI 自动显示"三星TF卡Pro128G"
2. 查看历史记录 → 一目了然

**清理旧卡**：
1. 点击"编辑" → 点击"删除映射"
2. 选择"是否同时删除备份数据"
3. 确认 → 映射删除，备份数据根据选择保留或删除

### 并发安全

**问题**：backup-manager.sh 和 WebUI 同时写入 aliases.json

**解决方案**：
1. **原子写入**：先写入 `.tmp` 文件，再 `mv` 到目标文件
2. **读写分离**：
   - backup-manager.sh 只更新 `last_seen`（低频写）
   - WebUI 只更新 `alias` 和 `notes`（低频写）
3. **冲突处理**：由于都是原子写入，最多出现"后写覆盖先写"，不会导致文件损坏

### 初始化

**postinst 脚本**：
```bash
# 创建空的 aliases.json
mkdir -p /opt/outdoor-backup/conf
cat > /opt/outdoor-backup/conf/aliases.json <<'EOF'
{
  "version": "1.0",
  "aliases": {}
}
EOF
```

## 代码规模估算

### WebUI 完整功能（含批量清理）

| 文件 | 行数（含注释） | 说明 |
|------|----------------|------|
| Makefile | 80 | IPK 包定义 |
| controller/outdoor-backup.lua | 280 | 路由和 API（含别名 + 批量清理 API） |
| model/cbi/outdoor-backup/config.lua | 120 | 配置页面（含批量清理入口） |
| view/outdoor-backup/status.htm | 280 | 状态页面（含别名编辑 + 批量清理界面） |
| view/outdoor-backup/log.htm | 30 | 日志页面 |
| po/zh_Hans/outdoor-backup.po | 100 | 中文翻译（含所有功能） |
| **LuCI 总计** | **~890 行** | |

### Shell 脚本修改

| 文件 | 新增行数 | 说明 |
|------|---------|------|
| common.sh | 70 | 别名相关函数 + 批量清理函数 |
| backup-manager.sh | 10 | 调用别名函数 |
| cleanup-all.sh | 50 | 批量清理脚本（独立文件） |
| postinst | 15 | 初始化 aliases.json |
| **Shell 总计** | **~145 行** | |

### 总计

| 模块 | 行数 | 说明 |
|------|------|------|
| LuCI WebUI | 890 | Lua + HTML + JavaScript |
| Shell 脚本 | 145 | 别名支持 + 批量清理 |
| **总计** | **~1035 行** | |

**预计开发时间**：1.5 个工作日（12 小时）

## 开发优先级

### P0（必须有）- MVP
- [x] 状态文件格式定义（status.json + aliases.json）
- [ ] 配置页面（CBI）
- [ ] 状态页面（基本信息展示）
- [ ] 日志页面
- [ ] 别名管理 API（增删改查）
- [ ] 别名显示优先级（Shell 脚本：别名 > UUID前8位）
- [ ] 批量清理 API（预览 + 执行）
- [ ] 批量清理多重确认机制

### P1（应该有）- 用户体验
- [ ] 实时进度刷新（AJAX）
- [ ] 备份历史表格（含别名显示）
- [ ] 存储空间可视化
- [ ] 别名编辑界面（模态框）
- [ ] 删除别名确认对话框（强调不删除数据）
- [ ] 批量清理界面（两步确认 + 输入确认文字）

### P2（可以有）- 锦上添花
- [ ] 多语言支持（en_US, zh_CN）
- [ ] 错误日志下载
- [ ] 高级设置（并发控制等）
- [ ] 别名批量导入/导出
- [ ] 批量清理进度实时显示

## 测试计划

### 功能测试 - 基础
- [ ] 配置修改 → UCI → Shell 脚本生效
- [ ] 状态文件读取和解析（status.json）
- [ ] 进度条实时更新
- [ ] 备份历史显示

### 功能测试 - 别名管理
- [ ] 首次插入新卡 → 显示默认名称（SD_前8位UUID）
- [ ] 编辑别名 → 保存成功 → 刷新后显示别名
- [ ] 编辑备注 → 保存成功
- [ ] 再次插入已有别名的卡 → 自动显示别名
- [ ] 删除别名 → 映射消失，备份数据保留（验证文件仍存在）
- [ ] 显示名称优先级：别名 > UUID前8位（简化版）
- [ ] 并发测试：备份期间编辑别名 → 不冲突

### 功能测试 - 批量清理（重点测试）
- [ ] 预览批量清理 → 显示所有卡片和大小，数据正确
- [ ] 第一步确认 → 显示将删除的内容和保留的内容
- [ ] 第二步确认 → 输入错误的确认文字 → 按钮禁用
- [ ] 第二步确认 → 输入正确的确认文字但不勾选复选框 → 按钮禁用
- [ ] 第二步确认 → 输入正确且勾选 → 按钮启用
- [ ] 执行清理 → 备份数据全部删除
- [ ] 执行清理后 → aliases.json 保留（验证别名仍存在）
- [ ] 执行清理后 → 配置文件保留
- [ ] 执行清理后 → 日志文件保留
- [ ] 清理后插入旧卡 → 别名仍然正确显示
- [ ] 误触发防护：关闭对话框 → 不执行清理
- [ ] 误触发防护：取消按钮 → 不执行清理

### 兼容性测试
- [ ] Lean's LEDE 22.03（主要开发环境）
- [ ] OpenWrt 23.05（官方版本）
- [ ] iStoreOS 22.03（目标部署环境）
- [ ] 检查 LuCI 版本差异

### 主题测试
- [ ] Bootstrap（默认）
- [ ] Material
- [ ] Argon（流行第三方主题）

## 部署步骤

1. **修改 outdoor-backup 包**
   - backup-manager.sh 添加状态文件写入

2. **创建 luci-app-outdoor-backup 包**
   - 独立仓库或子目录

3. **编译测试**
   ```bash
   make package/outdoor-backup/compile V=s
   make package/luci-app-outdoor-backup/compile V=s
   ```

4. **安装到设备**
   ```bash
   opkg install outdoor-backup_*.ipk
   opkg install luci-app-outdoor-backup_*.ipk
   ```

5. **访问 WebUI**
   ```
   http://192.168.1.1/cgi-bin/luci/admin/services/outdoor-backup
   ```

---

## 【完整行动计划】待确认

### 第一步：环境检测（5 分钟）

**目标**：确认 iStoreOS 的 LuCI 版本和兼容性

**需要你提供**：
- iStoreOS 设备的 SSH 访问
- 或者你自己执行以下命令并提供输出：

```bash
# 检查 LuCI 版本
ls -la /usr/lib/lua/luci/

# 检查 CBI 框架
ls /usr/lib/lua/luci/model/cbi/

# 查看已安装的 LuCI 应用示例
ls /usr/lib/lua/luci/controller/

# 检查 LuCI 主题
ls /www/luci-static/
```

**预期结果**：
- 如果有 `controller/` 和 `model/` → 标准 LuCI（直接可用）
- 如果没有 → 需要调整方案

---

### 第二步：Shell 脚本修改（2 小时）

**目标**：添加别名支持和状态文件生成

#### 2.1 修改 `common.sh`（新增 3 个函数，~50 行）

**文件**：`files/opt/outdoor-backup/scripts/common.sh`

1. **get_alias()** - 从 aliases.json 读取别名
2. **update_alias_last_seen()** - 更新最后插入时间
3. **get_display_name()** - 获取显示名称（优先级：别名 > SD_NAME > UUID）

#### 2.2 修改 `backup-manager.sh`（~10 行）

**文件**：`files/opt/outdoor-backup/scripts/backup-manager.sh`

- 备份开始时调用 `update_alias_last_seen()`
- 生成 `status.json` 时使用 `get_display_name()`

#### 2.3 修改 postinst 脚本（~10 行）

**文件**：`Makefile` 的 postinst 部分

- 创建 `/opt/outdoor-backup/conf/aliases.json`

---

### 第三步：创建 LuCI 包（4 小时）

**目标**：创建独立的 `luci-app-outdoor-backup` 包

#### 3.1 创建目录结构

```bash
mkdir -p luci-app-outdoor-backup/{luasrc/{controller,model/cbi/outdoor-backup},root/usr/share/rpcd/acl.d,po/zh_Hans}
```

#### 3.2 编写核心文件

**文件清单**：
1. `Makefile`（80 行）- IPK 包定义
2. `luasrc/controller/outdoor-backup.lua`（180 行）- 路由和 API
3. `luasrc/model/cbi/outdoor-backup/config.lua`（80 行）- 配置页面
4. `luasrc/view/outdoor-backup/status.htm`（230 行）- 状态页面
5. `luasrc/view/outdoor-backup/log.htm`（30 行）- 日志页面
6. `root/usr/share/rpcd/acl.d/outdoor-backup.json`（30 行）- 权限定义
7. `po/zh_Hans/outdoor-backup.po`（70 行）- 中文翻译

---

### 第四步：测试验证（2 小时）

**测试环境**：
1. Lean's LEDE（你当前环境）
2. iStoreOS（目标环境）

**测试项目**：
- 配置页面能修改 UCI
- 状态页面能读取 status.json
- 插入 SD 卡后状态实时更新
- 别名增删改查功能
- 删除别名时可选删除备份数据

---

### 关键设计确认（已根据反馈修正）

#### 1. 状态文件格式 ✅

**aliases.json 格式**（已确认）：
```json
{
  "version": "1.0",
  "aliases": {
    "uuid": {
      "alias": "三星TF卡Pro128G",
      "notes": "户外摄影专用卡",
      "created_at": 1728825600,
      "last_seen": 1728825600
    }
  }
}
```

**确认**：格式简单够用，不需要额外字段 ✓

#### 2. 显示名称优先级 ✅

**最终设计**（已简化）：
```
1. 路由器别名（aliases.json）← 最高优先级
2. UUID 前8位（SD_550e8400）  ← 兜底
```

**修正说明**：
- ~~原计划的 SD_NAME（FieldBackup.conf）~~ → 不存在，已移除
- 简化为两级，消除不必要的复杂性 ✓

#### 3. 删除别名行为 ✅

**最终设计**：
- 删除别名**永远不删除**备份数据
- 删除数据需要使用专门的"批量清理"功能

**确认**：职责分离，更安全 ✓

#### 4. 批量清理功能 ✅

**防误触发机制**：
1. **两步确认**：第一步预览 → 第二步确认
2. **输入确认文字**：必须输入"清空备份数据"
3. **复选框确认**：必须勾选"我已经将数据备份到 NAS"
4. **明确显示**：列出所有将被删除的卡片和大小
5. **保留别名**：aliases.json 永远保留

**确认**：多重保护，防止误操作 ✓

#### 5. 进度更新频率 ✅

**当前设计**：
- backup-manager.sh 每 60 秒更新一次 status.json
- WebUI 每 10 秒通过 AJAX 刷新

**确认**：频率合适，不需要调整 ✓

#### 6. iStoreOS 适配 ⏸️

**当前计划**：
- 先在 Lean's LEDE 上开发和测试
- iStoreOS 环境检测列入待办，后续准备

**确认**：分步进行，优先完成 Lean's LEDE 版本 ✓

---

### 开发时间估算（更新版）

| 步骤 | 时间 | 说明 |
|------|------|------|
| Shell 脚本修改（基础） | 2 小时 | 别名支持 + 状态文件生成 |
| Shell 脚本修改（批量清理） | 1.5 小时 | cleanup-all.sh + common.sh 函数 |
| LuCI 包开发（基础） | 4 小时 | Controller + View + 别名 API |
| LuCI 包开发（批量清理） | 2.5 小时 | 批量清理 API + 多重确认界面 |
| 测试验证（基础功能） | 1.5 小时 | 别名管理测试 |
| 测试验证（批量清理） | 1 小时 | 误触发防护测试 |
| **总计** | **~12.5 小时** | （1.5 个工作日） |

---

### 下一步行动（已更新）

**设计文档已根据你的反馈完成修正**：

✅ **Q1 回答**：别名格式简单够用，保留当前设计
✅ **Q2 回答**：去掉不存在的 SD_NAME，简化为：别名 > UUID前8位
✅ **Q3 回答**：删除别名永不删除数据，职责分离
✅ **Q4 回答**：进度更新频率保持不变
✅ **Q5 回答**：iStoreOS 列入待办，优先完成 Lean's LEDE
✅ **额外需求**：批量清理功能，多重确认，保留别名

**设计亮点（Linus 风格）**：

1. **数据结构清晰**
   - aliases.json 独立于 UCI（数据 vs 配置分离）
   - 别名是"用户数据"，不影响系统行为

2. **消除特殊情况**
   - 显示名称优先级简化为两级（别名 > UUID）
   - 删除别名不删数据，批量清理不删别名（职责单一）

3. **零破坏性**
   - 删除别名不影响备份功能
   - aliases.json 丢失只影响显示，不影响备份

4. **实用主义**
   - 解决真实痛点：UUID 不可读 → 别名管理
   - 解决真实痛点：SSD 满了 → 批量清理（但防误触发）

**准备开始编码**：

📋 **待办事项**（按优先级）：

1. **Shell 脚本修改**（~3.5 小时）
   - common.sh：别名函数 + 批量清理函数
   - backup-manager.sh：调用别名函数
   - cleanup-all.sh：独立的批量清理脚本

2. **LuCI 包开发**（~6.5 小时）
   - Controller：API 路由（别名 + 批量清理）
   - Config：配置页面（含批量清理入口）
   - Status：状态页面（别名编辑 + 批量清理界面）

3. **测试验证**（~2.5 小时）
   - 别名管理功能测试
   - 批量清理误触发防护测试

**请确认是否开始编码**？
