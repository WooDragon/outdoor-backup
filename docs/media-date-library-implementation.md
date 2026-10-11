# 媒体日期库：本地实现与接口

> 状态：主体本地实现与定向验证已闭合。首轮 F1–F8、R1（CI Lua）修订已闭合，有限范围实现复核及新增 fixture/RPC bootstrap 复核均为 APPROVED。修后未重新执行全量；不能发布。本文不是部署批准。
> 读者：维护 OpenWrt shell、Perl 和 Lua LuCI 接口的开发者。synthetic 指人工构造的隔离素材或存储夹具，不是真实原卡验收。

**前置阅读**：产品不变量、日期规则和 G1–G6 门槛在 [media-date-library-design.md](media-date-library-design.md)。变更产品合同前应先读取该设计。执行设备命令前应先读取 [media-date-library-operations.md](media-date-library-operations.md)。历史设计与本地实现评审状态在 [media-date-library-review.md](media-date-library-review.md)。本文只记录现行实现，不复制设计取舍。

## 1. 配置合同

`config.sh` 仍按 defaults < root 管理的 legacy `backup.conf` < 显式 UCI option 加载配置。UCI section 为 `outdoor-backup.config`。CBI 保存和 API 调用不会改变正在执行的 manager 配置快照。

| UCI option | 现行含义与边界 |
|---|---|
| `backup_layout` | `mirror` 为默认；`date` 需显式选择。非法枚举拒绝。 |
| `backup_root` | 镜像根；保持目标挂载点严格子目录的既有合同，不作为日期媒体根。 |
| `library_root` | 日期根；date 模式要求它是 `target_mount` 的直接子目录，与镜像根、来源挂载点互不包含且不相等。date 未填时派生 `target_mount/MediaLibrary`。mirror 未配置此值时保持空 intent，不凭显示默认值制造与现有镜像根的冲突。显式非空值仍检查隔离。 |
| `archive_offset_minutes` | 新库要求显式规范整数，范围为 `-840..840`。既有库读取固定 policy；显式不同 offset 拒绝，不在线改策略，也不跟随 TZ、旅行时区或 DST。 |
| `target_mount` / `target_uuid` | 已挂载目标的路径与实际 UUID；不猜盘，不格式化，不挂载，不修改 fstab。 |

CBI 的能力检查加载真实 helper schema 和模块，而非只检查文件存在。运行时还会检查工具和目标能力；配置页通过不等于任务准入通过。目标选择器仍只派生 mount、UUID 与镜像根，不迁移日期库。

## 2. manager 的公开动作

动作的第一个参数是 action；以下形状省略脚本路径。设备名不含 `/dev/`，DEVPATH 为该分区的规范 `/devices/.../<DEVNAME>` 路径。

| 形状 | 行为 |
|---|---|
| `add DEVNAME DEVPATH [SEQNUM]` | 保留三参数 legacy 和四参数事件兼容。自动任务使用 quick。hotplug 始终提供第四槽位；空或非法 SEQNUM 不变成 legacy 调用。 |
| `remove DEVNAME DEVPATH [SEQNUM]` | 保留三参数 no-op；四参数按事件顺序和现行 owner 证据请求一次 TERM。 |
| `manual DEVNAME DEVPATH quick\|checksum` | root CLI；比较只属于本次任务。mirror 仅接受 quick；checksum 仅 date。没有 WebUI trigger、后台队列或 UUID-only 手动入口。 |
| `initialize DEVNAME DEVPATH` | root CLI；仅在正式配置缺席时发布新的 PRIMARY 配置，恢复只读后退出。不执行媒体备份，不更新 alias 或 identity，不覆盖已配置卡。既有非法配置、非普通对象和 REPLICA 仍拒绝。 |
| `cleanup-preview BACKUP_ROOT` | 受管镜像清理预览；根必须精确等于当前有效镜像配置。 |
| `cleanup BACKUP_ROOT 0\|1` | 同一受管清理后端；0 清空 alias 映射，1 保留。日期状态拒绝边界不因当前模式改变而消失。 |

manual 与 initialize 复用 service admission、锁、来源 snapshot、挂载和取消守卫，不是绕过 enabled 或 stopped 的特权入口。date 自动或 manual 任务在只读挂载后发现没有 `FieldBackup.conf` 时，以 `source_not_initialized` 失败，不进入 RW 初始化。mirror 首次配置保持原行为。initialize 的成功不表示卡已备份或已与库绑定。

## 3. 实现职责与源码导航

| 被验证接口 | 源码权威 | 职责 |
|---|---|---|
| 配置与布局隔离 | [`config.sh`](../files/opt/outdoor-backup/scripts/config.sh)、[`library-layout.sh`](../files/opt/outdoor-backup/scripts/library-layout.sh) | 保留 mirror 默认与空 intent；检查根和磁盘日期状态。 |
| manager 动作与终态 | [`backup-manager.sh`](../files/opt/outdoor-backup/scripts/backup-manager.sh)、[`manager-admin.sh`](../files/opt/outdoor-backup/scripts/manager-admin.sh)、[`manager-date.sh`](../files/opt/outdoor-backup/scripts/manager-date.sh) | 冻结任务比较模式；管理 planning、transferring、finalizing 和成功边界。 |
| 日期准入与规划调用 | [`media-date.sh`](../files/opt/outdoor-backup/scripts/media-date.sh) | 只在既有 owner/lease 和 FD 9 下调用同步 runner；保留 sticky cancel。 |
| 发布与恢复状态 | [`media-date-publication.sh`](../files/opt/outdoor-backup/scripts/media-date-publication.sh) | 验证、同文件系统候选、sync、rename、sync；首份空 routes 先于 identity claim。 |
| 目标能力与结果核对 | [`media-date-tools.sh`](../files/opt/outdoor-backup/scripts/media-date-tools.sh) | 仅 ext4/f2fs；实际探测 case/Unicode 区分及 rename；核对受控 view、计数与历史路由。 |
| 元数据与规划 helper | [`media-date-plan.pl`](../files/opt/outdoor-backup/scripts/media-date-plan.pl)、[`MediaDate/`](../files/opt/outdoor-backup/lib/OutdoorBackup/MediaDate/) | 固定 argv/schema；只产私有规划结果，不复制媒体或写共享状态。 |
| 实际传输 | [`backup-transfer.sh`](../files/opt/outdoor-backup/scripts/backup-transfer.sh)、[`transfer-process.sh`](../files/opt/outdoor-backup/scripts/transfer-process.sh) | 一次 `-aL` rsync；沿用已有进程组取消和 drain，不新增 PID 管理。 |
| 镜像清理 | [`manager-cleanup.sh`](../files/opt/outdoor-backup/scripts/manager-cleanup.sh)、[`cleanup-all.sh`](../files/opt/outdoor-backup/scripts/cleanup-all.sh) | manager 后端统一租约、owner、target-only FD 9、全祖先与全树预检。 |
| LuCI 表单、API 与任务显示 | [WEBUI_DEVELOPER_GUIDE.md](WEBUI_DEVELOPER_GUIDE.md) | 该文档是 HTTP、授权、表单与 task schema 的权威说明。 |
| 可选包 | [BUILD.md](../BUILD.md) | 该文档是 recipe、安装文件及 provider 验证边界的权威说明。 |

九个 Perl 模块按职责分为 JSON、Path、Scan、Extractor、Date、Groups、Routes、Namespace 和 Planner。维护者应在对应模块修改规则，不将源码复制到文档作为第二份算法。

## 4. 路由、身份和日期能力

库标记固定在 `.outdoor-backup/library.json`，每来源位置快照固定在 `.outdoor-backup/routes/<SD_UUID>.json`。身份仍由 `.card-identities/<SD_UUID>.json` 绑定。routes 只表示预留位置，不表示传输完成或文件完整。新来源先验证命名空间为空，再发布完整 schema 的空 routes，最后调用原 identity claim。身份存在但 routes 缺失、空 routes 却存在正式/partial/replaced 命名空间、非法 JSON 或版本不一致均拒绝写入。

规划器把当前候选与全部保留路由共同检查。历史普通文件与新目录前缀冲突、未登记目标、槽位 recording identity 改变和晚到旁车需改变固定 bucket 时，规划器在传输前阻断。首版不自动迁移、重分类、重绑或猜回路由。当前卡仅有新旁车而主素材只在历史 route 时，helper 不历史猜配，并报告 `primary_not_present`。

现行 `Extractor.pm` 使用 Image::ExifTool API 的 fast 白名单，不使用 fast2、ee 或完整 dump。EXIF 照片字段按当地时间规则解释；Sony XML 只使用有 offset 的 profile。源码没有启用 Sony QuickTime UTC fallback。DJI UTC profile 限于精确 Encoder `DJI OsmoAction5 Pro`；未知型号不能外推该语义。无可靠日期的普通文件保留到 Undated。原卡 Sony 照片、视频/外 XML 配对与当前 DJI 设备仍待 G1 验收。

公开错误只接受固定 schema 和受控枚举。任意 stderr、GPS、序列号、原始 UMID 和完整 XML 不写入共享状态。原始 UMID 只在私有提取内存中参与配对；持久 identity 使用摘要，不是媒体内容 hash。

## 5. 比较、空间与恢复限制

date profile 使用 `-aL --partial-dir=.rsync-partial --backup --backup-dir=<本任务受管目录>`。自动任务默认 quick；同 size/mtime 的内容变化可能跳过。仅 mtime 改变时，quick 可能重传并保留同内容 old file。显式 checksum 只比较当前 source 对应 target，不覆盖卡上已不存在的历史媒体。

实现没有默认 checksum、内容 hash 缓存、第二复制器、自动清理 replaced/partial 或自动消费者。卡上删除不传播到库。路由先于传输发布；传输失败后保留路由与可恢复数据。重跑不以 routes 省略当前接受文件。默认本地 whole-file 不承诺复用已经传输的字节。

manager 复用原 owner、FD 8 lease、FD 9 anchor 和 runner/drain。所有 reader/writer 退出后才释放私有 view、来源挂载和锁。仅 rsync 返回 0 不足以 completed；sync、摘要、目标健康/身份复验和终态发布仍需成功。原子 rename 和 sync 返回值不是断电持久性证明。管理员不应在活动任务中手工改名受管路径或并发替换挂载；shell 守卫不等价于 openat2。

## 6. 验收证据的边界

下列状态来自既有 evidence 及已定稿的有限范围评审，不是本次文档任务重新执行的测试结论。主体本地实现与定向验证已闭合；修后未重新执行全量，不能称为 release passed。评审轮次应先读取 [评审记录第 7 节](media-date-library-review.md#7-本地实现修订闭合与有限范围复核)。本节是本次验证数字与证据边界的单一事实源。

### 6.1 唯一收尾全量与分层计数

唯一收尾全量证据为 `/private/tmp/outdoor-media-final.FOgEFl/`。原 collector 的 `summary.json`、`summary.md` 及各 suite 原始输出保持不变。41 个 shell suite 全部尝试，原分类为 36 pass、4 fail、1 blocked、0 未执行。fail 为 card-identity、card-reader、target-anchor 和 luci-media-date；library 因 guest 包元数据准备失败而 blocked。后续定向通过不回写这一历史分类，也不构成最终版本全量全绿。

下表只记录原全量实际输出。case、scenario、TAP、Python test 和嵌套 CBI 是不同层；不相加成总覆盖。collector 的 unknown 不应凭 rc0 猜成计数。

| 原全量 suite（根目录 `test-*.sh`） | 实际 case / assertion 或分层结果 | 原结果 |
|---|---|---|
| backup-core | 13 / 143 | pass |
| backup-progress | 10 / 31 | pass |
| card-config | 12 / 74 | pass |
| card-identity | 进入 1 case，0 个完整完成；fixture 内中断，0 assertion | fail，rc2 |
| card-reader | 0 case / 0 assertion，jq 补齐前下载失败 | fail，rc1 |
| cleanup | 38 scenario / 340 assertion；原 collector 未识别，补录原输出计数 | pass |
| config | 21 / 109 | pass |
| feed-layout | 7 / 22 | pass |
| hotplug-service | 4 / 26 | pass |
| led-lifecycle | 8 / 91 | pass |
| led | 14 / 153 | pass |
| live-progress | 4 / 51 | pass |
| lock | 13 / 45 | pass |
| luci-acl | 6 / 15 | pass |
| luci-media-date | 0 case / 0 assertion，顶层 luci.util 缺失 | fail，rc1 |
| luci-target-config | 8 / 28 | pass |
| luci-target-fd | 3 / 8；child 细分不叠加 | pass |
| luci-target-selection | 19 / 137 | pass |
| manager-cancellation | 8 / 96 | pass |
| manager-removal | 8 / 130 | pass |
| manager-service | 9 / 215 | pass |
| manager-source-identity | 15 / 289 | pass |
| media-date-helper | semantic 84 TAP；UUID 4 TAP；Python integration 21 tests，各层绿 | pass |
| media-date-library | 0 case / 0 assertion，metadata 下载前置阻断 | blocked，rc1 |
| media-date-lifecycle | 50 / 303，50 passed，0 failed，0 blocked | pass |
| media-date-manager | 30 / 78，30 passed，0 failed，0 blocked | pass |
| media-date-package | 9 recipe fixture tests；SDK/IPK/G3 未执行 | pass（仅 fixture） |
| media-date-regressions | 32 outer + 7 nested CBI，各层绿；不是 39 独立场景 | pass |
| media-date-transfer | 14 / 333，14 passed，0 failed，0 blocked | pass |
| owner-event | 15 / 162 | pass |
| service-control | 16 / 123 | pass |
| service-lifecycle | 12 / 73 | pass |
| service-state | 11 / 153 | pass |
| source-identity | 9 / 51 | pass |
| status | 9 / 47 | pass |
| storage-lifecycle | 4 / 19 | pass |
| target-anchor | 进入 13 case，前 12 个完整返回；T10b 中断，无终态 assertion 汇总 | fail，rc2 |
| target-device | 15 / 78 | pass |
| target-list | 11 / 25 | pass |
| target-manager | 43 / 409 | pass |
| transfer-process | 8 / 40 | pass |

同一证据根的三个 host JS suite 均 rc0：live-progress-ui 为 4 case / 22 assertion，target-selection-ui 为 5 case，status-modal 为 3 case / 72 assertion。runner 单测为 18 tests、OK、rc0。它们不与 shell suite 相加。此前局部 case、TAP 和实际 rsync 证据仍有效，但各轮结果不累计为总覆盖。

### 6.2 后续定向闭合与执行偏差

后续定向证据根为 `/private/tmp/outdoor-media-targeted.fToHc3/`。

| 实际入口 | 证据子目录 | 实际结果 |
|---|---|---|
| `test-card-identity.sh` | `test-card-identity.sh/` | 6 case / 70 assertion，rc0 |
| `test-target-anchor.sh` | `test-target-anchor/` | 16 case / 98 assertion，rc0 |
| `test-card-reader.sh` | `test-card-reader/` | 5 case / 17 assertion，rc0 |
| `test-media-date-library.sh` | `test-media-date-library/` | 74 case / 273 assertion，74 passed、0 failed，rc0；另 2 验收 blocked：OpenWrt toolchain 与 ext4/f2fs target；synthetic only |
| `test-luci-media-date.sh` | `test-luci-media-date/` | 前 14 scenario 已 PASS 后因 ubus 缺席而 rc1；不是这轮已通过 |

worker 首次把 `test-card-identity`（缺 `.sh`）传给入口，得到 rc64、0 行为 case。证据为 `test-card-identity/`。随后正确 `.sh` 入口执行一次并通过。这是独立执行偏差，不是行为 RED，也不与正确执行累加。

LuCI 后续证据根为 `/private/tmp/outdoor-luci-bootstrap.fUbP24/`：`red/` 因真实 RPC 缺席失败；`green/` 虽已有 owned ubusd/rpcd，仍因缺少 UCI Lua binding 失败，目录名 green 不等于通过；`final/` 为实际 Lua 82 case / 397 assertion 和 UI 9 case / 42 assertion，两层各自通过，suite rc0。final stderr 留有准备阶段的 ubus 连接诊断，不应隐藏；ready 记录、实际授权场景及终态 rc0 共同界定本次结果。

本次已定稿的新增复核只覆盖 [`test-card-identity.sh`](../test-card-identity.sh)、[`test-target-anchor.sh`](../test-target-anchor.sh)、[`test-luci-media-date.sh`](../test-luci-media-date.sh) 和 [`tests/ci-suite.sh`](../tests/ci-suite.sh)。fixture 修订不改生产权限语义。测试用 root daemon 只管理自己启动的 PID 和 socket；CI 准备真实 luci-compat、ubusd、ubus、rpcd、libuci-lua。权限通过真实 RPC session/access 验证，不以 mock 授权代替。该有限范围 APPROVED 不扩大为整个最终工作树或浏览器验收。

### 6.3 证据核对矩阵（既有执行，非本次重跑）

| 被验证物路径 | 已执行命令的权威记录 | 证据交付路径 |
|---|---|---|
| 根 shell suite 与 `tests/run-ci.sh` | 原全量 `summary.json` 的 `root_list.command`、各 `shell_suites[].command_text`；同根 `*.command.txt` 保存逐条命令 | `/private/tmp/outdoor-media-final.FOgEFl/` 的 rootlist、每 suite 的 stdout/stderr/rc 与 runner 输出 |
| `test-live-progress-ui.js`、`test-target-selection-ui.js`、`test-status-modal.js` | 原全量 `summary.md` 的 host JS 命令表 | 同根对应 `*.stdout`、`*.stderr`、`*.rc` |
| `tests/test-run-local-container.py` | 原全量 `summary.md` 的 runner 单测命令 | 同根 `test-run-local-container.*` |
| identity、anchor、card-reader、library 与 LuCI 定向入口 | 各证据子目录保存 `suite.stdout`、`suite.stderr`、`suite.rc`；未发现完整命令存档，不据目录名重建命令参数 | `/private/tmp/outdoor-media-targeted.fToHc3/` |
| LuCI 的真实 RPC/CBI/XHR/DOM 合同 | 各轮保存 `suite.stdout`、`suite.stderr`、`suite.rc`；完整命令未单独存档，源码入口只作导航 | `/private/tmp/outdoor-luci-bootstrap.fUbP24/{red,green,final}/` |

以上 `/tmp` 证据来自隔离 synthetic 测试，不是私人素材路径。证据包含 guest/module/provider 的边界；不应把名含 final 的旧文件自动视为修后全量验收。

本会话生成的日志及 guest/rsync 输出现已移至 `/private/tmp/outdoor-media-archive.6z8qt7nr/`。归档保留每项原有相对路径。`/private/tmp/outdoor-media-archive.6z8qt7nr/manifest.json` 记录逐路径映射和 `lstat` 信息。本次未删除数据。

`tests/media-date/package-module-probe/suite.stderr` 因 `tests/media-date/package-target-proof.json` 的历史引用而保留在仓库。源码、branch map、模块配方、target proof 和 scenario fixture 均保留。`tags` 与未分类文件未改动。

该归档不代表新的测试执行或通过记录。旧证据目录名中的 `final` 不表示修后全量已执行或通过。

### 6.4 G1–G6 未完成门槛

| 门槛 | 当前已有证据 | 未完成或 blocked 范围 |
|---|---|---|
| G1 原卡素材 | synthetic 日期、配对和冲突 fixture | 未改名的真实 Sony/DJI/XML 原卡脱敏 fixture 缺席；人工名字不是 raw fixture。 |
| G2 分支与回归 | 本地 implementation、synthetic、组件合同有证据；本次全量非通过项已定向闭合；有限范围评审 APPROVED | 未重跑修后全量；不是 release passed。 |
| G3 工具与包 | native OpenWrt rsync 3.5.1 / protocol 33；verified ExifTool 13.59 source moduleload | 目标 R5S rsync 3.4.1、真实 provider IPK/SDK、真 ext4/f2fs 验收仍 blocked；源码加载不等于 IPK 安装。 |
| G4 故障 | tmpfs ENOSPC、实际进程组 cancel/drain 部分通过 | 真介质拔盘、掉电与目标设备故障未验。 |
| G5 资源与性能 | M49 是合同证据，不是性能证明 | 真大视频 RSS、IO split、规划成本与峰值空间未验；无目标性能结论。 |
| G6 LuCI | real RPC/CBI/XHR/DOM 部分通过，真实权限不 mock | browser/full CGI auth 及真机未验；PhotoPrism 自动 index 不在本次验收。 |

- 未完成的 G1–G6 验收统一跟踪 [Issue #59](https://github.com/WooDragon/outdoor-backup/issues/59)，实现合并或固件编译成功不自动关闭验收。

源码与 suite 导航为 [`tests/media-date/`](../tests/media-date/)、[`test-media-date-regressions.sh`](../test-media-date-regressions.sh)、[`test-media-date-manager.sh`](../test-media-date-manager.sh)、[`test-media-date-library.sh`](../test-media-date-library.sh)、[`test-media-date-lifecycle.sh`](../test-media-date-lifecycle.sh) 和 [`test-luci-media-date.sh`](../test-luci-media-date.sh)。本次文档任务只做文档编辑与静态核查，没有执行行为套件、网络、固件、部署或发布。

### 6.5 实际交付文件

以下索引依据当前实际 tracked diff 与未跟踪源码核对。列入索引不表示所有差异都由本次生成。根目录 `README.md`、`CLAUDE.md` 及 `docs/` 下的设计文档和评审文档含有既有内容。生成日志与 `tags` 不列为功能源码。

| 类别 | 公共路径前缀 | 文件名 |
|---|---|---|
| 运行时脚本 | `files/opt/outdoor-backup/scripts/` | `backup-manager.sh`<br>`backup-transfer.sh`<br>`cleanup-all.sh`<br>`config.sh`<br>`owner-event.sh`<br>`status.sh`<br>`target.sh`<br>`library-layout.sh`<br>`manager-admin.sh`<br>`manager-cleanup.sh`<br>`manager-date.sh`<br>`media-date-plan.pl`<br>`media-date-publication.sh`<br>`media-date-tools.sh`<br>`media-date.sh` |
| MediaDate 模块 | `files/opt/outdoor-backup/lib/OutdoorBackup/MediaDate/` | `Date.pm`<br>`Extractor.pm`<br>`Groups.pm`<br>`JSON.pm`<br>`Namespace.pm`<br>`Path.pm`<br>`Planner.pm`<br>`Routes.pm`<br>`Scan.pm` |
| 配置文件 | — | `files/etc/config/outdoor-backup`<br>`files/opt/outdoor-backup/conf/backup.conf` |
| 包 recipe | `outdoor-backup/` | `Makefile` |
| LuCI 包 recipe | `luci-app-outdoor-backup/` | `Makefile` |
| CI workflow | `.github/workflows/` | `build-and-release.yml` |
| CI 测试入口 | `tests/` | `ci-suite.sh`<br>`run-ci.sh` |
| LuCI 实现 | `luci-app-outdoor-backup/` | `luasrc/controller/outdoor-backup.lua`<br>`luasrc/model/cbi/outdoor-backup/config.lua`<br>`luasrc/model/outdoor-backup/media.lua`<br>`luasrc/model/outdoor-backup/security.lua`<br>`luasrc/view/outdoor-backup/log.htm`<br>`luasrc/view/outdoor-backup/status.htm`<br>`root/usr/share/rpcd/acl.d/outdoor-backup.json` |
| 根目录测试 | `./` | `test-card-identity.sh`<br>`test-cleanup.sh`<br>`test-feed-layout.sh`<br>`test-luci-media-date.sh`<br>`test-luci-target-config.sh`<br>`test-luci-target-selection.sh`<br>`test-media-date-helper.sh`<br>`test-media-date-library.sh`<br>`test-media-date-lifecycle.sh`<br>`test-media-date-manager.sh`<br>`test-media-date-package.sh`<br>`test-media-date-regressions.sh`<br>`test-media-date-transfer.sh`<br>`test-status-modal.js`<br>`test-target-anchor.sh`<br>`test-target-manager.sh` |
| 共享测试 fixture | `tests/` | `luci-target-fixture.lua` |
| 媒体日期测试 | `tests/media-date/` | `library-helper.pl`<br>`library-scenarios.py`<br>`lifecycle-reader.sh`<br>`lifecycle-scenarios.py`<br>`luci-contracts.lua`<br>`luci-ui.js`<br>`manager-contracts.py`<br>`package-contracts.py`<br>`package-helper-runner.py`<br>`regressions-cbi.lua`<br>`regressions-scenarios.py`<br>`rsync-observe.sh`<br>`rsync-run.sh`<br>`rsync-scenarios.py`<br>`run-suite.py`<br>`scenarios.py`<br>`semantic-scenarios.pl`<br>`transfer-contracts.py`<br>`uuid-scenarios.pl` |
| fixture 与 proof | `tests/media-date/` | `branch-map.json`<br>`fixtures/sony.xml`<br>`package-perlbase.mk`<br>`package-perlver.mk`<br>`package-target-proof.json`<br>`manager-lifecycle-scenarios.json`<br>`transfer-acceptance-scenarios.json` |
| 根目录文档 | `./` | `BUILD.md`<br>`CLAUDE.md`<br>`README.md` |
| docs 文档 | `docs/` | `WEBUI_DEVELOPER_GUIDE.md`<br>`WEBUI_USER_GUIDE.md`<br>`component-implementation.md`<br>`media-date-library-design.md`<br>`media-date-library-implementation.md`<br>`media-date-library-operations.md`<br>`media-date-library-review.md` |

`package-perlbase.mk` 与 `package-perlver.mk` 是原始上游 recipe 快照。`package-target-proof.json` 是 target proof。这些文件属于 fixture/proof，不是 SDK 构建产物。

本地实现交付时，工作区尚未提交或推送，未创建 Issue/PR，未修改 mCPE provider 或 feed pin，未触发固件构建、真盘操作或部署。后续 PR、CI 与固件进度以 Issue #59 的记录为准；本地历史测试结果不随这些动作改写。
