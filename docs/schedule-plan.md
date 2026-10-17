# 定时任务：实施计划

状态：已实现，待验收。约束见 [定时任务：需求与原则](./schedule-requirements.md)，本文只写怎么做。第 2 节的代码事实已对照 `dev`（`129f94b`）核对。

## 1. 范围

第一版做到：在一个**工作区对话**里创建定时任务；到点后，对话空闲就开始一轮无人值守运行，结果写回这条 transcript。用户在 Web 或手机上打开这个对话就能看到结果；Android App 在后台时，会收到现有的“运行结束”系统通知。

不在第一版：

- 推送到 SNS / Webhook / 邮件。`Delivery` 目前只有 `Noop`，见第 9 节。
- 自由对话（没有工作区）。
- native 端的管理界面。
- “只在有变化时提醒”需要的跨轮状态存储。

## 2. 现有代码

| 位置 | 现状 | 影响 |
| --- | --- | --- |
| `Coordinator.add_message/3` | 对话 `running?` 时把新消息作为 `:steer` 入队；只有带 `task_instructions` 时才返回 `:run_in_progress` | 要加 `require_idle?`，忙时直接拒绝，不入队 |
| `OperationReceipt` | 按 `{:message, conversation_id}` + `request_id` 做持久化幂等；`reserved` 状态在重启后变成 `unknown`，不会重放 | 直接用来保证同一计划点只派发一次 |
| `TranscriptPersistence.inbound_origin/1` | `source in [:webhook, :sns, :schedule, :scheduler]` 时写 `origin.kind = "automatic"` | 已经支持，UI 会显示 `Automatic · schedule` |
| `TranscriptPersistence.delivery_channel?/1` | 只有 `:sns` / `:webhook` / `:cli` 或显式传了 `:delivery` 才发送 | `:schedule` 不发送，与第 9 节一致 |
| `TranscriptPersistence.record_stop_notice/3` | `max_turns` / `stalled` / `halted` 等状态会写 `msg-run-stop-<run_id>` | 定时运行停止时的说明直接复用 |
| `Agent.Config.channel_max_turns/1`、`ProgressGuard.enabled?/1` | 各自硬编码 `[:sns, :webhook, :cli]` | 加入 `:schedule`，并收敛到一处判断 |
| `Middleware.ToolGuard` | 判定为 `:prompt` 的调用先走 AutoReview，再进入 `:interrupted` 等人工批准 | 定时运行里照常走 AutoReview；只有本该进入人工批准的分支改成停止并说明 |
| `Agent.Config.build_context/2` | 工具 context 里有 `conversation_id` / `workspace_id` / `run_id`，没有 `source` | 定时工具要靠 `source` 判断能不能改调度，需要补上 |
| `TaskTracker` | 订阅 `runtime:runs`，用 `run_end` 判断运行是否结束 | 定时记录用同一个 topic 回写每次的结果 |
| `MessageSubmission.run_opts/2` 等 | 模型、provider、OM 参数都在 `HandbeanWeb` 里拼 | runtime 不能依赖 web（`.reach.exs`），需要抽出非 web 的构造函数 |
| `mix.exs` | 没有时区库，Elixir 默认只认 UTC | 要新增依赖 |
| `priv/repo/migrations` | SQLite，目前只有 engrams 和 ui_settings 两张表 | 新增定时任务表 |

## 3. 数据模型

新增迁移 `create_schedules`。

### 3.1 `schedules`

| 字段 | 说明 |
| --- | --- |
| `id` | UUID |
| `workspace_id`、`conversation_id` | 创建时由运行时写入，之后不能改；建索引 |
| `name` | 显示用 |
| `instruction` | 已保存的指令，包括创建时用户的偏好 |
| `rule` | JSON，见 3.3 |
| `time_zone` | IANA 时区名，创建时校验 |
| `model`、`reasoning_level` | 创建时用的复合模型 id；触发时重新校验，不自动换成别的模型 |
| `status` | `active` / `paused` / `disabled`（对话不存在或已归档） |
| `next_run_at` | UTC；建索引 `(status, next_run_at)`，供时钟查询 |
| `version` | 整数，乐观锁 |
| `created_by` | `user` / `agent` |
| `inserted_at`、`updated_at` | |

### 3.2 `schedule_runs`

| 字段 | 说明 |
| --- | --- |
| `id` | |
| `schedule_id` | |
| `slot_at` | 计划时间（UTC）；手动“立即运行”这一列为空 |
| `kind` | `scheduled` / `catch_up` / `manual` |
| `request_id` | 计划点固定为 `sched-<schedule_id>-<slot_unix>`；手动运行为 `sched-<schedule_id>-manual-<uuid>` |
| `status` | `claimed` → `started` → `completed` / `failed` / `stalled` / `halted` / `cancelled`；或者 `skipped` / `unknown` |
| `reason` | 跳过或失败的原因，比如 `busy`、`model_not_allowed`、`missed:3`、`delivery_unknown` |
| `run_id` | 被接受后的 run |

唯一索引：`(schedule_id, slot_at)`，只对 `slot_at` 非空的行生效。数据库层面保证同一计划点只有一行。

### 3.3 频率规则

第一版支持两种：

- `{"kind": "weekly", "weekdays": [1..7], "times": ["09:00", "18:30"]}`：每天固定时间就是 7 天全选。
- `{"kind": "interval", "every_minutes": N}`：`N` 不小于 1。从保存或恢复的那一刻开始算。

不做 cron 表达式。cron 表达式让 Agent 有了把频率写得更密、又不容易被用户看出来的余地。

只跑一次的规则不在这里定义，见 [一次性定时](./schedule-once-plan.md)。

## 4. 模块

| 模块 | 职责 |
| --- | --- |
| `Handbean.Schedule.Rule` | 纯函数：校验规则；`next_after(rule, tz, utc_dt)`；`latest_due(rule, tz, from, now)` 返回最近一个到期点和错过的个数 |
| `Handbean.Schedule.Store` | Ecto schema 与查询；`claim/2`、`record/3`、`pause/resume/update/delete`。所有写操作都带 `version` 条件 |
| `Handbean.Schedule.Clock` | 应用级 GenServer，全局只有一个写者。只负责找到到期任务并领取，派发交给 Task |
| `Handbean.Schedule.Dispatch` | 在 `Task.Supervisor` 下运行：检查前置条件，组装 run opts，调用 `Coordinator.add_message/3`，回写结果 |
| `Handbean.Schedule.Recorder` | 订阅 `runtime:runs`，按 `run_id` 把 `run_end` 的终态写回 `schedule_runs` |
| `Handbean.Schedule.Notice` | 往 transcript 写跳过、补跑、无合法模型等说明（`system_msg`，ID 固定） |
| `Handbean.Agent.RunOpts` | 从 `HandbeanWeb.*` 抽出来的、和 web 无关的 run opts 构造：模型解析、provider、推理级别、OM。LiveView 和 Dispatch 共用 |
| `Handbean.Agent.Channel` | `unattended?/1`、`interactive?/1`，替代散落在各处的 source 列表 |
| `Handbean.Tool.Builtin.Schedule` | Agent 用的 `schedule` 工具 |

监督树：`Clock` 和 `Recorder` 放在 `Handbean.AgentRunSupervisor`、`Handbean.Runtime.TaskTracker` 之后，`HandbeanWeb.Endpoint` 之前。派发用已有的 `Handbean.AgentRunTaskSupervisor`。

## 5. 运行时流程

### 5.1 时区

- 新增依赖 `{:tz, ...}`，配置 `config :elixir, :time_zone_database, Tz.TimeZoneDatabase`。选它的原因：纯 Elixir，时区数据在编译时打包，运行时不联网、不写盘，手机上也能用。
- 夏令时：当地时间不存在时（拨快那一小时），取间隔结束后的第一个有效时刻；当地时间出现两次时（拨回那一小时），取较早的一次。两种情况都在 `Rule` 里写死并测试。
- 用户的时区来源：
  - Web 端在 LiveView 连接参数里传 `Intl.DateTimeFormat().resolvedOptions().timeZone`，写进 run context 的 `user_time_zone`。
  - 工具调用时显式传了时区就用传入的，否则用这个值。两者都没有时拒绝创建，不默认成 UTC。

### 5.2 时钟

1. 启动时（以及每次 tick）：
   - 把 `schedule_runs` 里状态为 `claimed` 的行改成 `unknown`，原因 `delivery_unknown`。
   - 把 `started` 但对应 run 已不存在的行也改成 `unknown`。
   - 两种情况都不重新派发。
2. 定时器设为 `min(最早的 next_run_at - now, 60s)`。设上限是为了睡眠恢复、改系统时间之后，最多 60 秒内会重新拿持久化的时间和当前时间比较。是否到期不靠“定时器有没有响过”判断。
3. tick 时查询 `status = active AND next_run_at <= now`，每条执行 `Store.claim/2`。领到的交给 `Dispatch` 跑，时钟本身不等派发结果。

### 5.3 原子领取

在一个 SQLite 事务里：

1. 用 `Rule.latest_due` 算出这次要跑的计划点 `slot`、错过的个数 `missed`，以及新的 `next_run_at`。
2. `UPDATE schedules SET next_run_at = ?, version = version + 1 WHERE id = ? AND version = ? AND status = 'active'`。受影响行数为 0 说明被并发修改了，放弃，下次 tick 重新读。
3. `INSERT schedule_runs (slot_at = slot, status = claimed)`。撞上唯一索引就回滚，当作已经领取过。
4. `missed > 0` 时再插一行 `skipped`，原因 `missed:N`，记录被跳过的时间范围。

计数、状态和下一次时间放在同一个带版本号的 UPDATE 里，不会被另一条更新覆盖。

### 5.4 派发

`Dispatch.run(claim)` 按顺序检查，任何一步不通过都把这次记为 `skipped` 并写一条说明。

1. **对话**：存在、没归档、不是 internal、属于这个工作区。不满足时把任务改成 `disabled`，以后不再触发。
2. **模型**：用 `ModelConfig.model_allowed_for_workspace?/2` 检查已保存的模型，再用 `resolve_model_for_workspace/2` 拿到 provider。不允许时记为 `model_not_allowed`，不换模型。
3. **空闲**：对话忙就记为 `busy`。这里只是提前判断，真正的保证在第 4 步。
4. **派发**：调用 `Coordinator.add_message(conversation_id, content, opts)`，参数如下。
   - `source: :schedule`、`channel: :schedule`、`require_idle?: true`、`request_id`。
   - `origin: %{"kind" => "automatic", "source" => "schedule", "schedule_id" => …, "slot_at" => …}`。
   - `tools`：`Agent.default_tools()` 去掉 `computer` 和 `ArtifactDelivery.tool_names()` 里的工具。
   - 其余参数（`workspace_path`、模型、OM 等）由 `Agent.RunOpts` 按触发时的工作区设置生成。
   - 消息正文是一行标题 `[定时任务「name」· 计划时间 2026-10-01 09:00 Asia/Shanghai]`，后面接已保存的指令。不带“刚才聊到哪”。
5. **派发结果**：
   - `{:ok, ack}`：改成 `started`，写入 `run_id`。
   - `{:error, :busy}` 或 `:run_in_progress`：记为 `skipped`，原因 `busy`。
   - `{:error, :delivery_unknown}`：记为 `unknown`。
   - 其他错误：记为 `failed`，带上原因。
   - 都不重试。

`Coordinator` 需要的改动：`require_idle?: true` 时，`admit_message/4` 在 `running?: true` 分支直接返回 `{:error, :busy}`，不调用 `enqueue_candidate`。`start_run` 里因竞争返回 `:run_in_progress` 时也不重试。

### 5.5 运行中的限制

- **把 `:schedule` 当无人值守渠道**：
  - `Agent.Channel.unattended?(:schedule)` 返回 true。
  - `Config.channel_max_turns/1` 和 `ProgressGuard.enabled?/1` 都改成调用它，兜底轮数为 200，进展守卫开启。
  - `delivery_channel?/1` 不改，`:schedule` 不发送。
- **需要批准的工具**：
  - 定时运行允许 AutoReview 代替人工批准。`:prompt` 调用照常进入 `review_or_interrupt/3`：工作区开启 AutoReview 时先审查，审查通过就执行，审查拒绝就按现有逻辑返回拒绝结果。
  - 只改 `interrupt/3` 这一个出口：`config.source == :schedule` 时不进入 `:interrupted`，改为置 `status: :halted`，错误写“定时运行不能等待人工批准：<tool>”。会走到这里的情况：工作区没开 AutoReview、AutoReview 返回 `:fallback`（超时、出错、拿不准）、调用里含 `computer`（AutoReview 本来就跳过它）。现有的 `record_stop_notice` 会把说明写进对话。
  - AutoReview 的判断每次运行都重新做，不缓存上一次的结果。
  - 不复用 `tool_guard_session_allow`：每次运行都是新 State，不需要额外处理。
- **工具 context**：`Config.build_context/2` 补上 `source`，`schedule` 工具据此判断。

### 5.6 结果回写

- `Recorder` 收到 `{:run_lifecycle, cid, :run_end, payload}` 时，按 `run_id` 找 `schedule_runs`，把终态写进去。
- `:interrupted` 不算终态。照理不会出现，因为 5.5 已经把它改成了 halted。
- 应用在运行中途重启：`started` 行在 5.2 第 1 步被标成 `unknown`。transcript 本身由 `TranscriptRecovery` 处理。

### 5.7 对话里能看到什么

| 情况 | 对话里出现的内容 |
| --- | --- |
| 正常运行 | `Automatic · schedule` 的消息，加上 assistant 回复 |
| 停止（halted、stalled、达到轮数上限） | 现有的 `msg-run-stop-<run_id>` |
| 对话忙、无合法模型、对话不可用 | `msg-sched-skip-<schedule_runs.id>`：“定时任务「name」本次（时间）已跳过：原因” |
| 补跑 | `msg-sched-catchup-<id>`：“错过 N 次（从 A 到 B），只补跑最近一次” |
| 结果不明 | `msg-sched-unknown-<id>`：“定时任务「name」本次（时间）结果不明，不会自动重跑” |

说明直接写 transcript，不走 `Delivery`。ID 固定，重放不会重复。

## 6. Agent 工具与权限

`schedule` 工具有这些动作：`list`、`get`、`history`、`create`、`update`、`pause`、`resume`、`delete`、`run_now`。

- **身份**：`conversation_id` 和 `workspace_id` 只从 context 读，参数里没有这两个字段。只能看到和修改当前对话的任务。
- **谁能改**：只有 `Channel.interactive?(context.source)`（`:live_view` / `:native`），并且不是委派或 thread 运行时，才允许写操作。其他情况一律返回 `schedule_changes_require_user_turn`。所以定时运行、抓到的网页、技能都改不了调度。
- **频率要确认**：`ToolPolicy` 增加 `schedule_decision/2`（写法同 `computer_decision`）。
  - `create`、`update`（改了频率或指令）、`run_now` 在非 yolo 模式下一律 `:prompt`。
  - 审批卡片显示：规则、时区，以及解释后的下 3 次时间。
  - `list`、`get`、`history`、`pause`、`delete` 自动通过。
  - 这样“比用户刚同意的更密”就会落到一次明确的批准上。
- **创建时必填**：`rule`、`instruction`、时区（显式传入，或来自 `user_time_zone`）。缺任何一项都拒绝，不补默认频率。
- **保存或修改后**只重新计算 `next_run_at`，不立即运行。`run_now` 单独派发，不改 `next_run_at`。
- **暂停与恢复**：暂停后设 `next_run_at = NULL`；恢复时从当前时刻重新计算，不补暂停期间错过的点。

## 7. Web UI

对话头部加一个“定时任务”入口，侧栏显示：

- 当前对话的任务列表：名称、规则的人类可读描述、时区、下次时间（按用户本地时区显示）、状态。
- 操作：暂停、恢复、立即运行、删除。改频率、时间或语言是再发一句到这个对话，不打开字段表单。
- 每条任务最近 20 次运行（来自 `schedule_runs`）：时间、类型、状态、原因。点 `run_id` 跳到对话里对应的位置。
- 新建：在这个对话里用一句话说何时、做什么。Agent 调用 `schedule` 落盘。批准后在同一条对话里用白话确认时区、频率、钟点、送达本聊天，以及下一次时间。

UI 走 `Handbean.Schedule.Store` 的公开函数，不直接用 `Repo`（`.reach.exs` 禁止 web 层直接访问 Repo）。

## 8. 必须覆盖的反例

| 风险 | 验证 |
| --- | --- |
| 重复派发 | 两个进程同时对同一个到期点调用 `claim`，只有一个成功；同一个 `request_id` 再调一次 `add_message` 拿到原回执 |
| 崩溃后重跑 | 在 `claimed` 和 `add_message` 之间杀掉进程，重启后该行是 `unknown`，对话里有说明，没有新的 run |
| 插进用户的回合 | 对话正在运行、或在 `awaiting_approval`、或在 `stall_check` 时触发：记为 `skipped: busy`，`CandidateQueue` 里没有新消息 |
| 检查和派发之间的竞争 | 时序上“检查是空闲，派发前用户发了消息”：`require_idle?` 返回 `:busy`，不入队 |
| 补跑风暴 | `next_run_at` 在 3 天前、每天一次：只派发 1 次，记一行 `missed:2`，下一次时间在未来 |
| 夏令时 | `America/New_York` 每天 02:30：拨快那天在 03:00 触发；拨回那天只触发一次 |
| 暂停后补跑 | 暂停 2 天再恢复：不补，下一次从恢复时刻算 |
| 改频率后立刻跑 | `update` 之后 `next_run_at` 在未来，没有新的 run |
| 无人在场时请求批准 | 定时运行里调用需要 `:prompt` 的工具：AutoReview 通过则执行；AutoReview 关闭、返回 fallback、或是 `computer` 调用时，run 以 `halted` 结束并写说明，任务仍是 `active`；任何情况下都不出现 `:interrupted` |
| AutoReview 拒绝 | 定时运行里 AutoReview 拒绝某个调用：该调用不执行，模型收到拒绝结果，run 继续或按现有逻辑停止，不进入人工批准 |
| 1 分钟间隔叠加 | `every_minutes: 1`，单次运行超过 1 分钟：期间到点的计划点都记为 `skipped: busy`，不排队、不并发；同一个计划点只领取一次 |
| 定时运行改调度 | `source: :schedule` 的 context 调 `schedule create/update/delete/pause`：被拒绝 |
| 跨对话 | 工具参数里塞 `conversation_id`：schema 拒绝（`additionalProperties: false`） |
| 静默换模型 | 已保存的模型被移出允许列表：`skipped: model_not_allowed`，没有用别的模型运行 |
| 对话被归档 | 触发时把任务改成 `disabled`，之后不再触发 |
| 睡眠恢复 | 用测试时钟把“当前时间”往前拨 5 小时，下一次 tick 按第 5.3 节领取，不依赖定时器 |
| 失败不重试 | provider 报错：记为 `failed`，`next_run_at` 不变，下一个计划点之前没有新的 run |

测试里时钟要可注入：`Clock` 和 `Rule` 接收 `now` 参数，不在内部直接调 `DateTime.utc_now/0`。

## 9. 发送到其他渠道（不在第一版）

现在“对话内容同步到多个渠道”的实际范围：

- 同一个 Handbean 实例的 Web 和 native 都读同一条 transcript。
- Android 的运行结束通知（`TaskTracker` → `AndroidNotify`，App 在后台时生效）。
- `Delivery` 只在 `source` 是 `:sns` / `:webhook` / `:cli` 时调用，而且默认 adapter 是 `Noop`，仓库里没有真正的出站实现。

要把定时结果推出去，需要另写一份需求，至少回答这几个问题：

1. 推送目标存在哪，谁能配置。
2. 只推最终 assistant 回复，还是连同停止说明和跳过说明一起推。
3. 推送失败要不要重试。重试只针对推送这一步，不能连带重跑模型。

这一项和调度是正交的：在 `Dispatch` 里给 opts 加上 `delivery:` 即可接入现有的 `TranscriptPersistence.deliver/2`，第一版不需要为它预留别的结构。

## 10. 分期

| 阶段 | 内容 | 依赖 |
| --- | --- | --- |
| P0 | `tz` 依赖和配置；`Schedule.Rule` 及其测试（夏令时、补跑计算）；`Agent.Channel` 收敛 source 判断 | 无 |
| P1 | 迁移；`Schedule.Store`（原子领取、版本号、`unknown` 恢复）及并发测试 | P0 |
| P2 | `Agent.RunOpts` 从 web 抽出，LiveView 改用它，行为不变 | 无，可与 P0/P1 并行 |
| P3 | `Coordinator` 的 `require_idle?`；`ToolGuard` 定时运行停止；context 带 `source`；`Clock`、`Dispatch`、`Recorder`、`Notice` | P1、P2 |
| P4 | `schedule` 工具和 `ToolPolicy.schedule_decision`；LiveView 传 `user_time_zone` | P3 |
| P5 | Web 侧栏 | P4 |
| P6（之后） | native 管理界面；出站推送（第 9 节）；跨轮状态（“只报告变化”） | 各自另写需求 |

P3 合入之前，`Clock` 不放进监督树，以免半成品在后台触发。

## 11. 待定

已定：

1. **定时运行允许 AutoReview 代替人工批准**（见 5.5）。AutoReview 不可用或拿不准时仍然停止，不等人。
2. **`interval` 下限为 1 分钟。** 时钟的定时器上限是 60 秒（5.3），1 分钟间隔的触发误差最多约 1 分钟。
3. **跳过说明每次都写。** 注意：1 分钟间隔加上单次运行较长时，每分钟都会多一条“已跳过”。先按每次都写实现；如果太吵，再改成连续跳过只更新同一条。

## 12. 完成定义

- 第 8 节每一行都有自动化测试。`mix test --exclude slow` 通过，`mix compile --warnings-as-errors` 没有新的 warning。
- 实测：在一个专用对话里建一条“每天 09:00 Asia/Shanghai 抓某个公开 RSS 并总结”的任务，用测试时钟连续推进 3 天，对话里有 3 轮 `Automatic · schedule`，`schedule_runs` 里有 3 行 `completed`。
- 报告里写明已知限制：应用没在运行时不触发；结果只写进对话；需要登录的数据源不保证能取到。
