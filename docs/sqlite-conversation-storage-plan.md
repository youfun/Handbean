# SQLite 会话主存储实施计划

## 1. 结论与范围

Handbean 直接把现有 `Handbean.Repo` 管理的本地 SQLite 数据库作为会话与运行持久事实的唯一主存储（打包宿主默认文件名为 `handbean.db`），不再把 `index.json`、`meta.json`、`messages.jsonl`、`files.json`、operation receipt JSONL、Session snapshot JSON 和 transcript recovery marker 作为运行时事实源。

这是一次受控的全量冷启动，不保留旧存储数据：

- 切换是部署前提，不是运行时兼容功能：先停止所有 Handbean 进程，确认没有进程持有数据库，再删除旧 Handbean Repo；旧库中的 memory、schedule、UI setting、error tracker 及其他业务记录一并丢弃。
- “数据库”指按当前环境实际配置解析出的精确文件，而不是一律硬编码 `handbean.db`；开发、测试、release、显式 `DATABASE_PATH` 和 mobile 的文件名可能不同。只处理该主库及同名 `-wal`、`-shm`、`-journal` companion，不删除目录、不用 glob。
- 删除后再次确认主库与 companions 均不存在，再运行正常 Ecto migrations 创建空库。若删除中断，保持应用停止并重新执行同一删除步骤即可；旧数据本就不要求恢复。
- 不增加 storage epoch、initializing/resetting marker、自动 reset、旧库识别或数据迁移代码。若旧库没有按步骤删除就启动新版本，属于不受支持的部署操作。
- 此计划编写阶段不会删除开发机数据库；实际删除只发生在后续实施切换时。
- 不扫描、不导入旧 conversation/session JSON/JSONL，不双写 SQLite 与 JSONL，也不保留“数据库没有就回退读旧文件”的兼容路径。旧 JSON/JSONL 文件不由普通启动自动删除；新版本只是不再读取它们。
- JSON/JSONL 后续只可作为显式导入导出格式，不再参与在线写入和恢复。

第一阶段不增加跨会话全文搜索。普通列表、分页、按 run 恢复直接使用关系索引；确有全文搜索需求时，再按 Pi 的做法把 `SessionSearch` 当作可组合查询能力：同库 FTS 可由事务/trigger 维护，独立索引必须可从主表重建，不能成为第二事实源。

## 2. 为什么这样定：外部项目的已验证经验

这里只采纳已合并实现、源码或可复现 issue 中能够支持的结论；用户报告而未确认根因的内容不当成定论。

| 来源 | 已验证事实 | Handbean 采用或规避 |
| --- | --- | --- |
| [Pi Fast Sessions #5804](https://github.com/earendil-works/pi/issues/5804) | JSONL 会话列表需要解析所有文件；搜索正文会拖慢 resume；压缩后仍重放旧路径；SQLite 还会把同步接口扩成异步持久化边界 | SQLite 直接提供元数据列表和有界分页；保留显式 store API，不让 UI 假定即时文件可见性 |
| [Pi SQLite session storage #6594](https://github.com/earendil-works/pi/pull/6594)（已合并） | schema 将共享 entry 字段列化、其余内容放 payload；独立 sequence 表达追加顺序；materialized 数据用于快速列表/恢复 | 消息采用“稳定 envelope 列 + payload”并保存每会话顺序；只把可重建数据称为 projection，不复制主状态 |
| [Pi search index #7163](https://github.com/earendil-works/pi/pull/7163)（已合并） | `SessionStore` 持有 canonical data；`SessionSearch` 只查询；同库 FTS 与独立可重建 FTS 的失败策略不同 | 首次切换不夹带 FTS；将来显式区分主表与派生索引，不做隐含的跨库“原子写” |
| [OpenCode SQLite PR #10597](https://github.com/anomalyco/opencode/pull/10597)（已合并） | 从 JSON 文件转向带版本 migration、约束、批量迁移和分页/批量查询；数据库操作完成后再发布事件 | 使用现有 Ecto migrations、FK/unique/check 约束、有界分页；提交成功后才 PubSub/通知 |
| [OpenCode migration #13654](https://github.com/anomalyco/opencode/issues/13654)（用户报告） | 用“DB 文件存在”充当数据迁移完成标记会漏掉增量升级用户 | 本计划不做增量数据迁移；部署前直接删除整个旧 Repo 并从空库建 schema，也不增加迁移完成 marker |
| [OpenCode NFS corruption #14970](https://github.com/anomalyco/opencode/issues/14970)、[Codex NFS stalls #49543](https://github.com/openai/codex/issues/49543) | SQLite 官方明确 WAL 不支持网络文件系统；`busy_timeout` 不能修复 NFS 上的 SHM/lock 问题，甚至不能约束卡在内核 unlock 的时间 | 数据库必须位于宿主声明的本机持久目录；不把 WAL DB 放 NFS/iCloud Drive/同步盘；不静默搬到 `/tmp` |
| [Goose lock #12473](https://github.com/aaif-goose/goose/issues/12473)（已接受并有关联 PR） | 缺少 `(session_id, message_id)` 复合索引使 compaction 在 `BEGIN IMMEDIATE` 内退化为二次复杂度，持写锁数分钟 | 所有运行查询先列清单并配复合索引；事务内禁止逐条 N+1；replace/bulk 操作分批 SQL，但保持一个短事务 |
| [Goose connection leak #7624](https://github.com/aaif-goose/goose/issues/7624)（已修复） | 连接泄漏和并发 writer 会造成 `SQLITE_BUSY`；重启才释放资源 | 只使用受监督的 `Handbean.Repo` pool，不按 session 自建连接；连接数与 busy policy 做并发测试 |
| [Goose WAL growth #12898](https://github.com/aaif-goose/goose/issues/12898)（开放用户报告） | 长生命周期、多会话并发时 WAL/checkpoint 需要观测；报告把故障归因于 checkpoint 尚未被维护者确认 | 记录 WAL 大小、checkpoint 结果和 DB 写延迟；做长时并发测试，不把默认 auto-checkpoint 当作无需验证 |
| [OpenCode SQLITE_FULL #52796](https://github.com/anomalyco/opencode/issues/52796)（开放、有关联 PR） | 外部工具已经执行后，结果持久化失败会造成内存状态和持久状态分叉；磁盘满不能当普通模型失败 | 工具副作用与 DB 事务明确分界；terminal write 失败不得在内存中先标 settled，也不得自动重放可能已发生的工具 |
| [Codex history corruption #52732](https://github.com/openai/codex/issues/52732)、[#35091](https://github.com/openai/codex/issues/35091)（开放用户报告） | 原因未定，但 SQLite 损坏会阻断列表/恢复；Codex 因仍有 canonical JSONL 才可重建派生 DB | Handbean 选择 SQLite canonical 后不能假装可从 JSONL 重建；必须有一致性检查、受支持的在线备份和不自动删除原库的故障路径 |
| [Codex Windows SHM restart #49605](https://github.com/openai/codex/issues/49605)（开放用户报告） | 前一个进程尚未完全释放 SHM 时启动替代进程可失败 | 保持一个数据库一个 runtime owner；宿主重启必须等待旧进程退出，初始化 busy/SHM 错误要可重试且可诊断 |

SQLite 官方约束也作为验收依据：[WAL 文档](https://www.sqlite.org/wal.html)说明同一时间只有一个 writer、长读事务会妨碍 checkpoint、WAL 不适用于网络文件系统；[Online Backup API](https://www.sqlite.org/backup.html)说明在线数据库不能靠普通文件复制获得一致备份。

### 2.1 这些 issue 对本方案是否适用

| 风险 | 判断 | 原因与处理 |
| --- | --- | --- |
| JSON→SQLite 漏迁移 | 不适用 | 部署前删除整个旧 Repo，旧 JSON/JSONL 也不导入；空库仅运行正常 Ecto schema migrations |
| JSONL 多 writer 分叉 | 切换后不适用 | 不再在线写 JSONL；转化为 SQLite 单 writer contention 与 runtime ownership 问题 |
| NFS + WAL/SHM | 条件适用且必须阻断 | 默认 desktop/mobile data dir 是本机；用户显式把 `DATABASE_PATH` 放到网络/同步挂载时会遇到，timeout 无法修复 |
| 缺索引导致长写锁 | 直接适用 | Handbean 有 run terminal、replace、recovery 等批量路径；必须复合索引 + bulk SQL + query-plan test |
| 连接泄漏/多 writer BUSY | 直接适用 | 新空库投入使用后，一个 Repo pool仍同时服务 transcript、schedule、memory、error tracker；禁止 session 自建连接，并测真实 pool |
| WAL 长期增长 | 条件适用 | 长生命周期、多 conversation streaming 与长 reader 可能触发；先 telemetry/load test，再决定 idle checkpoint |
| SQLITE_FULL 后内存/DB 分叉 | 直接适用 | 工具副作用发生在事务外；持久化失败必须保持 unknown，不能先 settled 或自动重放 |
| DB 损坏后无法重建 | 直接适用且影响更大 | 本方案没有 canonical JSONL 兜底，必须先具备 verified backup、health circuit breaker 和离线恢复流程 |
| 旧进程 SHM 未释放 | 条件适用 | desktop update/relaunch、Windows endpoint security 或宿主强杀可触发；整库单 owner 与启动顺序处理 |
| SQLite 实现工具 exactly-once | 不成立 | DB 只原子化内部记录，无法回滚 shell/network/OS side effect；继续使用 unknown + reconcile/idempotency 语义 |

## 3. Handbean 当前事实与切换风险

当前 owner 分散如下：

| 持久内容 | 当前 owner | 当前问题 | 新 owner |
| --- | --- | --- | --- |
| 会话 metadata/sidebar index | `ConversationStore` 的 `meta.json` + `index.json` | 两份数据需手工同步；错误时有重建语义 | `conversations` |
| transcript | `ConversationTranscriptStore.Journal` 的 `messages.jsonl` + `.pending` | 自建 txid、compaction、fsync、进程/OS 锁 | `conversation_entries` |
| editor projection | `files.json` | 与 metadata/transcript 不能同事务 | `conversation_editor_states` |
| run/delegated usage | `meta.json` 内嵌 map | read-modify-write 和重复派生 totals | `conversation_run_usage` |
| 请求幂等回执 | `operations-*.jsonl` | reserve、接受消息、入队分属不同提交 | `operation_receipts`，由聚合事务调用 |
| Session reconnect snapshot | `~/.handbean/sessions/<id>.json` | 整体重写；不是 transcript 事实 | `session_snapshots`（明确为可重建/可丢 projection） |
| orphan 候选 | 空 marker 文件 + 扫描 transcript | marker 与 transcript 分离 | 查询 `conversation_entries` 中 unfinished assistant/tool；可选最小 `conversation_runs` 只作 run header/orphan 索引 |
| 当前任务通知 | `Runtime.TaskTracker` 内存 map | 本来就是 UI/host projection，不应升级为第二事实源 | 继续由 Runner/Session lifecycle 产生 PubSub projection；重启后从 transcript unfinished 状态校准 |
| 审批等待 | Runner 的 `interrupted_state` + Session control event | 进程死亡后不能真正 resume | live Runner 仍是唯一可执行 continuation owner；审批请求保留在 Session control projection，不另建第二套审批事实表 |

最重要的语义边界：SQLite 事务只能覆盖数据库记录，不能把 shell、网络请求、系统 chooser 或 provider 调用纳入事务。运行时先提交“允许执行/准备执行”，提交后才调用外部能力；若进程在外部副作用之后、结果落库之前死亡，该 tool call 必须恢复为 `unknown`，不能自动重放。

## 4. 数据模型

新增一组 Ecto migration 和 schema。业务模块仍返回当前调用方需要的 string-key map，数据库 schema 不泄漏到 Web/native。

### 4.1 主表

1. `conversations`
   - `id`（text PK）、`scope`、`workspace_id`、`visibility`。
   - `parent_conversation_id`、`parent_run_id`、`parent_tool_call_id`。
   - `title`、`title_source`、`selected_model`、`selected_reasoning_level`、`collaboration`、`last_run_result`、`loaded_tools`。
   - `archived_at`、`pinned_at`、`created_at`、`updated_at`，内部采用 UTC microsecond，facade 返回 ISO8601 string。
   - `updated_at` 继续是 sidebar recency key：只在 user-authored append 或显式 `touch: true` metadata update 时移动；assistant/tool delta、usage、loaded tools、打开会话和 `touch: false` 都不得重排 sidebar。Ecto schema 不使用会在任意 update 自动触发的 timestamps 行为来破坏该契约。
   - `next_entry_sequence`，只由 store 在 append 事务内递增。
   - 约束 scope/visibility/title；`parent_conversation_id` 使用同表 FK 且 `on_delete: :restrict`，保持当前“不能留下失去父级的 internal delegated conversation”边界。若将来要级联清理，必须作为单独产品行为设计，不能在首版隐式删除子会话。

2. `conversation_entries`
   - 内部 integer PK；`conversation_id` FK、公开 `entry_id`、`sequence`、`revision`。
   - 可查询的稳定 envelope：`role`、`content_type`、`message_type`、`direction`、`phase`、`status`、`run_id`、`tool_call_id`、`tool_status`、`content`、`created_at`、`updated_at`。
   - 其余类型特有字段放 `payload`；payload 不重复上述列，map→公开 transcript entry 的组装只有一个 owner。
   - unique `(conversation_id, entry_id)`、unique `(conversation_id, sequence)`。
   - 索引至少覆盖 `(conversation_id, sequence)`、`(conversation_id, run_id, status)`、`(conversation_id, run_id, tool_status)`；是否使用 partial index 由 `EXPLAIN QUERY PLAN` 验证，而不是猜测。

3. `conversation_editor_states`
   - `conversation_id` PK/FK、`editor_files`、`active_file`、`file_preview_error`、timestamps。
   - 这是持久 UI state，不与 transcript payload 混放。

4. `conversation_run_usage`
   - `conversation_id`、非空 `run_id`、`source`（parent/delegated/unkeyed）、各 token 数、`usage_incomplete`。
   - unique `(conversation_id, source, run_id)` 使终态重复通知幂等；`add_token_usage/2` 用固定内部 key（如 `__unkeyed__`）执行原子累加，避免 SQLite unique index 对多个 NULL 不去重。
   - `record_run_usage/3`、`record_delegated_usage/3` 保持 put-once 语义；`rebuild_token_usage_from_events/2` 在一个事务中替换 parent usage。总计查询聚合，不再把 totals 与 per-run map 双重保存。

### 4.2 运行辅助表

5. 可选最小 `conversation_runs`
   - 只有在基准证明按 unfinished entry 查询不足以承担 startup recovery 时才增加。
   - 仅保存 `run_id` PK、`conversation_id` FK、`status`、`started_at`、`finished_at`，作为 run header/orphan 索引；不保存 tool、approval、完整 Agent State 或 UI control event。
   - 工具生命周期继续由 `conversation_entries` 中 `content_type = "tool"`、`run_id`、`tool_status` 表达；审批 continuation 继续由 live Runner 的 `interrupted_state` 独占。不得建立 `tool_calls`、`approval_requests` 影子状态表。
   - PID、Task ref、port、provider connection 永不持久化。

6. `operation_receipts`
   - `scope_kind`、`scope_id`、`request_id`、fingerprint、status、receipt、timestamps。
   - unique `(scope_kind, scope_id, request_id)`；reserve 用 insert-on-conflict + fingerprint 校验，不再依赖进程锁和整体文件重写。

7. `session_snapshots`
   - `conversation_id` PK、`seq`、`control_events`、`next_turn_messages`、`extension_state`、`model`、`updated_at`。
   - 不保存 runtime handles；写前继续 redaction。
   - 明确是客户端重连 projection：丢失时从 transcript unfinished entries、活动 Runner/Registry 和 durable pending inbound 校准，不影响 canonical history。

不新增独立的“sidebar index 表”。`conversations` 本身就是列表事实源，避免重演 `index.json` 与 `meta.json` 的双写。

## 5. Store 与事务边界

### 5.1 保持边界、替换实现

- 保留 `ConversationTranscriptStore` behaviour，把默认实现改成 SQLite；测试 fake 仍可通过 `:transcript_store` 注入。
- `ConversationStore` 暂时保留为调用方 facade，内部改为 Ecto query/transaction；保留 string-key map、ISO8601 timestamps、`touch: false`、not-found 映射、internal access 和 owned metadata merge 等公共语义。删除所有公开 path helper 和文件布局契约后，再按职责拆成 `Conversation.Store`、`Run.Store` 等小 owner。
- `SessionStore` 增加 SQLite 实现并让 `PubSub.Session` 依赖 behaviour，而不是继续硬编码 `SessionStore.File`。
- `OperationReceipt` 保留公开返回语义，但存储由 DB 实现；消息接受等复合动作不能再由调用方串联多个 store，而应进入一个聚合事务 API。
- 所有 PubSub、channel delivery 和 host notification 都在事务成功后发出。事务重试不得重复外部通知。

### 5.2 消息接受是“持久预留 + owner 内提交”，不是跨内存状态的假事务

数据库事务不能包含 RunSupervisor 启动、CandidateQueue 的 `:queue.in/2` 或 Runner continuation。保持 `docs/runtime-contracts.md` 已有的 `reserved/completed/unknown` 语义，按真实 owner 分路径实现：

1. 所有带 `request_id` 的操作先以短事务 reserve receipt；相同 fingerprint 的 completed 返回原 receipt，遗留 reserved 转为 `delivery_unknown`，冲突返回 `idempotency_conflict`。在任何工作尚未开始且 `require_idle?` 等前置条件失败时，仍可条件删除 reserved receipt。
2. idle/new run：Coordinator 先完成会话独占和 RunSupervisor 启动；Runner 初始化事务插入 inbound entry，并把 receipt 从 reserved 改为 completed（`action: started, run_id`）。提交成功后才启动 provider task。事务失败则不得启动 provider。
3. running steer/follow_up：CandidateQueue 的 GenServer 先在同一次 call 内检查 run_id、seal 和 capacity；通过后执行事务，插入 `consumption: pending` 的 inbound entry并完成 receipt，再把同一 message 放入内存 queue。若 DB commit 后进程在入队/回复前死亡，receipt 重放 accepted，durable pending entry 在恢复时显示为 undelivered，不能重复插入。
4. next_turn：Session 先验证 `expected_run_id`，再在事务中插入 inbound entry、更新 `session_snapshots.next_turn_messages` 并完成 receipt；提交后才更新内存 projection/广播。
5. 删除 pending：先由 CandidateQueue/Session owner 阻止 Turn 再 drain 该项，然后事务删除 transcript entry，并在 next_turn 情况同步更新 snapshot。失败必须返回“持久状态未收口”，不能谎称完全删除。

这不是 exactly-once：DB commit 与内存入队/进程回复之间仍有崩溃窗口。契约是“durable accepted + 可识别 undelivered”，不是通过事务承诺进程消息与数据库原子。

### 5.3 其他单事务动作

1. 创建会话：conversation + editor state + 可选初始 entries。
2. 用户消息 append 与 sidebar recency：entry insert + conversation recency 更新。
3. run terminal：同 run 的 streaming assistant/running tool 批量收口 + usage put-once + 可选最小 run header 终态；提交后才广播 run_end。
4. archive/delete：conversation 及受 FK 管理的 entries/editor/runtime projection。全量冷启动后 schedule 与 conversation 从建表第一版就使用确定的 FK/删除策略。

审批不新增表：live Runner 的 interrupted `%Agent.State{}` 是唯一可执行 continuation；Session `control_events` 是重连 projection。两个客户端同时决定时，Coordinator/Runner 的 run_id 与 awaiting 状态校验只允许一次 resume。宿主重启后没有 continuation，recovery 收口相关 running tool/assistant 并清除 pending approval projection，不显示成仍可批准。

不要求在一个事务中的内容：普通 sidebar 读取、PubSub、通知、provider/tool/host 调用、显式导出、可重建全文索引。所有这些都在 DB commit 后发生，且事务重试不得重复外部副作用。

### 5.4 并发写、分页与批量操作

- append 在短 `BEGIN IMMEDIATE` 事务或等价单语句原子 SQL 内分配 `next_entry_sequence` 并 insert；绝不先在 BEAM 里读 sequence 再另行写入。
- generic patch 保留现有 deep-merge 与 `$append` 语义。envelope 列和 payload 的修改用 revision CAS + 有界重试，或在 immediate 事务内完成，不能彼此漂移。
- assistant 文本使用专用原子 SQL：`content = COALESCE(content, '') || delta`、revision + 1，并返回提交后的 content/UTF-8 byte length，使 `TranscriptPersistence` 能准确计算 `text_offset`。首个 delta 仍需 append/upsert 完整 entry；finalize patch 同时保存 status/phase/thinking/content_blocks。
- page cursor 仍是公开 entry ID：验证它属于当前 conversation，取得 sequence 后查询更早记录。一次读取 `limit + 1`（limit clamp 1..200，默认 100）计算 `has_more?`，结果恢复正序；cursor 已删除返回 `:invalid_cursor`，`before` 返回本页最老 entry ID 或 nil。
- `replace_all` 在一个事务内删除、按 1..N 重建 sequence、把 `next_entry_sequence` 设为 N+1，并分批 `insert_all`；批大小低于 SQLite bind parameter 上限。不得在事务中逐 entry 查询。
- `cancel_running_tools`、`settle_unfinished` 和 startup recovery 使用按 `(conversation_id, run_id, status/tool_status)` 的批量 UPDATE，不再先 `list` 全历史再 N+1 update。
- `SQLITE_BUSY/LOCKED` 只允许在整个、尚未产生外部副作用的事务边界做少量有界重试；不能重试 ambiguous commit，更不能用无限等待掩盖锁问题。
- 公开 map 继续返回 ISO8601 string timestamps，并保持 `TranscriptEntry` 对 legacy/canonical tool key 以及显式 nil 清值的语义；Ecto schema 和内部时间精度不泄漏给调用方。
- append/replace/save editor state 在 conversation 不存在时稳定映射为 `{:error, :not_found}`，不能泄漏 FK 异常。

## 6. SQLite 运行策略

当前 `ecto_sqlite3` 默认是 WAL、`synchronous: :normal`、foreign keys on、2 秒 busy timeout、pool size 5。会话切换需要把关键配置集中到 `Handbean.Repo.init/2`，使 dev/release/mobile 不会因各自只传 database/pool 而漂移：

1. durability：生产固定使用 WAL + `synchronous: :full` + foreign keys on。现有契约是 visible assistant delta 在广播前已经 sync；`NORMAL` 只能覆盖进程崩溃，不能继续声称覆盖断电。若逐 chunk FULL commit 的目标设备 p95/p99 不可接受，基准和调整的是广播前的有界 coalesce cadence/bytes，不是把 synchronous 偷降为 NORMAL；合并后的每个可见 delta 仍须先 commit 再广播。
2. location：数据库必须位于 host 声明的本机持久目录；WAL 不支持 NFS，`busy_timeout` 也不能修复 SHM/远程 lock。共享 runtime 不凭 OS 猜测静默搬到 `/tmp`；桌面/mobile host 明确声明其 data directory，显式 `DATABASE_PATH` 若指向已知不支持的位置则拒绝写入并给出可操作错误。
3. ownership：支持边界仍是一个 resolved DB path 由一个 Handbean runtime 使用；desktop/mobile launcher 在启动层避免重复实例。首版不为一次性切换增加 storage epoch/bootstrap 状态机。运行期保留或复用现有可崩溃释放的 native lock 时，只按实际 DB path 派生 sidecar，不能锁整个 data directory，以免与 mobile 同目录的 `app.db` 混淆；第二实例返回明确错误。
4. writes/pool：不为每个 session 建连接，只使用受监督的 `Handbean.Repo`。多语句 read-then-write 使用 immediate transaction，能用 `UPDATE/INSERT ... RETURNING` 的路径优先单语句原子 SQL，避免 deferred transaction 的 read→writer upgrade `BUSY_SNAPSHOT`。以真实连接池 1/2/5 做并行 streaming + schedule + error tracker workload 后固定 pool 和 bounded busy timeout；timeout 只吸收短暂本机竞争，不是长事务或 NFS 修复。
5. checkpoint：保留显式 `wal_autocheckpoint` 基线并记录 WAL bytes、checkpoint busy/log/checkpointed pages、commit latency。只有长时 workload 证明 WAL 不收敛时才增加“无 active run + 超过实测阈值”的受监督 PASSIVE checkpoint；RESTART/TRUNCATE 仅可在 idle maintenance 使用，不在每次 run_end 执行。
6. errors：新增统一 SQLite error classifier，区分 busy、full、ioerr、corrupt、constraint、unknown，并只输出脱敏诊断。DB 自身 BUSY/FULL/CORRUPT 不能触发 ErrorTracker 向同一个 Repo 递归写错误；Schedule Clock 等后台 writer 在 Repo health circuit breaker 打开时暂停。
7. test isolation：SQL Sandbox 合适做业务事务测试，但会掩盖真实多连接 WAL 竞争。另建 async false、临时磁盘 DB、真实 pool 的测试组覆盖 immediate transaction、BUSY、checkpoint、backup 和第二 OS process ownership。

## 7. 崩溃恢复与备份

### 7.1 Startup recovery

- 替换 marker/items 目录扫描：用 partial/indexed query 找 `status = streaming` 的 assistant entry 与 `tool_status = running` 的 tool entry；若实测需要最小 `conversation_runs`，它只缩小候选集合，不成为第二状态机。
- 保留恢复 owner 的进程身份授权：只有注册的 `Handbean.Agent.TranscriptRecovery` 本身可读取/收口 internal delegated conversation，不能通过 caller option 绕过。
- 对宿主重启遗留记录做幂等事务：同 run 的 streaming assistant/running tool → error/unknown，写一次稳定 recovery notice，并清除 Session pending approval projection。由于没有完整 Agent State，不恢复 approval/stall continuation，不重放工具或重发旧回复。
- `Session` 启动时以 durable transcript、pending consumption 和活动 Runner 校准 snapshot，不能让旧 snapshot 覆盖更新事实。
- `TranscriptRecovery` 继续在 Repo/Migrator/PubSub/Registry 之后启动。移动端现有额外 `Handbean.Runtime.mark_interrupted_runs()` 与它合并成同一个幂等入口，不能冷启动时跑两套竞争恢复。

### 7.2 数据库健康、备份与恢复

- migration 后运行 schema/FK smoke check；普通启动不每次做无界 full integrity scan。提供显式诊断入口执行 `quick_check`、`foreign_key_check`、关键索引/表存在性和 WAL 状态，并输出脱敏结果。
- 遇到 `SQLITE_CORRUPT/NOTADB`：Repo health circuit breaker 拒绝新的 conversation/run 写，暂停 ErrorTracker DB 写与 Schedule polling，保留数据库及 `-wal/-shm` 原样供诊断，绝不自动删除或创建空库冒充恢复成功。
- 以 SQLite `VACUUM INTO`（或所有目标平台都实际验证过的 Online Backup API）创建在线一致 snapshot，不能在运行中直接复制 resolved DB 文件。备份写入临时目标，另开只读连接执行 `quick_check`、`foreign_key_check` 和 schema version 校验，落盘后原子发布。
- 恢复只在 maintenance/offline 模式进行：停止 runtime，确认目标 DB 没有活动 owner，再按 SQLite 一致性恢复流程替换经过校验的备份；不得把一次性切换的“直接删除空库重建”误用于真实故障恢复。
- 备份包含整个 Handbean Repo，因为同库事务是设计保证。没有 JSONL canonical 副本时，不能承诺从导出文件恢复最新运行状态。

## 8. 实施顺序

### 阶段 A：空库切换、schema 与 contract tests

1. 在部署/开发说明中列出一次性切换清单：停止所有 Handbean 进程；用当前环境的 Repo 配置解析并回显绝对 DB 路径；只删除该主库及同名 `-wal`、`-shm`、`-journal`；确认四者均不存在；再启动新代码并运行 migrations。这个步骤由操作者明确执行，不实现 reset 命令、epoch marker 或运行时 legacy 检测。
2. 由于所有环境都从空库开始，在现有 migration 历史中加入一个排序早于 `20260718000000_create_schedules.exs` 的 conversation 基础 migration，并原地修改 schedule migration，使 `schedules.conversation_id` 从建表时就是 `references(:conversations, type: :string, on_delete: :delete_all)`；`schedule_runs` 继续按 FK 级联。其余第 4 节表、约束与索引按依赖顺序创建；不实现 orphan schedule、旧 ID 对账、backfill 或数据迁移标记。
3. 在 `Handbean.Repo.init/2` 集中 WAL/synchronous/foreign-key/busy/checkpoint 配置和 error classifier。沿用并校正现有 migration 入口：root release 的 `Ecto.Migrator`、dev/test 的 Mix Ecto aliases、mobile `HandbeanProbe.App.migrate!/0` 都必须运行同一套 root migrations，并在 Clock/Recovery 启动前完成；不为这次切换重构成新的 bootstrap 框架。`ecto.reset`/测试清库在进程停止后使用标准 drop/create/migrate，并确认不会让 WAL/SHM companion 干扰下一次空库运行。
4. mobile 一次性切换通过卸载/重装、Android clear-data 或清除 iOS simulator/app container 完成。这样会同时清空 Handbean Repo、`HandbeanProbe.Repo` (`app.db`) 和旧 JSON artifacts；普通 `on_start/0` 不执行删除。
5. 重构 `mobile/test/test_helper.exs`：在启动 `:handbean` 之前设置唯一 data dir，并把 `Handbean.Repo` 与 `HandbeanProbe.Repo` 都指向该测试目录；分别运行对应 migrations 后再启动依赖它们的服务。对 Handbean Repo 使用 SQL Sandbox 或每测试独立临时 DB，不能再靠 `Handbean.Host.put!/1` 在已启动 pool 后改变 JSON 根目录来假装隔离。
6. 为 `ConversationStore`、`ConversationTranscriptStore`、`SessionStore`、`OperationReceipt` 固化与文件布局无关的公共行为测试；覆盖 sidebar recency、ISO8601 map、owned metadata、usage API、not-found、internal authorization 和 `TranscriptEntry` aliases，删除路径/行数/rename 实现断言。所有业务测试从全空数据库开始，不写 JSON import fixture，也不建立保留旧数据的升级 fixture。

验收：root dev/test/release 与 Android/iOS 都能从空库得到相同 schema；schedule FK 从建表即成立；旧 JSON/JSONL 不被读取；第二 runtime、unsupported storage、BUSY/FULL/CORRUPT 有明确结果。未删除旧库的升级路径明确不在支持或测试范围内。

### 阶段 B：会话 metadata、editor state、transcript

1. 实现 SQLite `ConversationStore` facade 和 transcript backend。
2. 一次替换列表/get/create/archive/pin/rename/editor state/usage/分页；删除 index rebuild、journal replay、pending intent 和 compaction 路径。
3. 给流式 append、通用 patch、delete、replace_all、cursor 删除、internal conversation authorization 做并发与权限回归。
4. 事务提交后才执行现有 `broadcast_title_updated`、Session event 和 UI refresh。

验收：Web/CLI/native 从同一 DB 看到相同 history；10k entries 的冷分页不加载全历史；并发 delta 不丢字节、重复 entry ID 不覆盖、archive/list 顺序不漂移。

### 阶段 C：两阶段 admission、receipts 与 run 收口

1. 将 operation receipts 移入表，按第 5.2 节分别在 Runner、CandidateQueue、Session 的真实 owner 内完成 reserve→durable accept→receipt complete，不建立一个虚构的跨进程“大事务”。
2. 批量化 terminal path：按 conversation/run 一次收口 unfinished assistant/tool entries，并 put-once usage；提交后才广播 run_end。写失败时不先修改内存 settled 状态。
3. approval/stall check 继续由 Runner interrupted state 与 Session control projection 管理；补 Web/native 同时 decision、旧 run_id、Runner 在 decision 前后退出的竞态测试，不新增 tool/approval 表。
4. pending delete 依照 owner 阻止 drain 后再收口 durable entry/snapshot；测试失败返回与恢复行为。

验收：在每个 DB/owner 边界注入崩溃，`queue_full/sealed` 不留下 accepted entry，durable accepted 但未注入能恢复为 undelivered，工具结果写失败不伪装 settled，外部副作用不自动重放。

### 阶段 D：Session snapshot 与 startup recovery

1. `PubSub.Session` 改为注入 `SessionStore` behaviour 的 SQLite 实现，移除对 `.File` 的硬编码，并保持 500ms throttled snapshot 不与每 delta transcript commit 重复竞争。
2. 用 indexed unfinished-entry query 替换 marker/items 目录扫描；统一 root/mobile 的 startup recovery，保留 registered recovery process 的 internal-read 权限边界。
3. 删除 `ConversationTranscriptStore.Journal`、`SessionStore.File`、旧 operation JSONL 的运行时依赖；将其 native lock 能力迁到目标 DB 专属 StorageLock，不删除 lock NIF。
4. 删除 `conversation_root/session_store_dir` 配置及所有 path helper 调用；subagent descriptor、saved tool input、worktree 等非会话 artifact 另行确认路径 owner，不能随 conversation directory 被误删。数据库只保存它们必要的引用/生命周期事实。

验收：冷启动幂等收口 orphan assistant/tool 并清除不可继续审批；snapshot 缺失不影响 canonical transcript；旧 JSONL 即使仍在磁盘也不会被读取。

### 阶段 E：运维、性能与全端验收

1. 更新 `docs/runtime-contracts.md`、`docs/transcript-durability.md`、安全/备份说明和用户数据位置说明。
2. 增加 quick-check/backup 诊断命令和 telemetry dashboard 指标；确认日志不含 transcript、工具参数、凭据或绝对隐私路径。
3. 建立 workload：并行多 conversation streaming、审批、subagent、schedule、10k/100k entries 分页、bulk replace、长读、磁盘满、kill -9、重启重叠、WAL checkpoint。
4. 移动端按 `verifying-handbean-mobile` 专项流程验证双 Repo 空库 migration、clear-data/uninstall cutover、冷启动、后台/前台和强杀恢复；Android/iOS 分别报告 host test、package、模拟器和真机结论。桌面覆盖 macOS、Linux、Windows 可用矩阵，不把单平台通过写成全平台通过。

验收门槛：无无限 retry；正常本地并发无未解释 `SQLITE_BUSY`；事务 p95/p99、WAL 峰值和 checkpoint 可解释；备份可恢复且通过 quick/FK check；数据库错误不会被包装成 provider/tool 成功。

## 9. 重点测试矩阵

| 风险 | 自动测试 |
| --- | --- |
| sequence/patch 并发 | 多 Task 同 conversation append；CAS patch；原子 text append；unique constraint 映射成稳定业务错误 |
| 原子接受消息 | receipt、inbound、pending consumption 任一点 fault；commit 前无 provider/queue；commit 后崩溃可显示 undelivered |
| 审批竞态 | Web/native 同时 approve/deny；旧 run_id；Runner 在 decision 前退出；宿主重启后 pending control 不再可批准 |
| 工具副作用 | 工具已执行而 result 写入 SQLITE_FULL；内存不先标 settled；恢复成 unknown/error 且不重放 |
| run terminal | assistant/tool bulk closure、usage put-once 同事务；重复 run_end 幂等 |
| pagination | newest 100、向前翻页、并发 append、cursor 删除、replace_all、internal access control |
| locking | pool 并发、第二 OS process、每个实际 DB 独立 lock、busy timeout、长读、长事务检测；查询计划确保复合索引命中 |
| empty-schema setup | root dev/test/release 与 mobile 分别从不存在的 DB 运行完整 migrations；schedule FK/索引存在；所有 store 在 schema ready 后才启动 |
| WAL/空间 | 持续并发写、长 reader、checkpoint busy、WAL 收敛、磁盘满、I/O error |
| corruption/backup | NOTADB/CORRUPT 不删原库；在线 backup 在并发写时一致；恢复副本通过 quick/FK check |
| host | desktop restart overlap；Android/iOS clear-data/reinstall、双 Repo migration、cold start、force-stop；数据库始终位于 host 私有本地持久目录 |

## 10. 验证命令（实施时按风险逐步执行）

```sh
mix compile --warnings-as-errors
mix test test/handbean/conversation_store_test.exs \
  test/handbean/conversation_transcript_store_test.exs \
  test/handbean/agent/operation_receipt_test.exs \
  test/handbean/agent/transcript_persistence_test.exs \
  test/handbean/agent/transcript_recovery_test.exs \
  test/handbean/pubsub/session_test.exs
mix test test/handbean/agent test/handbean/pubsub test/feature
mix test
npm test
```

共享 schema 和 runtime 改动还要进入 `mobile/`，加载 `verifying-handbean-mobile` 技能后执行其当前 host/package/simulator/device 矩阵；migration 或 native package 行为必须重新打包并冷启动，不能只热加载。

## 11. 顾问评审结论与采纳

顾问首轮结论是“有条件通过”。评审认为 SQLite canonical、无旧会话导入、同库事务、FTS 延后和备份/故障路径方向成立，但初稿把 `tool_calls`、`approval_requests` 和完整 `agent_runs` 设计成独立表，会与 transcript、Runner、Session 形成第二套 runtime/权限状态机。

本版已采纳主要意见：

- 删除 tool/approval 影子事实表；工具事实留在 transcript entry，审批 continuation 留在 live Runner，最小 run header 也改为“基准证明需要才建”。
- 把“消息、receipt、内存 queue 一次原子提交”的错误表述改成按 Runner/CandidateQueue/Session owner 的两阶段 admission，并明确 commit→内存动作之间的 undelivered 窗口。
- 补齐 sidebar recency、ISO8601 wire map、unkeyed usage key、owned metadata、not-found、deep merge、text offset、replace sequence 和 page cursor 契约。
- 固定 FULL durability，把 flush coalescing 作为性能变量；补 immediate transaction、真实 pool 测试、ErrorTracker 递归写、root/mobile migration/lock 顺序、单一 recovery owner 和 verified backup/restore。

评审后产品进一步明确：旧 Handbean Repo 的全部数据均可丢弃。因此本版删除了 orphan schedule、旧 ID 对账和“保留既有非会话数据前滚”的兼容设计，改为一次显式停机 reset 后从空库执行 schema migrations。这一变更缩小了数据迁移风险，但扩大了被接受的数据损失范围。

顾问随后针对 full-reset 增量复核时，曾按“应用必须防止操作者漏删旧库”的假设建议 storage epoch、reset marker 和 quarantine 状态机。产品现已明确这是受控开发/部署切换，旧 Repo 会在新代码启动前直接删除，因此本版不采纳这套永久运行时机制，并把“未删除旧库直接升级”明确列为不支持。仍保留评审中与简化方案有关的三项修正：conversation migration 排在 schedule 前并从建表建立 FK；所有环境按实际 DB 路径删除 companions；mobile 用 clear-data/reinstall 且测试配置两套独立 Repo。

顾问按这一明确支持边界重新复核后的结论为 **PASS**：在旧 DB 和 companions 必定于新版本首次启动前删除的前提下，简化后的无 epoch 方案没有剩余 P0/P1。非阻塞建议中的 parent self-FK 删除语义和 dev/test reset companion 处理也已写入阶段 A/数据模型。

顾问意见属于设计审查，不替代实现时的测试结果；pool size、busy timeout、checkpoint/coalesce 阈值仍须由目标平台 workload 决定，不能照抄其他 Agent 的常量。

## 12. 完成定义

- 这是一次受控的全量冷启动：旧 Handbean Repo 的所有业务数据均不保留；切换时先停进程，再删除实际配置的 DB 及同名 WAL/SHM/journal companions，确认不存在后才运行新 migrations。
- 不实现 storage epoch、自动 reset 或旧库兼容检测；未先删除旧库就启动新版本明确不受支持。
- 旧 conversation/session JSON/JSONL 不迁移、不双写、不隐式回退，在线运行不再读取或写入它们。
- 会话、entry、usage、receipt 的持久 owner 只有一套；工具事实仍在 transcript entry，审批 continuation 仍由 live Runner 独占，Web/native 只做适配与 projection。
- 第 5.2 节每条 admission 路径都有明确的 DB commit 与内存 owner 边界，事务外副作用都有 unknown/idempotency 语义。
- 不存在旧 schedule/memory/settings/error 数据兼容路径；新空库从第一版 schema 起使用正确 FK、约束和 owner。
- 本机单 owner、WAL、checkpoint、磁盘满、损坏、在线备份和移动生命周期都有可运行测试或真实宿主证据。
- 文档不再声称 JSONL journal 是 canonical；用户能区分“进程崩溃可恢复”“外部副作用未知”“数据库损坏需备份恢复”三种情况。
