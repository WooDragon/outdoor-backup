# 媒体日期库：本地操作与恢复边界

> 状态：主体本地实现与定向验证已闭合，有限范围复核 APPROVED；修后未重跑全量，不能发布。以下命令是源码核对后的接口说明，不是目标 R5S 部署批准。本次文档维护未在设备上执行这些命令。
> 场景：root 管理已挂载的 ext4/btrfs 目标，并使用独立日期库；不会访问私人素材、自动迁移旧镜像或创建 WebUI 队列。

**前置阅读**：操作前应先读取 [media-date-library-implementation.md](media-date-library-implementation.md) 的配置、来源身份及 G1–G6 边界。挂载目标前应先读取 [README 的 Configure target storage](../README.md#configure-target-storage)。WebUI 操作前应先读取 [WEBUI_USER_GUIDE.md](WEBUI_USER_GUIDE.md)。本文是日期配置、manual、initialize 和现行 cleanup CLI 的操作权威；其他文档只链接这些步骤。

## 1. 操作前确认

所有命令块均在已授权的 OpenWrt 设备 root shell 中执行。应先替换尖括号占位符。DEVNAME 是分区名，不含 `/dev/`；DEVPATH 是该分区在 sysfs 下的 `/devices/.../<DEVNAME>` 路径，不是 USB 控制器路径或盘的父路径。

先只读核对设备与实际模块，不凭包名存在认定能力齐全。

```sh
block info
opkg list-installed | grep -E 'outdoor-backup|exiftool|perl|rsync'
rsync --version
perl /opt/outdoor-backup/scripts/media-date-plan.pl probe
```

预期：管理员能逐项确认目标 UUID、来源分区和不同物理盘；probe 输出合法 version 1 能力对象。若 helper、模块或 rsync 不可用，应停止日期操作，取得匹配固件的可选包与 provider。probe 成功不证明目标文件系统、来源卡或库准入通过。source-loaded provider 证据不代替真实 IPK 安装验收；可选包边界应先读取 [BUILD.md](../BUILD.md#可选日期包与-provider-边界)。

## 2. 选择新日期库

应先确认没有活动备份或其他维护 owner。若需要更改配置，应先执行 service stop；只有返回 0 才表明已准入工作停止。stop 非零时应保留挂载和锁，读取系统日志并核对当前 owner，不使用宽泛 kill 或直接删锁。

```sh
/etc/init.d/outdoor-backup stop
```

stop 成功后，核对当前配置。

```sh
uci show outdoor-backup
block info
```

目标必须已由 fstab 挂载。日期根应为该目标的直接新子目录；不存在或真正空目录才可首次初始化。它应与镜像根、来源挂载点互不包含。应保留旧镜像根配置，不把原镜像目录改成日期根。

下面使用独立占位符，不自动选择设备。固定 offset 应由管理员显式选择，`480` 表示 UTC+08:00，`0` 表示 UTC；不能给新库留空或沿用设备 TZ 猜测。

```sh
TARGET_MOUNT='<EXACT_ALREADY_MOUNTED_TARGET>'
TARGET_UUID='<UUID_FROM_INTENDED_TARGET>'
BACKUP_ROOT="$TARGET_MOUNT/<MIRROR_CHILD>"
LIBRARY_ROOT="$TARGET_MOUNT/<NEW_DATE_LIBRARY_CHILD>"
ARCHIVE_OFFSET_MINUTES='<CANONICAL_INTEGER_-840_TO_840>'

uci set outdoor-backup.config.target_mount="$TARGET_MOUNT"
uci set outdoor-backup.config.target_uuid="$TARGET_UUID"
uci set outdoor-backup.config.backup_root="$BACKUP_ROOT"
uci set outdoor-backup.config.library_root="$LIBRARY_ROOT"
uci set outdoor-backup.config.archive_offset_minutes="$ARCHIVE_OFFSET_MINUTES"
uci set outdoor-backup.config.backup_layout='date'
uci commit outdoor-backup
```

预期：配置显式选择 date，不改旧数据。库尚未因为 UCI commit 而建立。应检查 legacy 配置和有效继承是否符合预期；`uci show` 只显示 UCI 层。CBI 保存也不会执行卡初始化、备份或历史迁移。既有 library.json 固定的 offset 不应在线修改；改 UCI 不会重算历史路由。

## 3. 显式初始化缺配置的新卡

应先确认服务已启用准入且 `enabled=1`。应确认来源未被其他程序挂载。管理员应通过实际 `block info` 与 sysfs 确认分区；以下命令只读取分区路径。

```sh
DEVNAME='<SOURCE_PARTITION_NAME>'
SOURCE_SYSFS=$(readlink -f "/sys/class/block/$DEVNAME")
printf '%s\n' "$SOURCE_SYSFS"
DEVPATH=${SOURCE_SYSFS#/sys}
printf '%s\n' "$DEVPATH"
```

预期：SOURCE_SYSFS 指向真实 `/sys/devices/.../<DEVNAME>`，DEVPATH 对应 `/devices/.../<DEVNAME>`。应人工核对后才继续，不接受空值、错误节点或不相干父路径。

在明确允许该新卡写入 `FieldBackup.conf` 的前提下，执行独立初始化。

```sh
/etc/init.d/outdoor-backup start
/opt/outdoor-backup/scripts/backup-manager.sh initialize "$DEVNAME" "$DEVPATH"
```

预期：正式配置缺席时，manager 经来源 snapshot 和目标守卫打开有界 RW 窗口，发布新的 PRIMARY 配置，恢复 RO 后收尾。它不启动 rsync，不更新 alias 或 identity，不建立素材路由。正式配置已经存在时，它只读取合法 PRIMARY 配置，不覆盖文件。非法配置、REPLICA 或非普通正式对象仍拒绝。成功后还需实际备份，不能把初始化当作备份完成。

date 自动任务遇到未配置卡只报 `source_not_initialized`，不会替管理员执行这一步。格式化后不应复制旧卡配置来认领旧来源；已有配置不会因 initialize 自动获得新身份。

## 4. 执行本次手动任务

应先按上一节核对来源设备和 DEVPATH。应确认 `enabled=1`、服务准入和目标挂载有效。有效配置为 `enabled=0` 时，manual（quick 或 checksum）与 initialize 均返回 5，并明确诊断所拒绝的 action；manager 不进入备份生命周期，不创建卡配置、route、identity、alias、status 或目标目录，不打开来源 RW 窗口，也不启动 rsync 或传输 runner。自动 add 仍成功忽略。以下两条二选一，不连续执行两次当成一次任务。

```sh
# 日常比较；mirror 和 date 均可用。
/opt/outdoor-backup/scripts/backup-manager.sh manual "$DEVNAME" "$DEVPATH" quick

# 仅 date；对当前卡及对应目标做显式深度内容比较。
/opt/outdoor-backup/scripts/backup-manager.sh manual "$DEVNAME" "$DEVPATH" checksum
```

预期：manager 同步运行一个任务并返回真实结果；checksum 不持久化到 UCI，也不影响下次自动 quick。mirror 的 checksum 请求直接拒绝。没有 UUID-only manual、WebUI trigger、自动 SSD-ready consumer 或冷插卡重试队列。

quick 可能漏掉同 size/mtime 的内容变化。仅 mtime 改变可保留同内容旧文件。checksum 可能读取当前全部 source 和对应 target，不核验卡上已不存在的历史媒体。任务返回 0 或 completed 都不表示全库历史内容审计。

若目标尚未就绪导致失败，应先修复目标，再安全移除并重新插入来源，或重新核对后使用 manual。应保留路由和 partial/replaced，不能直接运行任意 rsync 或删状态绕过拒绝。

## 5. 查看状态与保留证据

```sh
jq '{current_backup,storage,history}' /opt/outdoor-backup/var/status.json
logread | grep outdoor-backup
```

预期：date task 显示布局、本次比较和 phase。planning 表示分析素材，finalizing 表示同步与最终检查，二者没有 ETA。transferring 的采样不构成完整性审计。应先读取 [WEBUI_DEVELOPER_GUIDE 的 task 合同](WEBUI_DEVELOPER_GUIDE.md#日期任务与状态合同) 理解 archive、warnings 和 replaced 的未知值。

在任务退出且 owner 释放后，可只读列出自己的库元数据位置。

```sh
ls -ld "$LIBRARY_ROOT/.outdoor-backup" "$LIBRARY_ROOT/.card-identities"
ls -l "$LIBRARY_ROOT/.outdoor-backup/library.json"
```

routes 是位置记录，不是完成标记。library/routes/identity 缺失或损坏时，应停止写库并保存现存元数据及日志。应先核对离线状态备份，不能删除 identity 强制重绑、扫描文件名猜回 routes 或将非空根重新初始化。首版没有受管重分类、路由重建、改名修复或自动回滚命令。元数据备份应与相应媒体快照一致；不应将 GPS、序列号、私人路径、完整 XML 或原始 UMID 公开提交。

## 6. 镜像清理的现行入口

本节只用于 mirror；date 媒体没有旧 cleanup 删除协议。应先验证 NAS/其他目的地确有可恢复副本。清理不可撤销。应人工确定当前有效 `BACKUP_ROOT`，不使用任意根、挂载点、日期 bucket、前缀通配符或裸 `rm -rf`。

```sh
BACKUP_ROOT='<EXACT_CURRENT_EFFECTIVE_MIRROR_ROOT>'
/opt/outdoor-backup/scripts/backup-manager.sh cleanup-preview "$BACKUP_ROOT"
```

预期：预览取得并释放自己的 service lease 和 owner，验证 target-only FD 9、当前 UUID、全部祖先和全部子树后输出 version 1 mirror 对象。大小来自 `du -sk` 的估算，不保证删除后释放同等字节。预览不是执行授权，也不持锁等待浏览器确认；执行时重新检查。

管理员确认后才执行 CLI。`--force` 或 `-f` 必须在首位；它只确认 CLI 删除意图，不绕过任何后端检查。最后一个位置参数只能是 0 或 1，缺省为 1。

```sh
# 保留 alias；服务应仍可准入，enabled 应为 1。
/opt/outdoor-backup/scripts/cleanup-all.sh --force "$BACKUP_ROOT" 1
```

预期：只删除一级 UUID 目录的非 hidden child 子树。根级 hidden 项、UUID 级 hidden 项、UUID 目录和 `.card-identities` 保留；可见子树中的内容随该子树删除。1 保留 alias，0 清空 alias 映射但仍保留 identity。清理不保证刷新或清空备份 history。所有候选先预检，发现日期标记或残留 routes 时整次拒绝；切回 mirror、传 force 或指定 date root/bucket 都不能绕过。

非零返回时应保留现场并检查原因。退出码为 1 参数/force、2 根不符、3 检查或执行失败、4 日期状态不受此协议清理、5 服务不可用或 busy、130/143 取消。一次正在执行的删除可在 TERM 后完成，后续写入门会停止新删除；不承诺事务回滚或精确释放空间。

## 7. 切回 mirror 与安全卸盘

若只需要停止日期备份，应先 stop 并确认返回 0。若要切回 mirror，应保留日期库及其隐藏状态，核对镜像根与日期库隔离后仅改变布局。

```sh
/etc/init.d/outdoor-backup stop
# 仅在 stop 成功且配置隔离已核对后继续。
uci set outdoor-backup.config.backup_layout='mirror'
uci commit outdoor-backup
```

预期：下次任务采用 mirror；旧日期库不迁移、不删除，磁盘上的日期状态仍受保护。应保留原日期 offset 和根记录，不能把旧日期 bucket 指为镜像根。重新开始工作时可使用现有 init start。配置/API snapshot 不改运行中的任务。

卸盘前应停止所有使用该目标的消费者，包括本项目之外的程序。只有 stop 成功且其他消费者也已停止时，才按 fstab/设备自身流程卸载目标。该流程不部署、不启动或自动索引 PhotoPrism。真介质拔盘、掉电和消费者端到端验收仍未完成。
