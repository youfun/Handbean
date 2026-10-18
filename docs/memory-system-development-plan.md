# Handbean 记忆系统收口与反思开发计划

## 目标

Handbean 的记忆系统采用一个 SQLite 数据库、两个持久事实域和一个运行时投影：

- 会话轨迹（`conversation_entries`、`conversation_runs`、`conversation_turns`、
  compaction checkpoint）记录发生过什么。
- 语义记忆（`engrams`、`synapses`、`engrams_fts`）记录跨任务仍值得复用的事实、
  规则、偏好和模式。
- 模型上下文按当前作用域和任务实时投影，不形成第三套持久状态。

本计划只实现 Handbean 当前的本机、单用户、工作区隔离场景，不复制 Mem0、
Mastra、Letta、Pi 或 nanobot 面向其他场景的字段和存储结构。

## 长期约束

- 所有记忆读写和关系操作由 `Handbean.Memory.MemoryStore` 统一校验作用域。
- workspace 身份缺失、空白或不匹配时 fail closed。
- `local_only` 禁止读取、写入或修改 global 记忆。
- workspace 记忆只能与同一 workspace 的记忆建立关系；global 只能与 global 建立关系。
- 原始消息、工具结果和运行轨迹只有 conversation trajectory 一个事实源。
- 不保留 JSONL observation 兼容读取、双写、启动迁移或自动导入。
- 如需迁移现有本地 JSONL，只使用一次性脚本；脚本不进入产品运行时调用链。
- 自动反思只能生成可审核的短期候选，不能直接创建长期记忆、覆盖或删除记忆。
- 不新增 embedding、entity、confidence、candidate、observation 或 reflection 表；
  后续只有在真实指标证明需要时再设计。

## 目标架构

```text
conversation trajectory
        │
        ├── current conversation context
        └── model_compaction checkpoint
                         │
                         ▼
                 optional Reflector
                         │
                         ▼
              short-term engram candidate
                         │
                 explicit reinforce
                         ▼
                  long-term memory
                         │
             ┌───────────┴───────────┐
             ▼                       ▼
    bounded rules/preferences   query-driven recall
             └───────────┬───────────┘
                         ▼
                   prompt projection
```

## 实施顺序与检查项

### 阶段 0：基线与计划

- [x] 核对现有 engram、synapse、FTS、observation、conversation trajectory 和 compaction owner。
- [x] 调研 Mem0、Mastra、Letta、Pi、nanobot 的产品场景，拒绝按字段清单照搬。
- [x] 由顾问模型复审架构、作用域边界和阶段顺序。
- [x] 明确旧记忆迁移只允许一次性脚本，不进入业务代码。
- [x] 记录修改前相关测试基线：`mix test test/handbean/memory test/handbean_web/live/settings_live_test.exs`，153 passed。

### 阶段 1A：统一作用域 owner

- [x] `MemoryStore.learn/3` 从显式 scope opts 构造身份 metadata；非法或缺失身份拒绝写入。
- [x] `MemoryStore.recall/2` 保持 workspace/global/privacy fail-closed 语义。
- [x] `MemoryStore.reinforce/2` 按作用域原子读取并强化，不接受调用端先 `Repo.get`。
- [x] `MemoryStore.associate/4` 同时校验两端，并禁止 workspace↔global 和跨 workspace 关系。
- [x] 增加 scoped `MemoryStore.update/3` 与 `MemoryStore.delete/2`。
- [x] recall 不再无条件 preload 未过滤的 synapse 图；设置页只加载当前安全关系。
- [x] 支持可选 `ttl_hours`，普通短期记忆默认 24h，reflection candidate 使用 168h。
- [x] 所有上述行为有 store 层隔离、缺身份、`local_only` 和关系边界回归测试。

### 阶段 1B：记忆工具与策略

- [x] `mem_learn` 只传 scope opts，不再自行拼接身份 metadata。
- [x] `mem_reinforce` 调用 scoped store API，删除本地 `accessible?`。
- [x] `mem_associate` 调用 scoped store API，删除直接 `Repo.get` 和本地 `accessible?`。
- [x] 新增 `mem_update`，用于用户明确纠正已有记忆。
- [x] 新增 `mem_forget`，用于用户明确撤销或删除已有记忆。
- [x] 注册两个新工具并更新 Memory PromptPolicy。
- [x] 工具级测试覆盖同 workspace、global、`local_only`、缺身份、跨 workspace 和错误 ID。

### 阶段 1C：上下文投影

- [x] Bucket A：注入当前有效作用域内的长期 `rule` / `preference`，workspace 优先于 global。
- [x] Bucket A 同时受最大条数和 token/字符预算限制。
- [x] Bucket B：对其余所有 active engrams 做查询召回，并排除 Bucket A 已注入 ID。
- [x] 短期 `rule` / `preference` 仍可通过 Bucket B 召回。
- [x] 原始工具执行和 turn completion observation 不再注入 prompt。
- [x] 测试无关键词规则、查询相关事实、短期偏好、预算、去重和跨工作区隔离。

### 阶段 1D：清理 JSONL observation

- [x] 从 middleware wiring 移除 after-tool / after-completion observation writer。
- [x] 删除 `ObservationStore`、`Observation` 和对应中间件。
- [x] 删除未实现且与 Compactor 重复的 Observer 配置和设置字段。
- [x] 删除对应测试，不添加兼容 shim、双写或启动迁移。
- [x] 备份 `~/.handbean_dev/handbean_dev.db` 与旧 observation JSONL；在线备份、quick/FK 与 SHA-256 校验通过，未添加迁移脚本。

### 阶段 1E：Web 与 mobile 管理投影

- [x] Web 设置页支持 promote、edit、delete。
- [x] Web 设置页显示 scope 和 source。
- [x] 所有 UI mutation 通过 scoped `MemoryStore`，不直接访问 Repo。
- [x] native memory projection 复用同一 owner，提供与平台交互能力相符的 promote/edit/delete。
- [x] Web LiveView 行为测试覆盖操作成功、失败、筛选刷新和隔离。
- [x] mobile host tests 覆盖状态、事件和持久结果；不把 host tests 声称为设备验收。
- [x] 真实 Web 页面检查列表、编辑态、窄屏、删除确认和错误态，并保存截图证据。
- [ ] 原生界面若有视觉变化，检查代表性状态；本轮未运行模拟器或真机。

### 阶段 2：compaction-driven Reflector

- [x] 只保留一个 Reflector，不实现重复的 Observer LLM 阶段。
- [x] 自动触发点只在成功持久化 compaction checkpoint 后；另提供显式手动触发入口。
- [x] 输入仅为 checkpoint summary 和当前 active scoped engrams，不重复发送原始覆盖消息。
- [x] 输出使用严格结构化 `candidate | ignore` 协议。
- [x] candidate 经过 `Policy.validate_candidate_memory/1`。
- [x] 同 scope、同 kind、规范化内容完全相同的候选跳过。
- [x] candidate 写为 `short_term: true`、168h TTL，metadata 记录 source、conversation 和 checkpoint。
- [x] Reflector 不自动 reinforce、update、delete、associate 或写 global。
- [x] 反思结果作为 internal conversation entry 持久化，以 checkpoint ID 做审计和幂等。
- [x] provider 失败、格式错误、重复触发和取消不会破坏主会话或产生半写状态。
- [x] Reflector 默认可关闭；关闭时基础显式记忆工具和上下文投影仍正常工作。

### 阶段 3：验证与收尾

- [x] `mix format --check-formatted`（仅本任务文件）。
- [x] `mix compile --warnings-as-errors`。
- [x] 运行 memory store、tool、policy、isolation、usefulness 和 observational/reflector 最小测试集。
- [x] 运行相关 LiveView 测试。
- [ ] 运行根项目 `mix test`：相关测试与 Runner/Compactor 全部通过；全仓沙箱运行因系统工具/当前 workspace 污染终止，不作为通过结论。
- [x] 在 `mobile/` 运行相关 host tests 和 `mix test`。
- [x] 明确报告未运行的 simulator、Android 真机和 iOS 真机层级。
- [x] 核对 git diff，只提交本任务文件，不覆盖工作区已有改动。
- [x] 回写本清单最终状态、验证命令和已知未覆盖项。

### 阶段 4：开发环境真实模型验收

- [x] 在备份完成后启动 `PORT=5002 mix phx.server`。
- [x] 只使用 `default` 工作区（`~/.handbean_dev/.handbean/workspace`）和唯一测试标记。
- [x] 真实 LLM 触发并核对 `mem_learn`、`mem_recall`、`mem_update`、`mem_reinforce`。
- [x] 真实 LLM 触发并核对 `mem_associate`、`mem_forget`。
- [x] 准备持久化 compaction checkpoint，真实触发 `mem_reflect` 并核对 168h candidate 与 internal audit。
- [x] 新会话验证长期规则/偏好无关键词投影，事实按查询自动召回。
- [x] 清理带唯一标记的测试记忆、关联、测试对话和临时 checkpoint；保留脱敏验证记录。
- [x] Web 桌面与 390px 窄屏截图检查记忆卡片、编辑态、删除确认和反思设置。

### 阶段 5：顾问优化复审

- [x] 修正 PromptPolicy 与 `mem_associate` 实际关系枚举不一致。
- [x] 移除 associate 的 SQLite deferred read→write 事务升级，并把 busy timeout 提高到 5 秒；保留 `synchronous: full` 耐久性。
- [x] 禁止 update、reinforce 和 associate 使用已过期的短期记忆，delete 仍可清理过期项。
- [x] 自动投影同时使用 head/tail token、20% floor 和最多 3 个必需命中；显式 `mem_recall` 默认语义不变。
- [x] `mem_learn` 自动附加可信 conversation/run provenance metadata。
- [x] 明确延期跨 Session execution search、synapse 图召回、embedding 和 provenance schema 列。

## 验收标准

1. 用户只说“修失败测试”时，作用域内的长期规则和偏好仍能进入上下文。
2. 不相关的事实和上下文不会常驻占用 prompt。
3. 短期规则和偏好可以按查询召回，但不会被当作已确认的常驻规则。
4. workspace A 的记忆不能在 workspace B 被读取、强化、编辑、删除或建立关系。
5. 缺 workspace identity 时所有 workspace 操作 fail closed。
6. `local_only` 下不存在 global 读写或修改路径。
7. 工具日志和 completion preview 不再作为记忆直接注入。
8. 用户和 Agent 都能纠正、撤销错误记忆。
9. Reflector 只能创建有来源、可审计、会过期的候选。
10. 不存在运行时 JSONL 兼容、迁移或第二套 observation 状态。

## 后续指标（不阻塞本次开发）

- 召回结果被实际使用的比例。
- 规则/偏好常驻投影的 prompt token 成本。
- reflection candidate 的 promote、delete、expire 比例。
- 同 scope 重复候选比例。
- 关键词召回的人工确认漏召回率。
- 跨 workspace 泄漏率必须持续为 0。

只有这些指标证明关键词召回或 metadata 查询已经不足时，才重新评估向量检索、
表达式索引或一等 provenance 字段。
