# 组件详细实现

## 1. 热插拔触发脚本

运行时实现以 [`90-outdoor-backup`](../files/etc/hotplug.d/block/90-outdoor-backup) 为单一事实源。`add` 仅处理分区事件。它在读卡器识别后读取生命周期状态。运行态的 `add` 在 settle 前捕获 generation，并通过环境变量传给 manager。停止态的 `add` 不排队 manager。`remove` 绕过 service、configuration 和 reader gate，并传入原始事件参数 `DEVNAME`、`DEVPATH` 和 `SEQNUM`。

## 2. 备份管理器主脚本

### 文件：`/opt/outdoor-backup/scripts/backup-manager.sh`

管理器先验证事件。它随后取得 FD 8 shared admission lease。它再通过 FD 9 运行目标守卫。目标守卫成功后，管理器才进入其余既有流程。管理器由 [`config.sh`](../files/opt/outdoor-backup/scripts/config.sh) 加载有效配置。有效值的顺序是 defaults < legacy `backup.conf` < 显式 UCI option。`TARGET_MOUNT` 的默认值为 `/mnt/ssd`。`TARGET_UUID` 的默认值为空。`add` 事件要求用户配置非空的目标 UUID。`remove` 事件不要求目标介质在场，仍进入清理路径。

目标守卫在加载 `common.sh`、注册 cleanup trap、获取锁、挂载来源卡、读取别名和创建应用日志之前运行。管理器按以下顺序调用当前实现：

1. [`target.sh`](../files/opt/outdoor-backup/scripts/target.sh) 以 FD 9 打开目标挂载。它要求配置路径不是符号链接。它要求目录存在。它要求内核 `/proc/<manager-pid>/mountinfo` 中的挂载记录精确匹配该路径。它还要求 VFS 与文件系统级选项均为 `rw`。
2. [`target-device.sh`](../files/opt/outdoor-backup/scripts/target-device.sh) 校验官方 `block info` 返回的 UUID。`target_device_read_block_uuid` 复用严格 token 解析。它输出唯一 UUID 字段的原始值。现有比较 wrapper 使用该读取结果。两者不决定来源卡身份。它用 sysfs 证明目标、来源卡和系统 backing disk 的物理盘不同。它接受 direct `sd`、`mmc`、`nvme`。系统 loop 仅在 backing file 明确指向 `/dev/` 分区时可追溯。unknown 或 deleted backing、file-backed loop、`dm` 与 `md` 均失败关闭。它解析 `block info` 的完整键值 token。`LABEL` 值内的同形文本不算 UUID。畸形引号会被拒绝。
3. `target_prepare_root` 要求 `BACKUP_ROOT` 是目标挂载的严格子目录。它通过 `/proc/<manager-pid>/fd/9` 创建目录。既有符号链接组件，包括 `.logs`，会被拒绝。守卫拒绝覆盖目标挂载点、`BACKUP_ROOT` 祖先或备份树内子挂载。不相交目录的挂载不会被误拒。

初始守卫失败时，管理器向 stderr 和 error 级 syslog 报错。它可触发可选红灯。它不进入来源挂载、`rsync`、别名、锁或应用日志生命周期。LED helper 创建延时子进程前，管理器关闭目标 FD。缺少 LED 不改变失败的非零退出状态。`enabled=0` 的 `add` 事件在任何 LED 副作用前退出。

守卫成功后，目标目录和日志都经 FD 9 引用。管理器在目标准备、`rsync` 前、`rsync` 后及末尾的设备复验中检查锚点。目标卸载、替换或只读重挂载不应产生成功结果。日志摘要写入失败，以及摘要后的 detached 或只读复检失败，均返回非零。

静态符号链接检查不是 `openat2`。恶意 root 并发替换目标目录不在此 shell 实现的保证范围内。未知或 deleted loop backing 无法证明身份时会失败关闭。本文档不声称真机全兼容。`FieldBackup.conf` 由 [`card-config.sh`](../files/opt/outdoor-backup/scripts/card-config.sh) 按数据读取，绝不 `source` 或 `eval`。该读取器只导出 `SD_UUID`、`BACKUP_MODE`、`CREATED_AT` 与旧 `SD_NAME`。其他合法赋值会被忽略。畸形数据或缺失、非法 UUID 会失败，且不会重写现有卡配置。读取器为兼容数据仍接受 `REPLICA`。自动管理器仅执行 `PRIMARY` 的 SD 卡到目标存储方向；它读取既有 `REPLICA` 卡后明确失败，不执行 `rsync`，不改变卡文件或 UUID，不更新 alias，也不创建目标 UUID 叶目录或备份日志。管理器不会将 `REPLICA` 自动改为 `PRIMARY`。新卡配置只生成 `PRIMARY`。`backup-transfer.sh` 直接调用正式 `rsync` 并保留真实退出码；#14 的旧管道退出码限制不再适用。最终包 CI、固件 CI 与真机验证仍未完成。

首次配置是软件实现的受控流程：管理器只在不存在正式 `FieldBackup.conf` 时打开来源卡的读写窗口。它在同目录创建唯一临时文件，检查完整写入后以 rename 发布正式文件，并检查 `sync`。该流程拒绝符号链接和其他非普通正式对象。`SOURCE_MOUNTED` 仅在本进程 mount 成功后置位。每次成功显式 umount 都清除该状态。失败的 umount 保留该状态，让持锁 cleanup 重试一次。`mount_sdcard` 拒绝已经是挂载点的来源路径，避免叠加挂载。cleanup 只有在 `LOCK_HELD=1` 且锁链接仍指向本进程时才操作共享资源。它先完成来源清理和 `sync`：该 sync 失败会将此前成功的 transfer 转为 `rsync`/exit 1，但不会替换既有业务失败码；仅 sync 成功的 transfer 才可写 `completed`。finalization 决定后，失败状态在目标 FD 关闭前写入，随后 LED 终态、日志和锁释放。未持锁进程只关闭自身 target anchor，并保留原退出码。恢复只读后的重读只验证流程控制，不证明实际介质写入、断电持久性或正确卡身份。现有 Docker 测试以 mount、umount 和文件操作桩证明该控制流；真卡、断电、克隆身份和多分区证据仍待验证。

### Source snapshot and card identity binding

After target validation and trap registration, every three-argument and four-argument `add` sources `source-identity.sh` and captures one source snapshot before lock contention. The source-only library has no persistent state and does not mount, lock, cancel, or install traps. Disabled `add` and `remove` exit before the library loads or reads source state. The snapshot contains `DEVNAME`, the canonical sysfs node, major:minor, the normalized filesystem UUID, and the parent gendisk `diskseq` as a decimal string or `null`.

`source-identity.sh` samples topology, reads the exact `/dev/<DEVNAME>` filesystem UUID through the strict `block info` reader, and samples topology again. Both topology samples must match. A missing, malformed, wrong-node, or duplicate UUID field rejects the sample. `diskseq` is `null` only when its sysfs attribute is genuinely absent. A present attribute must be a non-symbolic regular file with exactly one nonempty physical record; that record may end with one terminal LF. The library rejects an empty value, an extra empty or nonempty record, a read failure, a symbolic link, zero, a leading-zero form, non-decimal text, and an unsigned-64-bit overflow. Present-to-absent and absent-to-present changes also reject comparison. The library does not use shell arithmetic for the unsigned 64-bit value. A kernel without the attribute has only the weaker UUID-and-topology comparison.

The manager keeps this snapshot as an opaque baseline. It rechecks the baseline after acquiring the lock and before every `mount_sdcard` side effect, including the initial read-only mount and a blank card's read-only-to-read-write-to-read-only sequence. After the initial read-only mount, it reads the actual source filesystem UUID through `card_identity_read_source_uuid` and compares it exactly with the snapshot `filesystem_uuid`. The manager checks the sticky cancellation state after capture, after the post-lock recheck, and after each per-mount recheck. Thus, a `TERM` received while a probe runs prevents the later LED start or mount side effect. A capture, recheck, consumption read, or UUID comparison failure sets `ERROR_TYPE=device_unknown`; the manager performs no later source operation and never reports completion. The manager never replaces the baseline to accommodate a replacement medium. The post-read-only-mount `SOURCE_FS_UUID` read remains separate from snapshot storage: `card-identity.sh` uses the observed value for the existing card-binding record. This comparison does not claim a post-mount full-snapshot recheck or an atomic mount.

The rechecks narrow substitution races but do not make mount atomic. A delayed `add` cannot identify media already replaced before snapshot capture. Another replacement can occur after a successful recheck and before mount. The snapshot is not a physical-card identifier: `diskseq` depends on Linux and driver media-change reporting, does not increase merely because a partition is rescanned, and must not be interpreted as proof that every reader swap increments it. A clone remains indistinguishable if all observed fields match and the kernel does not report a media change.

The manager validates `FieldBackup.conf` before it binds the loaded `SD_UUID`. It creates or reads `.card-identities/<SD_UUID>.json` below `TARGET_BACKUP_ROOT`, which is itself an FD 9 path. `target_prepare_directory` creates the relative identity directory. The v1 JSON object has exactly `version: 1`, `sd_uuid`, and normalized `fs_uuid`. `jq` validates the JSON object, key set, types, version, and card UUID. Shell validation checks the source UUID character set and lowercase normalization because the pinned OpenWrt `jq` lacks regex support.

A missing record uses a same-directory `mktemp` file, `jq` serialization, rename, `sync`, and final anchor validation. The manager checks anchor health before directory or record work, before publication, and after publication. It rejects an existing link, directory, malformed record, wrong card UUID, unsafe source UUID, or different source UUID. It does not overwrite a rejected record. It does not update aliases or start transfer after a binding rejection. The global manager lock serializes normal publication. This shell code does not claim protection against hostile concurrent root mutations or power-loss atomic durability. `SIGKILL` can leave the temporary name behind; the manager never treats or scans it as a record.

A legacy backup directory without a record receives a first-observation binding. This compatibility behavior preserves its directory, data, and aliases. It cannot prove the historical source of that data. A filesystem UUID identifies a filesystem, not a physical SD card. A clone remains indistinguishable only when every observed snapshot field is the same and the kernel does not report a media change.

LuCI 表单提供 `target_mount`、`target_uuid` 和 `backup_root` 说明。表单在 `enabled=1` 时要求 UUID。表单在 `enabled=0` 时允许空 UUID。字段的合法值和路径检查不代表表单会自动挂载或格式化介质。

> **前置阅读**：目标存储的可执行配置、重试方法和用户可见限制，修改部署或运维行为前必须先读取：[README.md 的 Configuration 章节](../README.md#configuration)。

运行时细节以 [`backup-manager.sh`](../files/opt/outdoor-backup/scripts/backup-manager.sh)、[`source-identity.sh`](../files/opt/outdoor-backup/scripts/source-identity.sh)、[`card-config.sh`](../files/opt/outdoor-backup/scripts/card-config.sh)、[`card-identity.sh`](../files/opt/outdoor-backup/scripts/card-identity.sh)、[`target.sh`](../files/opt/outdoor-backup/scripts/target.sh) 和 [`target-device.sh`](../files/opt/outdoor-backup/scripts/target-device.sh) 为单一事实源；本文档不复制生产算法。

## 3. 传输、空间与状态模块

`backup-transfer.sh` 是在 add 事件的目标守卫成功后才由管理器显式加载的 inert source-only 模块。它不安装 trap，也不改变 disabled 事件或初始 guard 的资源约束。该模块直接运行正式 `rsync --archive --recursive --times --prune-empty-dirs --partial --stats`，并从该命令捕获真实退出码。它不会使用 pipeline、退出码文件、`--ignore-existing`、任何 append 家族选项或 `--delete`。rsync 根据 size/mtime quick check 更新文件，因而不能保证发现 size 和 mtime 都未变的内容变更。只有诊断含 `No space left on device` 或 `ENOSPC` 时，失败才分类为 `no_space`；单独的 rsync exit 11 或 12 不是满盘结论。

`check_minimum_free_space` 在创建备份叶目录后，经 FD 9 的目标路径调用 `df`。它不对整张卡或备份树执行 `du` 扫描。`MIN_FREE_SPACE` 默认为 1024 MB；非负十进制整数合法，`0` 禁用余量。无法取得可信 `df` 值时，守卫失败关闭。

`status.sh` 依赖 `jq`。它把 `current_backup`、经活 FD 获取的 `storage` 和 `history` 原子写入唯一的 `status.json` 快照。它不维护 `history.jsonl`。history 以 UUID 去重，最新终态在前，最多 20 条。运行期间 `current_backup` 仅表达 active/running，未知进度和速率字段均为 0。成功终态的文件数和字节数来自 `rsync --stats`。管理器仅在 rsync、cleanup `sync`、汇总写入和最后的锚点健康及身份复验均成功后才写 `completed`。

持锁 `cleanup` 先清理传输临时文件和本进程拥有的来源挂载。它随后执行 `sync`。cleanup `sync` 失败时，管理器将此前成功的 transfer 转为 `rsync`/exit 1。cleanup `sync` 失败时，管理器保留既有业务失败码。cleanup `sync` 成功后，管理器才可写 `completed`。finalization 判定失败后，管理器在关闭目标 FD 前写入 failed 状态。管理器随后写 LED 终态和日志。管理器最后释放锁。`ERROR_TYPE` 的现有调用映射为 `device_unknown`、`lock_timeout`、`no_space`、`card_config`（红灯 4 闪，SD 卡配置被策略拒绝，例如既有 `REPLICA` 卡）、`rsync` 和 `verify_failed`。本文档不把未覆盖的 LED 类型表述为端到端验证。

### #16c：remove 事件的 owner 匹配

hotplug 的 `add` 分支在 settle 后把原始 `SEQNUM` 作为第四个参数传给 manager。它仍执行读卡器识别。`remove` 分支不读取 sysfs、UCI 或读卡器白名单。它直接以引用保护的原始 `DEVNAME`、`DEVPATH` 和 `SEQNUM` 调用 `backup-manager.sh remove`。

manager 只接受三参数或四参数的 `add` 和 `remove`。三参数 add 保持兼容，但不会建立可被自动 remove 取消的事件身份。三参数 remove 以 0 退出，并向 stderr 和 syslog 记录缺少身份。四参数 remove 先 source `target-device.sh` 的词法设备名校验和无状态 `owner-event.sh`；它不加载配置、目标、挂载、状态、传输、LED 或 cleanup 生命周期。

`owner-event.sh` 不创建共享状态。它要求 `jq`，校验正规范 `DEVNAME`、以 `/devices/` 开头且末段等于设备名的 `DEVPATH`，以及无前导零的正 64 位十进制 `SEQNUM`。它从原子锁链接读取候选 `/proc/PID`，拒绝自身、PID 1、非正规范 PID、失效进程和 zombie。它读取 `/proc/PID/stat` 的 starttime，并使用 `jq -Rs` 按原始 NUL 分隔 argv 精确匹配 `/bin/sh|/bin/ash manager add owner-devname owner-devpath owner-seq`。事件只在 owner 序号严格小于 remove 序号，且路径为同一分区或 remove 路径加 owner 设备名这一直接父盘关系时匹配。

发送前 helper 重读 starttime 和锁链接。两项都未变化时，它才向该单一 PID 发送一次 `TERM`。缺锁、陈旧锁、无效字段、argv 不匹配、路径不匹配、序号不递增或证据变化均不会改写共享资源。身份输入无效、缺 `jq` 或 `TERM` 失败返回非零；无 owner 或 owner 不匹配记录 notice 后以 0 返回。已有 owner 的 sticky cancel、传输 drain 和 cleanup 负责其后的收尾。

该实现的保证是：拔出 B 不应取消正在备份 A 的匹配 owner。它不保证拔出 B 会自动使 B 的备份消失。hotplug `remove` 不取消 waiter；waiter 可以等待至获锁或超时。administrative `stop` 通过 generation-current 准入 gate 取消已准入 waiter。三参数和四参数 `add` 都在获锁后复验其 pre-lock source snapshot。三参数 add 另有独立限制：它不具备自动 remove 身份匹配。`SEQNUM` 只是顺序证据，不是卡身份。hotplug 没有零丢包或时延保证。POSIX `/proc` 加 `kill` 仍有最终 TOCTOU，不能宣称等价 pidfd。crash 后残留挂载恢复仍属 #16 后续工作。

本批在固定 `openwrt/rootfs:x86_64-24.10.8` 隔离容器和 sysfs/block fixture 中记录：`test-source-identity.sh` 为 8 cases、42 assertions、0 failures；`test-manager-source-identity.sh` 为 12 cases、247 assertions、0 failures；`test-target-manager.sh` 为 40 cases、366 assertions、0 failures；`test-manager-cancellation.sh` 为 8 cases、96 assertions、0 failures。来源库覆盖稳定双拓扑采样、UUID/节点/major:minor/diskseq 变化、严格 `diskseq` 读取和观测期间变化，并以函数局部 `LC_ALL=C` 固定 20 位 unsigned-64-bit 的字典序比较，不改变调用方 locale。manager suite 的 base 计数为 245 assertions。该 suite 的独立计数 mutant 只删除一条无副作用观测，结果为 244 assertions、1 failure，唯一计数门失败；外层检查另增加 2 条断言。S06 删除获锁后门时可启动 LED，但逐 mount 门仍拒绝挂载，因而该证据不表示已复制或写入卡。S12 在初始只读 mount 后将夹具来源 UUID 从 A 切换至 B；正常路径在消费 UUID 与 snapshot `filesystem_uuid` 不一致时以 `device_unknown` 停止，不创建 identity、alias、`rsync` 或 completion。仅删除该消费比较的 runtime mutant 会让 B 到达原本错误的 binding 路径。S12 也覆盖 post-mount UUID 读取失败的同一错误分类。C05 证明 source-UUID lookup 期间的 `TERM` 被 outer gate 拦截而不进入 setup；删除 outer gate 的 runtime mutant 可进入 setup，但 per-mount cancel gate 仍阻止 RW mount 和配置发布。C06 的 sync 期间 `TERM` 保留已发布配置，并阻止后续只读恢复、identity、alias 与 `rsync`；外层 post-setup gate 的 normal/mutant 对照只在真实 setup 成功返回后才注入 `TERM`，不将该证据描述为 sync 期间信号穿透内部检查。上述记录不代表完整回归、CI、真机、包构建或固件构建。

The pre-finalization sync gates transfer completion. The summary is appended to the backup log; `status.json` is replaced atomically. Neither update carries a power-loss durability guarantee.

### 服务生命周期与准入（#16）

[`service-state.sh`](../files/opt/outdoor-backup/scripts/service-state.sh) 是 source-only 生命周期库。它在私有运行目录维护严格的 `running:<generation>` 或 `stopped:<generation>` 状态记录。generation 是从 `0` 到 `2147483647` 的十进制整数。controller 在固定 FD 7 上持有独占 control lock。manager 在固定 FD 8 上持有 shared admission lease。controller 在 FD 8 上持有独占 admission lock。库会校验 FD 的锁模式、mount ID 与 inode，并拒绝链接、非普通锁文件和无效状态记录。

[`service-control.sh`](../files/opt/outdoor-backup/scripts/service-control.sh) 在一次 FD 7 获取内执行 `start`、`stop` 或 `restart`。`start` 仅在停止态推进 generation。它先取得 admission 独占锁并确认业务锁缺席，再发布新的 running generation。`restart` 先完成 stop；失败的 stop 不会进入 start。

`stop` 先把当前 generation 发布为 stopped。controller 随后反复取得 admission 独占锁，并检查业务锁缺席。二者同时成立时才证明 quiescence。业务锁仍存在时，controller 只向经锁链接、`/proc` starttime 和原始 NUL 分隔 argv 复核的当前 manager owner 发送一次 `TERM`。owner 的正常退出不是成功结论；controller 会在下一轮重新确认 admission 独占与业务锁缺席。无法证明 owner、无法获取 admission、超时或收到取消时，stop 返回非零。

manager 在目标守卫、来源 mount、LED、业务锁和其他备份副作用前取得 shared admission lease。hotplug 传入 generation 时，manager 只接受该 running generation。manager 在取消检查点复验 lease 仍对应当前 running generation。lease 失效会以取消路径退出。cleanup 显式释放 lease；仅原始 FD owner 可解锁，继承 FD 的子进程只能关闭已验证的副本。

hotplug 的 `add` 分支在读卡器识别后读取状态。停止态直接退出而不排队 manager。运行态在 settle sleep 前捕获 generation，并以原始 `DEVNAME`、`DEVPATH` 和 `SEQNUM` 调用 manager；sleep 不会改写 argv。`remove` 分支绕过状态、配置和读卡器 gate，直接将原始事件槽位送入 manager 的 remove 验证路径。

[`/etc/init.d/outdoor-backup`](../files/etc/init.d/outdoor-backup) 只准备私有运行路径并逐字传播 controller 的退出状态。`PKG_UPGRADE=1` 时，init 只有在已解析的 `/etc/rc.d/SNNoutdoor-backup` 链接仍指向该 init 脚本时才 restart；禁用服务保持 stopped。`reload` 不改变生命周期状态。Makefile 的当前包元数据为 `1.2.0-11`，并按 BusyBox CUSTOM 条件选择 `flock`。`prerm` 只调用 controller stop，保留其失败状态，不执行广泛 `pkill`，不删除备份数据，也不自动删除无法验证的残留业务锁。因而失败的 stop 不保证 package wrapper 回滚。

### #16b：传输取消与进程边界

[`transfer-process.sh`](../files/opt/outdoor-backup/scripts/transfer-process.sh) 是惰性 source 库，唯一公开 `transfer_process_run`。它为同一管理器的一次 `rsync` 建立私有 session/process group；`backup-transfer.sh` 的 argv、`--stats`、`--partial` 和无 `--delete` 语义不变。该库不注册 trap，也不触及 mount、lock 或 status。

管理器只记录首个 `INT`/`TERM` 的 sticky 码（130/143），并在阶段边界阻止后续独立副作用。首个请求直接写入 syslog；它不写共享 `backup.log`。runner 验证 leader 的 PID、starttime、PGID 和 session 后，才向该组发送一次 `TERM`。leader 退出而子进程仍在时，它保守等待；连续两次空扫描后才返回。它向 stderr 保留自身诊断，并把首次取消等待、不可验证 leader、失败 TERM 和不可读 `/proc` 镜像到 syslog，但不转发任意 rsync stdout 或 stderr。它不猜测 PID、不用 pidfd 或原子进程快照，不能读 `/proc` 时也不升级为 `KILL`。终态出口先 ignore 信号再最后采样，故边界前已记录的取消不能写 `completed`，边界后的新信号被忽略。已建立 running 状态时，取消通过 failed 写入路径记录 history 的 `status="error"` 与 `error_message="cancelled"`；更早取消不改写既有状态。正在执行的卡配置发布或只读恢复可在下一检查点前完成，不承诺回滚。

该协议要求 root、常规 Linux、可读 `/proc` 和 BusyBox `setsid`。Makefile 仅按 CUSTOM 条件选择 `BUSYBOX_CONFIG_SETSID` 或 `BUSYBOX_DEFAULT_SETSID`；ImmortalWrt 24.10.6 默认具备，OpenWrt 19.07.10 默认缺失。IPK 不会补齐既有 BusyBox，缺失时不启动 `rsync`。

固定 rootfs 的记录为 process 8/40、core 11/121、cancellation 7/61；未改动复测为 target-manager 40/365、config 20/96、lock 13/45，status 9/47 是早期基线。覆盖 session 隔离、起步窗口、0/23、leader 早退、fork replacement、实际 `TERM`/`INT`、ignore 两侧和 source config/`df` 取消。未声称全仓、CI、构建或真机验证；也未独立覆盖不可读 `/proc`、zombie-only、长期忽略 `TERM` 或混合信号。

## 4. 公共函数库

### 文件: `/opt/outdoor-backup/scripts/common.sh`

```bash
#!/bin/sh
#
# Common functions for SD Card Backup System
#

# LED paths - R5S specific, needs verification
LED_GREEN="/sys/class/leds/green:lan"
LED_RED="/sys/class/leds/red:sys"

# Logging functions
log_info() {
    logger -t "$LOG_TAG" -p info "$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $1" >> "$BASE_DIR/log/backup.log"
}

log_error() {
    logger -t "$LOG_TAG" -p err "$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $1" >> "$BASE_DIR/log/backup.log"
}

log_warn() {
    logger -t "$LOG_TAG" -p warn "$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN] $1" >> "$BASE_DIR/log/backup.log"
}

log_debug() {
    if [ "${DEBUG:-0}" = "1" ]; then
        logger -t "$LOG_TAG" -p debug "$1"
        echo "$(date '+%Y-%m-%d %H:%M:%S') [DEBUG] $1" >> "$BASE_DIR/log/backup.log"
    fi
}

# LED control functions
led_backup_start() {
    # Fast blink - backup in progress
    if [ -d "$LED_GREEN" ]; then
        echo "timer" > "$LED_GREEN/trigger" 2>/dev/null || true
        echo "100" > "$LED_GREEN/delay_on" 2>/dev/null || true
        echo "100" > "$LED_GREEN/delay_off" 2>/dev/null || true
        log_debug "LED set to fast blink"
    fi
}

led_backup_done() {
    # Solid on - backup complete
    if [ -d "$LED_GREEN" ]; then
        echo "none" > "$LED_GREEN/trigger" 2>/dev/null || true
        echo "1" > "$LED_GREEN/brightness" 2>/dev/null || true
        log_debug "LED set to solid on"

        # Auto-off after 30 seconds
        (
            sleep 30
            echo "0" > "$LED_GREEN/brightness" 2>/dev/null || true
        ) &
    fi
}

led_backup_error() {
    # Slow blink red - error occurred
    if [ -d "$LED_RED" ]; then
        echo "timer" > "$LED_RED/trigger" 2>/dev/null || true
        echo "500" > "$LED_RED/delay_on" 2>/dev/null || true
        echo "500" > "$LED_RED/delay_off" 2>/dev/null || true
        log_debug "LED set to error blink"

        # Auto-off after 60 seconds
        (
            sleep 60
            echo "none" > "$LED_RED/trigger" 2>/dev/null || true
            echo "0" > "$LED_RED/brightness" 2>/dev/null || true
        ) &
    fi
}

led_backup_stop() {
    # Turn off all LEDs
    if [ -d "$LED_GREEN" ]; then
        echo "none" > "$LED_GREEN/trigger" 2>/dev/null || true
        echo "0" > "$LED_GREEN/brightness" 2>/dev/null || true
    fi
    if [ -d "$LED_RED" ]; then
        echo "none" > "$LED_RED/trigger" 2>/dev/null || true
        echo "0" > "$LED_RED/brightness" 2>/dev/null || true
    fi
    log_debug "LEDs turned off"
}

# Check if path is safe (prevent directory traversal)
is_safe_path() {
    local path="$1"
    case "$path" in
        *../*|*/../*|*/..)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

# Get filesystem type of device
get_fs_type() {
    local device="$1"
    blkid -o value -s TYPE "$device" 2>/dev/null
}

# Check if device is mounted
is_mounted() {
    local device="$1"
    mount | grep -q "^$device "
}

# Get mount point of device
get_mount_point() {
    local device="$1"
    mount | grep "^$device " | awk '{print $3}'
}

# Calculate directory size in MB
get_dir_size_mb() {
    local dir="$1"
    if [ -d "$dir" ]; then
        du -sm "$dir" 2>/dev/null | awk '{print $1}'
    else
        echo "0"
    fi
}

# Check available space in MB
get_available_space_mb() {
    local path="$1"
    df -m "$path" 2>/dev/null | awk 'NR==2 {print $4}'
}

# Create backup report
generate_report() {
    local sd_uuid="$1"
    local sd_name="$2"
    local backup_dir="$3"
    local duration="$4"

    local size_mb=$(get_dir_size_mb "$backup_dir")
    local report_file="$BACKUP_ROOT/.logs/report_${sd_uuid}_$(date +%Y%m%d).txt"

    cat >> "$report_file" << EOF
=====================================
SD Card Backup Report
=====================================
Date: $(date '+%Y-%m-%d %H:%M:%S')
SD Card: $sd_name
UUID: $sd_uuid
Backup Size: ${size_mb} MB
Duration: ${duration} seconds
Speed: $((size_mb / duration)) MB/s
Location: $backup_dir
=====================================

EOF
}
```

## 5. 安装脚本

### 文件: `/opt/outdoor-backup/install.sh`

```bash
#!/bin/sh
#
# Installation script for OpenWrt SD Card Backup System
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Installing OpenWrt SD Card Backup System..."

# Check if running as root
if [ "$(id -u)" != "0" ]; then
    echo "Error: This script must be run as root"
    exit 1
fi

# Check OpenWrt
if [ ! -f "/etc/openwrt_release" ]; then
    echo "Warning: This doesn't appear to be an OpenWrt system"
    read -p "Continue anyway? (y/n) " -n 1 -r
    echo
    if [ "$REPLY" != "y" ]; then
        exit 1
    fi
fi

# Install required packages
echo "Installing required packages..."
opkg update || true
opkg install block-mount kmod-usb-storage rsync || true
opkg install kmod-fs-ext4 kmod-fs-exfat kmod-fs-ntfs3 || true

# Create directory structure
echo "Creating directory structure..."
mkdir -p "$SCRIPT_DIR/var/lock"
mkdir -p "$SCRIPT_DIR/var/status"
mkdir -p "$SCRIPT_DIR/log"

# Set permissions
echo "Setting permissions..."
chmod 755 "$SCRIPT_DIR/scripts/"*.sh
chmod 755 "$SCRIPT_DIR/bin/"* 2>/dev/null || true

# Install hotplug script
echo "Installing hotplug script..."
cp "$SCRIPT_DIR/scripts/90-outdoor-backup.hotplug" "/etc/hotplug.d/block/90-outdoor-backup"
chmod 755 "/etc/hotplug.d/block/90-outdoor-backup"

# Create default config
echo "Creating default configuration..."
cat > "$SCRIPT_DIR/conf/backup.conf" << EOF
# OpenWrt SD Card Backup Configuration

# Backup root directory
BACKUP_ROOT="/mnt/ssd/SDMirrors"

# Mount point for SD cards
MOUNT_POINT="/mnt/sdcard"

# Enable debug logging (0=off, 1=on)
DEBUG=0

# Maximum concurrent backups
MAX_CONCURRENT=1

# LED paths (adjust for your hardware)
LED_GREEN="/sys/class/leds/green:lan"
LED_RED="/sys/class/leds/red:sys"
EOF

# Test LED access
echo "Testing LED access..."
if [ -d "/sys/class/leds/green:lan" ]; then
    echo "Green LED found"
else
    echo "Warning: Green LED not found at expected path"
fi

if [ -d "/sys/class/leds/red:sys" ]; then
    echo "Red LED found"
else
    echo "Warning: Red LED not found at expected path"
fi

# Create uninstall script
cat > "$SCRIPT_DIR/uninstall.sh" << 'EOF'
#!/bin/sh
echo "Uninstalling OpenWrt SD Card Backup System..."
rm -f /etc/hotplug.d/block/90-outdoor-backup
echo "Hotplug script removed"
echo "Note: Backup data in /mnt/ssd/SDMirrors/ was not removed"
echo "Uninstall complete"
EOF
chmod 755 "$SCRIPT_DIR/uninstall.sh"

echo
echo "=================================="
echo "Installation completed!"
echo "=================================="
echo
echo "The system will automatically backup SD cards when inserted."
echo "Backup location: /mnt/ssd/SDMirrors/"
echo "Logs: $SCRIPT_DIR/log/"
echo
echo "To monitor backups:"
echo "  logread -f | grep outdoor-backup"
echo
echo "To uninstall:"
echo "  $SCRIPT_DIR/uninstall.sh"
echo

# Test with a quick LED blink
echo "Testing LED (3 second blink)..."
echo "timer" > /sys/class/leds/green:lan/trigger 2>/dev/null || true
echo "500" > /sys/class/leds/green:lan/delay_on 2>/dev/null || true
echo "500" > /sys/class/leds/green:lan/delay_off 2>/dev/null || true
sleep 3
echo "none" > /sys/class/leds/green:lan/trigger 2>/dev/null || true
echo "0" > /sys/class/leds/green:lan/brightness 2>/dev/null || true

echo "Setup complete!"
```

## 6. 配置文件模板

### 文件: `/opt/outdoor-backup/conf/backup.conf`

```bash
# OpenWrt SD Card Backup System Configuration
#
# This file contains global settings for the backup system.
# Per-SD card settings are stored on each SD card.

# === Storage Settings ===

# Root directory for all backups
# This should be on your SSD or fast storage
BACKUP_ROOT="/mnt/ssd/SDMirrors"

# Temporary mount point for SD cards
MOUNT_POINT="/mnt/sdcard"

# === Performance Settings ===

# Maximum concurrent backup operations
# Set to 1 for safety, increase if CPU/storage can handle it
MAX_CONCURRENT=1

# rsync bandwidth limit in KB/s (0 = unlimited)
BANDWIDTH_LIMIT=0

# rsync compression (yes/no)
# Enable for slow storage, disable for fast SSD
USE_COMPRESSION=no

# === Safety Settings ===

# Minimum free space required on target (MB)
MIN_FREE_SPACE=1024

# Maximum backup retries on failure
MAX_RETRIES=3

# Retry delay in seconds
RETRY_DELAY=10

# === Logging Settings ===

# Enable debug logging (0=off, 1=on)
DEBUG=0

# Log rotation size in KB
LOG_MAX_SIZE=10240

# Number of old logs to keep
LOG_ROTATE_COUNT=10

# === LED Settings ===
# Adjust these paths for your specific hardware

# Green LED for normal operations
LED_GREEN="/sys/class/leds/green:lan"

# Red LED for errors
LED_RED="/sys/class/leds/red:sys"

# LED blink rates (milliseconds)
LED_FAST_BLINK=100
LED_SLOW_BLINK=500

# === File Filters ===
# Files/directories to exclude from backup

EXCLUDE_PATTERNS="
.Trash*
.Spotlight*
.fseventsd
System Volume Information
\$RECYCLE.BIN
.DS_Store
Thumbs.db
*.tmp
*.TMP
~*
"

# === Advanced Settings ===

# rsync extra options
# Add custom rsync flags here
RSYNC_EXTRA_OPTS=""

# Pre-backup hook script (optional)
# Run custom commands before backup starts
PRE_BACKUP_HOOK=""

# Post-backup hook script (optional)
# Run custom commands after backup completes
POST_BACKUP_HOOK=""
```

这些组件实现提供了完整的OpenWrt SD卡自动备份系统，包含了所有核心功能和安全机制。