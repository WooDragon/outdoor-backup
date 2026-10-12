# 媒体日期库：设计评审记录

> 状态：默认关闭 checksum 的增量设计复核 APPROVED；首轮五项 MUST FIX 的设计闭环保留。
> 日期：2026-10-10。
> 历史适用范围：本记录中的裁决、r1/r2 修订过程和测试结论保持原样。2026-10-12 的 [Issue #65](https://github.com/WooDragon/outdoor-backup/issues/65) 替代了旧的新库显式 offset、Warning 一律否决字段、静态默认 mirror 根及裸文本日期摘要决定。当前合同应先读取 [现行实现](media-date-library-implementation.md#1-配置合同) 与 [WebUI 合同](WEBUI_DEVELOPER_GUIDE.md#日期任务与状态合同)。历史 APPROVED 不构成本次改动的评审或验收结论。
> 本记录保留设计审批历史，并追加本地实现的有限范围评审结论。主体本地实现与定向验证已闭合；修后未重跑全量，不能发布。本记录不是部署批准。

**前置阅读**：方案及 BDD 分支的权威版本在 [media-date-library-design.md](media-date-library-design.md)。实现或评估这项功能前应先读取该设计；本记录不重复定义运行时合同。

## 1. 评审范围与证据

首轮 Red Team 审阅了新设计全文，以及 README、项目 CLAUDE.md 的新增索引。源码基线为 `80f6f200f52fc226809f9125ae656d0e8d02e554`。评审者按需读取了来源身份、首次配置、目标守卫、传输、取消、状态和清理接口。

评审者还静态核对了 rsync 3.4.1 的手册及 generator、receiver、backup、delete 代码。评审者没有执行传输、清理或目标环境测试。未跟踪的新设计通过全文读取纳入评审，不把空的 git diff 当作已审阅。

用户要求的门槛是：鲁棒、优雅简洁、可维护；按拍摄日整理 Sony/DJI 素材；不保留镜像加日期副本两套相同媒体；实际复制、增量和校验仍由 rsync 执行。

所有判断均针对设计。以下 finding 不是已发布代码的 Bug 归档。

## 2. 首轮裁决

**NEEDS REVISION**。评审者认可“临时来源视图 + 一个实际传输 rsync”的方向。主会话采纳全部五项 MUST FIX，未以扩大非目标范围或增加数据库来规避问题。

| ID | 设计缺口及具体风险 | 已落文档的修订 | BDD 场景 | 复核状态 |
|---|---|---|---|---|
| MDL-001 | 日期 bucket 下的 UUID 可被旧 cleanup 当镜像目录删除；不同根仍可能互为祖先/后代 | 日期根限制为目标直接子目录；两模式拒绝包含关系；清理根须经过 target 准入，并在删除前检查全部候选及祖先的日期状态 | M32、M33、M41 | 设计闭环；实现未验收 |
| MDL-002 | 历史普通文件 A 被源目录 A/B 占用，rsync 可发生类型替换，即使未传 delete | 所有保留路由与候选共同检查文件/目录前缀及实际组件类型；旧正式位置不能靠 replaced 隐式改变 | M19、M42 | 设计闭环；实现未验收 |
| MDL-003 | 身份绑定已发布、首份 routes 尚未发布时中断，正常重跑和路由丢失不可区分 | 首次身份 claim 前发布完整 schema 的空路由；用身份、路由和来源目标命名空间的状态表区分新来源、中断及损坏 | M23–M25、M43、M44、M48 | 设计闭环；实现未验收 |
| MDL-004 | +09:00 和 UTC 表示同一瞬间，却因 +08:00 归档换算得到两个日期而误报冲突 | fallback 不否决 primary；可信 peer 先统一时间语义、精度及日期坐标，再判真实冲突 | M04、M05、M08、M46 | 设计闭环；实现未验收 |
| MDL-005 | 既有无配置卡初始化会重挂 RW 并写配置，违背日期自动任务只读 | 在任何 RW 初始化分支前拒绝日期任务的无配置卡；独立显式初始化与自动备份分离，镜像流程保持兼容 | M40、M45 | 设计闭环；实现未验收 |

两项建议也纳入修订：

- S-001：明确首版本地 rsync 保留 whole-file 默认。重跑可以恢复任务结果，但不承诺复用已传字节。
- S-002：新旁车的主素材只存在于历史 route 时，首版不历史猜配，按独立文件规则归档并报告 `primary_not_present`；对应 M47。

修订还澄清了消费者边界：本次 completed 只覆盖本轮接受文件，不能证明历史所有预留路由或旧失败素材组完整。首版没有自动全库索引触发器。

## 3. 限范围复核

复核使用同一 Red Team 上下文。范围只覆盖 MDL-001–005 的闭环、两项建议，以及修订直接引入的回归。复核不重新发现无变化领域的问题，也不代替目标环境验收。

**原设计复核 verdict：APPROVED。** 同一 Red Team 读取修订后完整正文，逐项关闭 MDL-001–005，并确认 S-001/S-002 已处理。复核没有报告新增 BLOCKER、MUST FIX、SUGGESTION 或修订回归。主会话采纳该定稿结论。

| 质量维度 | 复核结论 |
|---|---|
| 鲁棒性与数据安全 | PASS（设计） |
| 优雅与简洁 | PASS（设计） |
| 可维护性与接口一致性 | PASS（设计） |
| 可验证性与证据边界 | PASS（设计规格，不是测试执行结果） |

评审记录及其导航是在复核期间新增的文档元信息。复核者没有重新读取 README/CLAUDE.md；首轮被审阅的设计索引保持原文，新增评审记录索引由最终文档检查核对，不扩称已被 Red Team 逐字审阅。

原设计复核后，正文状态与本记录闭环表按裁决更新。那次元信息更新没有改变当时的运行时设计合同。后续实质性修订应单独复核。

## 4. 默认关闭 checksum 的增量修订

用户确认日常备份默认关闭 checksum。本次只修改设计与 BDD 规格，不修改运行时代码。

| 修订面 | 当前合同 |
|---|---|
| 默认比较 | quick check 使用 size + mtime，不传 checksum；同 size/mtime 的内容变化可能跳过 |
| 显式深度对比 | 管理员只为本次手动任务选择 checksum，范围为当前来源与对应目标，不覆盖历史全库 |
| 旧文件保留 | backup-dir 安全网保留；quick 下仅 mtime 改变可能留下同内容旧文件，明确作为空间例外，不自动删除 |
| 状态及成功语义 | 记录本次 comparison_mode；completed 不表示所有已有媒体已逐字核验 |
| 测试规格 | 修订 M16/M17；新增 M49/M50 覆盖默认成本、显式选择、非法值与下次恢复默认 |

**本次增量 verdict：APPROVED。** 同一 Red Team 读取两份当前文档，对默认比较、传输校验、旧文件保留、空间保证、单次选择、状态、性能及 BDD 做独立增量复核。复核没有新增 BLOCKER、MUST FIX 或建议。主会话采纳该定稿结论；它不是继承旧 APPROVED。

复核确认 quick 的同 size/mtime 失检边界、仅 mtime 更新可能保留同内容旧文件的空间例外，以及手动 checksum 不影响下一次自动默认值，均已明确写入合同。原 MDL-001–005 未重新打开。M16/M17/M49/M50 与 G3/G5 的规格对应本次变更；运行时测试执行数仍为 0。

## 5. 验证边界与后续门槛

本轮交付是设计文档及评审记录。BDD 表含 50 个设计场景；本轮执行数为 0，不计作测试通过。

真实原卡命名/配对 fixture、Sony 照片和当前 DJI 无人机素材、OpenWrt 包模块、实际 rsync 的 checksum/backup-dir/partial、故障注入与性能仍需取得。应按设计第 16 节 G1–G6 完成后续验收。

本轮没有修改运行时代码、feed pin 或固件。NAS 素材没有被写入、移动、改名或复制完整媒体。本轮没有安装系统开发工具，也没有提交、推送、发布或部署。

## 6. 本地实现首轮评审与修订状态

本节保留首轮实现评审时的历史快照，表内“待最终复核”等措辞不是当前状态。当前闭合结论在第 7 节，不改写以上历史设计闭环。主体已有本地实现及 synthetic、ARM guest 测试。首轮实现 Red Team 返回 **NEEDS REVISION**，共有八项 finding；设计 APPROVED 不适用于实现。

| ID | 首轮问题简述 | 本地修订状态 |
|---|---|---|
| F1 | mirror 无显式日期根时，派生的 MediaLibrary 默认值会与既有同名镜像根冲突，破坏 legacy/UCI 兼容。 | 保留空 library-root intent；显式重叠仍拒绝。已有定向证据，待最终复核。 |
| F2 | 日期库初始化依赖未声明的 uuidgen；目标 guest 缺少该命令时不能正常建立库 ID。 | 复用实际 UUID 生成及内核 fallback，并验证结果后发布。已有定向证据，待最终复核。 |
| F3 | helper CLI 的 UTF-8 路径在 argv 与文本/字节转换边界失真，可能错误读取命名空间或 JSON 路径。 | CLI 原始字节只解码一次；实际中文路径调用已有定向证据，待最终复核。 |
| F4 | helper 拒绝原因丢失为泛化失败；cleanup 后状态不能保留可判别业务错误。 | 固定 schema/错误枚举贯穿 manager，私有 stderr 不外泄。已有定向证据，待最终复核。 |
| F5 | 新 suite 未完整接入 CI guest 入口及真实模块准备路径，不能由本地组件结果推断 CI 可执行。 | 已有 CI 入口与模块准备定向测试；最终全量尚未执行。source provider 加载不计作 IPK 验收。 |
| F6 | strict library 测试把合法大写 UUID 当非法数据，oracle 与实际 UUID 合同不符。 | 已修订坏 oracle 并补大写 UUID round-trip 测试；待最终全量与复核。 |
| F7 | 既有回归 fixture 尚未与现行接口边界对齐，不能把部分执行结果汇总成全回归通过。 | 最后 fixture 仍在修订；首轮 finding 的完整定位需随最终评审 evidence 核对，不在此补造具体失败位置。 |
| F8 | manager 路径解析改变了 symlink fixture 的调用树，读到生产来源配置而非 fixture 配置，破坏既有隔离。 | 保持调用目录下的配置/库寻址；symlink 调用树已有定向证据，待最终复核。 |

F1–F4/F8 的定向输入与观测入口在 [`tests/media-date/regressions-scenarios.py`](../tests/media-date/regressions-scenarios.py)。F5 入口在 [`tests/ci-suite.sh`](../tests/ci-suite.sh)，F6 用例在 [`tests/media-date/scenarios.py`](../tests/media-date/scenarios.py)。这些位置是证据导航，不是八项 finding 已经关闭的裁决。本节没有重新执行测试，也不汇总 through/passed 数。

**首轮历史快照（已由第 7 节更新当前结论）**：当时为“修订验证进行中，复核未定稿”，最终复核与最终全量尚未执行。当时的测试数字留待下游 evidence 定稿后补录，不能写成“本地实现全部完成”“可发布”或实现 APPROVED。现行源码接口与 G1–G6 未验收项应先读取 [media-date-library-implementation.md](media-date-library-implementation.md)；root CLI 操作应先读取 [media-date-library-operations.md](media-date-library-operations.md)。

## 7. 本地实现修订闭合与有限范围复核

本节归档本地实现的后续定稿结论，不改写第 1–5 节的设计审批历史。结论来自本次收尾交付提供的既有评审结果；本次文档任务没有重新发起评审，也没有自行给出 verdict。

| 范围 | 后续结论 | 结论边界与导航 |
|---|---|---|
| 首轮实现 F1–F8 | 修复已闭合；有限范围复核 APPROVED | 包括配置兼容、UUID 生成、UTF-8 CLI、错误枚举、CI 接入、UUID oracle、回归 fixture 和 symlink 调用树。第 6 节是首轮快照，不是仍待修复清单。 |
| R1（CI Lua） | 修订已闭合；有限范围复核 APPROVED | CI Lua 依赖准备的闭合不等于 provider IPK、SDK 或整套最终 CI 通过。 |
| 新增 fixture / RPC bootstrap | 既有定稿复核 APPROVED | 只覆盖 `test-card-identity.sh`、`test-target-anchor.sh`、`test-luci-media-date.sh`、`tests/ci-suite.sh`；不扩大为整个最终工作树复核。 |

新增复核确认测试使用 root 启动自己拥有的 daemon，并只清理自己拥有的 PID 和 socket。CI 准备真实 luci-compat、ubusd、ubus、rpcd 和 libuci-lua。权限验证使用真实 RPC session/access，不以 mock 授权代替。fixture 的修订保留生产权限边界。

**当前状态：主体本地实现与定向验证已闭合，不能发布。** 唯一收尾全量保留原 fail/blocked 分类；后续定向闭合不回写原 collector。维护者没有重跑修后全量，不应称为最终版本全量全绿或 release passed。

核对 suite、各层计数、入口执行偏差及证据时，应先读取 [implementation 第 6 节](media-date-library-implementation.md#6-验收证据的边界)。核对未完成验收时，应先读取 [implementation 的 G1–G6 表](media-date-library-implementation.md#64-g1g6-未完成门槛)；设计第 16 节仍定义产品验收门槛。PhotoPrism 自动 index 不在本次验收。

本次收尾只校正文档和静态导航，没有执行行为套件、网络、Git 写操作、固件、发布或部署。
