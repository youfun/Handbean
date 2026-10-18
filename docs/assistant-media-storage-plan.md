# Assistant 媒体发布与存储方案

状态：Phase 1 已实施并通过聚焦测试、E2E、Web 视觉及 mobile host 验收；Phase 2–3 待实施。

## 1. 目标

实施前，Handbean 的 Agent 可以读取、截图或生成图片，但不能把这些图片作为 assistant
消息附件直接发到对话中，只能在回复中写出本地路径，例如：

```text
/path/to/workspace/.handbean/new-conversation-picker.png
```

浏览器无法把任意服务器文件路径安全地当作图片 URL；Windows、Linux、macOS 的路径
格式也不同。目标是建立一套跨渠道、跨平台并可扩展到 S3 的媒体发布机制：

- Agent 能显式把工作区图片发布到当前对话。
- WebUI、macOS WKWebView、Windows 和 Linux 使用同一消息协议与内容 URL。
- transcript 不保存绝对路径、Base64、对象存储 key 或临时签名 URL。
- 第一版使用本地存储，但领域协议和数据库不依赖本地文件系统。
- 后续增加 S3 backend 时，不修改 transcript 格式和聊天 UI。
- 媒体发布必须具备路径隔离、MIME 校验、大小限制、幂等和崩溃恢复。

## 2. 实施前的代码事实

### 2.1 用户输入附件

用户上传的附件已经具备以下能力：

- 工作区对话存到 `.handbean/uploads/<conversation_id>/`。
- free chat 存到 Handbean 数据目录。
- user transcript entry 保存 `attachments` 描述。
- Web 时间线在 `user_msg` 分支渲染图片缩略图和文件链接。
- `/uploads/:conversation_id/:file` 将受控文件映射为 HTTP 响应。

这套逻辑只覆盖用户输入，而且仍与工作区路径和本地文件系统耦合。

### 2.2 Assistant 消息

assistant transcript entry 当前只保存并流式渲染 Markdown 文本。时间线没有 assistant
附件区域；如果 Agent 只返回本地路径，该路径只是普通文本或代码文本。

### 2.3 Tool 图片观察

`Handbean.Tool.Images` 已经把工具返回的图片存为不透明引用：

- 图片体不进入 transcript。
- transcript 保存 `ref`、MIME、SHA-256 和大小。
- provider 调用边界才重新加载并编码图片。
- 历史只保留有限数量的工具图片观察。

它解决的是“模型观察工具图片”，不是“用户可见的 assistant 媒体”。第一阶段不迁移
这条关键多模态链路。

### 2.4 桌面版本

macOS 原生应用只是使用 `WKWebView` 打开内置 Phoenix 服务。Windows、Linux 和 macOS
WebUI 发行包也运行同一套 Phoenix/LiveView。因此聊天图片展示应由共享 runtime 和 Web
路由完成，不应分别实现平台专用图片协议。

## 3. 核心设计原则

### 3.1 路径不是媒体身份

本地路径只在导入时短暂使用。导入完成后，媒体通过不透明 `media_id` 标识：

```text
Agent 或工具产生文件
        ↓
publish_media 读取并验证文件字节
        ↓
Handbean.Media.Backend 保存不可变对象
        ↓
conversation_media 保存私有存储信息
        ↓
assistant transcript entry 只引用 media_id
        ↓
Web 通过 /media/:conversation_id/:media_id/content 显示
```

不存在把 `/Users/...` 或 `C:\Users\...` 字符串直接改写为 URL 的步骤。

### 3.2 持久事实、运行态和 UI projection 分离

- 持久事实：媒体 ID、所属对话、MIME、大小、哈希、存储 backend 和状态。
- 运行态：工具调用正在上传或等待 `tool_end` 提交。
- UI projection：Web 根据 `media_id` 生成内容路由，渲染缩略图和灯箱。

### 3.3 Transcript 保持跨渠道

transcript 服务于 Web、移动端、CLI、webhook 和未来渠道，因此不保存 Phoenix URL。
Web 路由是在呈现层临时派生的，不是对话的持久业务事实。

### 3.4 Backend 由每个对象记录

每个媒体对象都保存创建时使用的 backend 标识。以后把默认写入 backend 从 Local 改为
S3 时，旧对象仍由 Local 读取，新对象由 S3 读取。

## 4. Media 领域与 Backend 协议

新增独立领域：

```text
Handbean.Media
Handbean.Media.Backend
Handbean.Media.Backends.Local
```

未来增加：

```text
Handbean.Media.Backends.S3
```

不要把用户可见媒体放入 `Handbean.ConversationArtifacts`。后者拥有 saved tool input、
change snapshot 和 subagent descriptor 等内部恢复文件，生命周期和权限语义不同。

### 4.1 Backend 回调

第一版建议采用以下形状：

```elixir
@callback put(storage_key, binary, metadata) ::
            :ok | {:error, term()}

@callback delivery(storage_key, metadata) ::
            {:ok, {:send_file, absolute_path}}
            | {:ok, {:redirect, signed_url}}
            | {:error, term()}

@callback delete(storage_key, metadata) ::
            :ok | {:error, term()}
```

第一版图片上限为 5 MB。导入层从一个已验证的文件句柄读取受限 binary，再把同一份字节
交给 backend。这样 Local 和 S3 都不需要重新打开不可信源路径。以后支持视频或大型文件
时，再增加 multipart/stream 接口，不改变消息协议。

backend 标识必须通过固定注册表映射到模块，不能把数据库字符串动态转成任意模块。

### 4.2 Local backend

建议存储目录：

```text
<Handbean data dir>/.handbean/media/<conversation-id>/<media-id>.<ext>
```

Unix 上目录权限为 `0700`，文件权限为 `0600`。与 `Handbean.Tool.Images` 一致，
Local 根目录需要先对 `Handbean.Host.data_dir()` 本身执行 `resolve_symlink`，以兼容 macOS
的 `/var` 系统别名；与此同时，必须严格禁止 `.handbean/media` 下属子目录和文件为符号
链接。数据库只保存逻辑 key：

```text
<conversation-id>/<media-id>.png
```

不得保存操作系统绝对路径。逻辑 key 使用平台无关格式，Local backend 再将逻辑段转换为
当前操作系统路径。

### 4.3 S3 backend

未来 S3 backend 使用相同逻辑 key。`delivery/2` 返回短期预签名 URL：

```elixir
{:ok, {:redirect, presigned_url}}
```

页面仍引用稳定的 Handbean URL。预签名 URL 不进入 transcript、模型上下文或长期缓存；
过期后浏览器重新请求 Handbean URL，即可获得新签名。

## 5. 数据模型

新增 `conversation_media` 表。

| 字段 | 说明 |
| --- | --- |
| `id` | 对外公开的不透明媒体 ID |
| `conversation_id` | 所属对话 |
| `producing_entry_id` | 最终关联的 assistant transcript entry；staged 时为空 |
| `producer_tool_call_id` | 创建媒体的工具调用，用于关联和幂等 |
| `purpose` | 第一版为 `published`；以后可扩展 `tool_observation`、`user_upload` |
| `backend` | `local`，未来可为 `s3` |
| `storage_key` | backend 私有对象 key，不进入 transcript |
| `mime_type` | 通过文件头验证的规范 MIME |
| `filename` | 用户可见名称 |
| `size_bytes` | 实际字节数 |
| `sha256` | 完整性校验和 ETag |
| `status` | `staged`、`ready`、`pending_delete` |
| `inserted_at` / `updated_at` | 生命周期管理 |

关键唯一约束：

```text
(conversation_id, producer_tool_call_id, sha256)
```

同一个工具调用重试并发布相同内容时，返回已有 staged/ready 记录，不重复上传或发图。

专用表是必要的，不能只从 transcript 推导：

- 内容路由需要按 ID 常数时间查找存储位置。
- backend、storage key 和删除状态不应泄露到 transcript。
- staged 和 pending-delete 对象需要独立 GC。
- S3 孤儿回收不能依赖全 bucket 扫描。

## 6. Transcript 附件协议

assistant 媒体 entry 示例：

```json
{
  "id": "msg-media-tool-call-123",
  "role": "assistant",
  "content_type": "assistant_msg",
  "message_type": "assistant",
  "direction": "outbound",
  "content": "",
  "phase": "commentary",
  "status": "completed",
  "tool_call_id": "tool-call-123",
  "attachments": [
    {
      "media_id": "9ba3...",
      "conversation_id": "conv-123",
      "kind": "image",
      "mime_type": "image/png",
      "filename": "new-conversation-picker.png",
      "size_bytes": 238104,
      "sha256": "...",
      "source": "agent"
    }
  ]
}
```

不得持久化以下字段：

```text
url
storage_key
storage_path
absolute path
backend URL
presigned URL
Base64 body
```

空内容 assistant entry 是 UI-only 媒体消息。现有历史恢复逻辑只重放非空 assistant
文本，因此它不会把媒体字节或占位消息重新喂给模型。

## 7. Agent 工具：publish_media

工具命名为 `publish_media`，避免与内部 `ConversationArtifacts` 和 Tool Result
`artifacts` 概念冲突。

第一版输入：

```json
{
  "path": ".handbean/new-conversation-picker.png",
  "filename": "new-conversation-picker.png"
}
```

第一版每次调用只发布一个文件。多文件可由 Agent 多次调用或在协议稳定后扩展。

### 7.1 授权与允许根目录

允许：

- 相对于当前 `working_directory` 的路径。
- 位于允许根目录内的绝对路径；允许根目录仅包括当前 `working_directory` 和 runtime
  明确注册的工具输出目录，例如 Browser 截图临时目录。

禁止：

- 因为处于 `yolo` 模式就扩大允许根目录。
- 指向允许根目录之外的绝对路径或使用 `..` 越界的路径。
- 符号链接逃逸。
- 目录、socket、设备文件等非普通文件。
- 第一版不支持的格式，包括 SVG。
- 超过图片大小或批次限制的文件。
- 仅凭扩展名认定 MIME。

free chat 没有工作区时，只允许明确注册的工具输出根目录。

绝对路径只用于执行边界内的授权和读取，不能原样进入 transcript、PubSub 或日志。
`publish_media` 的 tool input projection 必须在 `tool_start` 发出前完成规范化：工作区文件记录
为工作区相对路径，已注册工具输出记录为不透明 source ref 或不含根目录的展示名；工具执行
仍使用仅存在于当前调用上下文中的已授权原始路径。

### 7.2 单文件句柄读取

必须避免“先校验文件，再按路径重新打开复制”的 TOCTOU 竞态：

1. 展开输入路径。
2. 校验展开路径和解析符号链接后的路径都在允许根目录。
3. `lstat` 确认是普通文件。
4. 只打开一次文件句柄。
5. 从该句柄限量读取。
6. 用实际字节验证 PNG/JPEG/GIF/WebP magic/MIME。
7. 对同一份字节计算 SHA-256。
8. 把同一份字节交给 Media backend。

### 7.3 Staging

工具执行顺序：

1. 根据幂等键查询已有媒体。
2. backend 保存不可变对象。
3. 插入 `conversation_media(status: "staged")`。
4. 如果 DB 插入失败，立即尝试 `Backend.delete/2` 补偿。
5. Tool Result 只返回公共 `published_media` 描述，不携带 backend 或 storage key。

staged 记录必须在工具返回前落库。否则进程在 backend 写入后、`tool_end` 前崩溃时，
Local 尚可扫描目录，S3 却无法安全识别孤儿对象。

## 8. 运行事件与原子提交

不新增独立的 `media_published` 事件。它会造成 tool 和媒体消息的双写顺序问题，并要求
Runner、CLI、恢复和 UI projection 再维护一套事件语义。

扩展现有结构：

- `Handbean.Agent.Tool.Result` 增加 `published_media`。
- `ResultContract` 对其做有界、公共字段投影。
- `tool_end` payload 增加 `published_media`。
- `tool_start` 对外 payload 和持久化 input 使用去绝对路径的公共投影；原始已授权路径只在
  工具执行上下文中存在。
- 正常执行、审批后恢复、嵌套工具等所有 tool-end 生产路径收敛到共享 builder。

### 8.1 Transcript store 原子接口

在 `Handbean.ConversationTranscriptStore` 增加可选 callback：

```elixir
complete_tool_call(
  conversation_id,
  tool_entry,
  media_entry,
  media_ids,
  opts
)
```

SQLite 实现在一个 `Repo.transaction/1` 中：

1. upsert tool transcript entry；
2. 校验媒体 ID、对话 ID、tool call ID 均匹配；
3. 将对应媒体从 `staged` 转为 `ready`；
4. 设置 `producing_entry_id`；
5. upsert 确定 ID 的 assistant 媒体 entry：`msg-media-<tool_use_id>`。

如果 tool 失败，不把媒体转为 ready；staged 对象留给 GC 清理。

`TranscriptPersistence` 只做 capability dispatch，不直接依赖 Ecto：

- production SQLite store 使用 `complete_tool_call/5` 获得单事务 ACID。
- 自定义或测试 transcript store 使用顺序 fallback。

## 9. Web 内容 URL

新增浏览器路由：

```text
GET /media/:conversation_id/:media_id/content
```

处理流程：

1. 通过现有 `HandbeanWeb.Access`。
2. 查询 `conversation_media`。
3. 校验 URL 中的 conversation ID 与记录一致。
4. 校验媒体状态为 `ready`。
5. 通过固定 backend 注册表解析对象记录中的 backend。
6. 调用 `delivery/2`。

### 9.1 URL 不持久化

Web 呈现层根据 `media_id + conversation_id` 临时生成路由。现有
`Composer.attachment_url/1` 可增加媒体描述分支，使实时事件和历史重载继续调用同一个
函数。实现时应使用 Phoenix Verified Routes 或等价的安全路径构造，不手工拼接未经验证
的路径段。

### 9.2 Local 响应

Local backend 返回经再次校验的普通文件路径，controller 使用 `send_file`，并设置：

```text
Content-Type: image/png
X-Content-Type-Options: nosniff
Content-Disposition: inline; filename="..."; filename*=UTF-8''...
Cache-Control: private, max-age=31536000, immutable
ETag: "<sha256>"
```

`filename` 写入 `Content-Disposition` 前必须过滤控制字符和双引号，并提供安全的 ASCII
fallback 与 RFC 5987 `filename*` 编码。媒体不可变，因此 Local 响应可以长期缓存。需要
支持 `If-None-Match`，命中时返回 304。

### 9.3 S3 响应

S3 backend 返回短期预签名地址，controller 使用 302/307 重定向。重定向响应必须使用：

```text
Cache-Control: private, no-store
```

不能把重定向缓存一年，否则浏览器会保留已经过期的签名 URL。

## 10. 聊天 UI

当前附件画廊只存在于 user message 分支。应抽出角色无关组件：

- user 和 assistant 共用附件画廊；第一阶段 assistant 只发布栅格图片，现有 user 文件
  附件继续使用文件卡片及下载行为。
- assistant `content` 为空时，不渲染空白气泡、复制按钮或 Markdown hook。
- assistant 媒体 entry 保持在主聊天流，不藏进可能折叠的 tool card。
- live `tool_end` projection 使用与 SQLite 相同的确定 entry ID，避免刷新前后重复。

纯视觉部分必须在真实 Web 页面检查宽屏、窄屏、单图、多图和历史重载状态，并截图验收。

## 11. 部署场景

### 11.1 WebUI 和 Agent runtime 在同一台机器

Agent 路径属于服务器本机。`publish_media` 导入文件，浏览器通过 HTTP 内容路由显示。
这是当前 macOS、Windows 和 Linux 自包含发行包的主要场景。

### 11.2 浏览器远程访问 Handbean 服务器

浏览器所在电脑的 `C:\Users\me\picture.png` 对服务器没有意义，不能转换成 URL。用户
本机文件必须先通过浏览器上传。Agent 在服务器工作区内生成的文件仍可正常发布。

### 11.3 Agent worker 与 Web 服务器分离

worker 不能只发送本地路径。它必须读取并验证字节，然后上传到共享 Media backend，通常
是 S3，再传递 `media_id`。这也是 backend 接收字节而不是源路径的原因。

### 11.4 macOS 原生应用

macOS 应用的 `WKWebView` 加载同源 Phoenix URL，因此无需 Swift 图片渲染协议。Finder、
Explorer 或系统“另存为”属于可选 host 能力，不影响聊天媒体协议。

## 12. 生命周期与清理

- `staged`：backend 已写入，但尚未与完成的 tool call 和 assistant entry 原子关联。
- `ready`：可被内容路由读取。
- `pending_delete`：业务引用已移除，等待 backend 删除。

GC 负责：

- 清理超过 TTL 且对应 run 已终止的 staged 对象。
- 重试 pending-delete 对象。
- backend 删除成功后删除媒体记录，或保留短期 tombstone 防止重放复活。

对话 archive 是可恢复操作，不删除媒体。只有永久删除对话或明确的保留策略才能进入
pending-delete。S3 删除不放进 SQLite 事务，采用 outbox/状态机式最终一致性。

## 13. 分阶段实施

### 第一阶段：Agent 可见媒体发布

- 新增 `conversation_media` 表和 schema。
- 新增 `Handbean.Media`、backend behavior 和 Local backend。
- 新增 `publish_media` 工具。
- 扩展 Tool Result、ResultContract 和全部 tool-end payload 路径。
- 新增 transcript store 原子 `complete_tool_call/5`。
- 新增 `/media/.../content` controller。
- assistant 使用共享附件画廊，修复空消息气泡。
- 增加 staged/pending-delete GC。
- 用 fake backend 验证 S3 重定向契约，但不引入真实 S3 SDK。

### 第二阶段：真实 S3 backend

- 配置 S3 endpoint、bucket、region 和凭据边界。
- 实现上传、删除和短期预签名。
- 验证默认 backend 切换后旧 Local 对象仍可读取。
- 验证失败、超时、重试、孤儿回收和多实例部署。

### 第三阶段：统一现有媒体字节存储

按风险顺序迁移：

1. 用户上传 `Handbean.Uploads`，并保留 `/uploads/:conversation_id/:file` 作为存量历史
   记录的只读兼容路由。
2. `Handbean.Tool.Images` 的字节所有权。

即使共用 Media backend，也保留不同目的和保留策略：

- `published`：用户可见，随对话历史保留。
- `user_upload`：用户输入。
- `tool_observation`：模型观察，受工具图片历史预算约束。

内部 `ConversationArtifacts` 不迁移。

## 14. 测试与验收

### 14.1 Media 与 backend 合约

- Local put/delivery/delete。
- fake S3 redirect backend。
- backend 按对象记录解析，切换默认 backend 不影响旧对象。
- Windows-safe 逻辑 key 和路径转换。
- 不允许数据库 backend 字符串加载任意模块。

### 14.2 安全

- 工作区内普通文件可发布。
- 允许根目录内的绝对路径可执行，但其原值不会进入 transcript、PubSub 或日志；
  `tool_start` 只包含工作区相对路径或不透明受控 source ref。
- 允许根目录之外的绝对路径、使用 `..` 越界的路径、符号链接逃逸、目录和设备文件
  被拒绝。
- yolo 不扩大媒体发布根目录。
- MIME 与扩展名不一致时拒绝。
- 拒绝 SVG 和超限文件。
- 单文件句柄读取覆盖文件替换竞态。
- 其他 conversation ID 无法读取媒体。
- transcript、事件和日志无绝对路径、Base64、storage key 和预签名 URL。

### 14.3 一致性与恢复

- backend 成功、staged DB 插入失败时执行补偿删除。
- tool-end 事务失败时媒体不变成 ready。
- 同一个 tool call 重放不产生重复媒体或重复 assistant entry。
- BEAM 在 backend put 后崩溃时，staged 记录可被 GC 发现。
- pending-delete 可重试。
- tool 失败时不会发布可见媒体。

### 14.4 用户可见行为

- Agent 发布 PNG/JPEG/GIF/WebP 后，聊天直接显示图片，而不是路径文本。
- 实时流、刷新页面和应用重启后显示一致。
- 单次调用发图、同一轮多次调用发多图、纯媒体 assistant entry 与后续文本 assistant
  entry 的顺序展示均正确，且不破坏 user 消息原有的多图和图文混排。
- 灯箱、下载和键盘操作可用。
- Web、macOS WKWebView、Windows 和 Linux 使用相同内容 URL。
- 现有用户上传和 Tool.Images/provider 历史测试保持通过。

## 15. 关键架构决策与编码前检查清单

### 15.1 已选方案

- 使用独立 `Handbean.Media` 领域。
- 使用专用 `conversation_media` 表，而不是从 transcript 扫描推导。
- 每个对象记录 backend 和 storage key。
- Web 使用稳定 Handbean 内容 URL。
- Local 使用 `send_file`，S3 使用短期签名重定向。
- assistant 媒体用独立、空文本的 assistant transcript entry 表达。
- 第一阶段暂不迁移 Tool.Images 和用户上传。
- 正常执行、审批后恢复和嵌套工具三条 `tool_end` 路径共用统一 payload builder；
  `Executor.nested_end_payload/4` 也必须携带 `published_media`。

### 15.2 被否决的替代方案

不单独发送 `media_published` 事件。公共媒体描述放到既有 `tool_end`，由 transcript owner
统一提交，避免 tool 与媒体消息产生双写顺序问题。

不把 staging metadata 只留在 Tool Result 内存中。backend put 后、工具返回前必须插入
staged 记录，以支持 S3 崩溃恢复和上传幂等。

不采用“先校验、再按路径重新复制文件”。导入使用单一文件句柄，并对同一份字节完成
MIME 验证、哈希和 backend 写入，以避免 TOCTOU。

不在附件描述中持久化稳定相对 URL。transcript 保持跨渠道，只保存媒体 ID 和公共元数据，
Web presentation 根据媒体 ID 派生 URL。

不让纯媒体 assistant entry 继续走无条件 Markdown 气泡。实现时同时修复空白气泡、复制
按钮和 `StreamingMarkdown` hook。

### 15.3 编码前 P0 检查清单

1. backend put 后建立 staged DB 记录。
2. tool-end 的 tool entry、ready 转换和 assistant media entry 在同一 SQLite 事务完成。
3. 不新增第二条媒体事件。
4. 正常执行、审批后恢复和嵌套工具三条 `tool_end` 路径都传递 `published_media`。
5. `publish_media` 的 `tool_start` input 在持久化和广播前移除绝对路径，原始已授权路径
   只存在于工具执行上下文。
6. 导入文件使用单一文件句柄，禁止校验后按路径重新复制。
7. transcript 保持跨渠道，不保存 Web URL 或私有存储信息。
8. assistant 附件渲染与空内容消息行为同时完成。

## 16. 非目标

第一阶段不包含：

- 真实 S3 SDK 与云凭据配置。
- 视频、音频和超大文件 multipart 上传。
- 对已有 user uploads 的立即迁移。
- 对 Tool.Images provider wire path 的立即迁移。
- Finder、Explorer 或系统分享菜单等原生增强。
- 将任意操作系统路径暴露成静态 HTTP 文件服务。
