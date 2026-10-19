# Run、扩展与客户端恢复契约

保留 Coordinator → RunSupervisor（CandidateQueue + Runner）→ Turn。
不引入第二个状态机或另一份 UI runtime。Web/native 共用下面的约束。

## 消息何时算接受

- `conversation_id` 是对话身份；`run_id` 是一次执行身份；`request_id`
  是可选的幂等操作身份，不能互相替代。
- idle 消息：独占启动 RunSupervisor 后，在 Runner 初始化中写 inbound，
  成功后才启动 provider task。失败不会启动 provider。
- running 消息：Session 校验 `expected_run_id`，CandidateQueue 在同一次
  GenServer call 内检查 seal/capacity、持久化 inbound、再加入队列。
  `queue_full`/`sealed` 拒绝不能留下“已接受”的 user transcript。
- `:steer`/`:follow_up` 的 ack、队列项、通知与 transcript 都标记**接受它的 run**，
  不生成另一个运行身份。入队 ack 的 `run_pid` 保持 nil 兼容，`run_id` 有意义。
- `:next_turn` 是 Session 管理的延后消息，不等于本 run 的 steer 队列；它也在
  接受时持久化，delivery 明确写成 `next_turn`。
- 封口时发送，Coordinator 等待捕获的旧监督树 PID 退出，再重新路由；
  并发替代 run 已出现时只能向它重新申请接受，不能借旧身份入队。
- Runner 收尾只停止自己的监督树 PID。带 run_id 的事件和 finish 请求必须匹配
  Session 当前 run；旧 run 不得关闭或污染新 run。
- 接受不等于已注入：单数 `message_id` 是 queued，Turn 的 `message_ids`
  是 consumed。终态仍 queued 的消息是 undelivered。

操作回执不是 exactly-once 或数据库事务：进程可能在持久化、入队和完成回执之间
死亡。已有 `OperationReceipt` 对未完成预留保守返回 `delivery_unknown`，
不能由调用方擅自当成“没有执行”重试。已完成入队也会完成回执，重复 request_id
返回原接受 run_id，不再次入队。

## 终态

`AgentEvent.terminal_status?/1` 是消费者的唯一终态列表，接受 atom 和 JSON string：
completed、cancelled、error、timeout、max_turns、budget_exceeded、halted、stalled。
`interrupted`/`awaiting_approval` 是等待，不结算终态 usage、不把 pending 标未送达。
缺失或未知 status 也不推断为 completed。Runner 保留 Turn 的真实最终 status。

如何编写工作区插件见 [`extensions.md`](extensions.md)。下面只约束 runtime 边界。

## Middleware 与扩展 Hook

| 边界 | 所有者 | 可做什么 |
| --- | --- | --- |
| session_start/end、before/after_completion、after_compaction、after_tool_request/execution、on_error | Middleware | 受信任的 runtime 模块，修改完整 State；可 halt/interrupt。权限审批由 ToolGuard 的 after_tool_request 管理 |
| before_agent_start | HookPipeline → Turn | gate；只接纳 system_prompt/metadata，不能改 run 身份或工具授权 |
| context | HookPipeline → Turn | 每次 provider request 的 gate；改本次 messages/system_prompt，不改 durable State/transcript；halt 不发 provider 请求 |
| tool_call | HookPipeline → Turn | 可阻止工具或合并 args；不能改工具名/调用 ID；改写后仍检查 active set 与 workspace policy，不继承原调用的临时批准 |
| 已发生的 run/turn/tool 生命周期 | HookPipeline → Runner | readonly notification；halt 或 context 改写被忽略，后续观察者仍收到通知 |
| message_delta/thinking_delta | Runner persistence/projection | 跳过扩展 HookPipeline，避免每个 chunk 同步执行插件 |

capability 列表由 `Extension.Event.blockable?/1` 持有。`Event.known_events/0`
表示事件名可识别，不保证每个名字都已被 runtime 发出。
Hook 不是 OS 沙箱；加载进同一 BEAM 的 Elixir 扩展本身是受信任代码。
这些检查约束正常 Hook 返回值的能力，不是对恶意代码的隔离承诺。

## Snapshot、seq 与补历史

1. 先订阅 conversation topic，再取 Session snapshot，然后读 durable history。
2. snapshot 的 `(epoch, last_seq)` 是事件检查点，不能从有界 events 列表的最后
   一项猜测。每次 Session 启动有新 epoch；Session 单独重启时从 Runner/Queue
   Registry 恢复仍存活的 run 身份，不阻塞调用 Runner。
3. 同 epoch 内 `seq <= checkpoint` 丢弃；`seq == checkpoint + 1` 应用；更大
   或 epoch 改变则恢复 snapshot + history。另一 conversation 的 topic 永远不应用。
   Session 暂不可用时恢复返回错误，不把检查点降为 0。旧无 epoch 事件保留 live 兼容。
4. 补历史失败时不能清空已有历史或提交新的 snapshot 检查点。
5. 只恢复当前活动 run 的控制状态（审批、工具等）；不重放工具操作或文本 delta。
   `control_events` 单独保留最近 500 条非文本控制，不被 streaming delta 淘汰。
   这仍是有界缓存，不是无限事件日志；queued 由 Session/Queue 校准，idle 未消费
   的 steer/follow_up 从已加载 durable transcript 恢复为 undelivered，已消费或已
   删除消息不重建。向前补历史后使用同一校准，不能依赖 UI 当时在线。
   新候选 inbound 明确写 `consumption: pending`，注入后改为 consumed；旧历史缺少
   该标记时不猜测为未送达。native 无 Session 时可以显示历史，但首个带 epoch 的
   事件仍须恢复真实 snapshot + queue，不把临时的 0/nil 当已确认检查点。
6. transcript 与 Session seq 是两个独立时钟。文本在广播前已持久化，history
   可能比刚读的 snapshot 更新，不能用“有 assistant 就跳过所有流”或拼接旧 tail。
7. live message_delta 保留 `chunk` 兼容旧消费者，增加 `transcript_id`、`text_offset`
   （UTF-8 字节）和经过 ThinkingFilter 的 `text`。两端由 `Projection.text_patch/2`
   合并未见 suffix，忽略已覆盖的 overlap；缺 prefix 时恢复，不凭空补字。
8. Web/native 默认显示最新 100 条，历史页按时间正序，`before` 是 transcript ID，
   不是 Session seq。向前补页以 ID 去重；已删除 cursor 必须重新从最新窗口恢复。
   重连保留已加载窗口的条数，不把分页 cursor 当成运行时检查点。

旧 raw chunk 仍可 live 投影，但不作为恢复来源。手机正常文本直接更新同一个
durable transcript ID 的气泡，不再额外生成一条重复的 streaming row。

## 回归与设备验证

```sh
mix test --include e2e test/handbean/e2e/run_admission_test.exs test/handbean/e2e/extension_contract_test.exs
mix test test/feature/runtime_projection_feature_test.exs test/handbean/pubsub/projection_test.exs
# mobile/ 中执行；正常依赖锁同步后不需要 --no-deps-check
mix test test/handbean_probe/native_chat_test.exs test/handbean_probe/home_screen_test.exs
```

Mob.ScreenCase 只能证明宿主侧消息处理、节点树和 transcript，不是手机验收。
设备上按 `mobile-device-verification.md`：打开 >100 条的对话，补两页，运行中切换
对话再返回、批准工具、取消再发送。检查 native assigns 的 seq/run_id、durable
文本和单个气泡身份；另截屏确认“加载更早消息”入口及长文本布局。不得用 Web
页面或仅截图代替这些 native 状态检查。
