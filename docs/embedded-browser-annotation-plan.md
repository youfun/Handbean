# 内置浏览器标注：实施方案

日期：2026-10-10。状态：方案，尚未实现。

前置分析见 `docs/embedded-browser-annotation-analysis.md`。本文对那份文档第 10 节的未决项给出默认选择，并拆成可执行的阶段。

## 结论

桌面第一版用 Handbean 自己持有的 headless `agent-browser` 会话做画面，经 LiveView 推到工作台的一块新面板。标注、命中检测和截图都在 Elixir 侧完成，结果用现有的 `Composer.restore_draft/2` 追加进当前对话的草稿，不直接发送。

## 依据（本次核对过的事实）

- 本机 `agent-browser` 0.33 每个会话都自带 WebSocket stream（README「Streaming (Browser Preview)」一节）。
  - 服务端推送：`{"type":"frame","data":<base64 JPEG>,"metadata":{deviceWidth, deviceHeight, pageScaleFactor, offsetTop, scrollOffsetX, scrollOffsetY}}`。
  - 服务端接收：`input_mouse`（`eventType`、`x`、`y`、`button`、`clickCount`）、`input_keyboard`（`eventType`、`key`、`code`）、`input_touch`。
  - `stream status` 报告端口；`AGENT_BROWSER_STREAM_PORT` 可固定端口。
  - 另有 `--init-script` / `addinitscript`、`eval`、`viewport <w> <h>`、`screenshot`，以及 `--screenshot-format jpeg`、`--screenshot-quality`。
- `HandbeanWeb.WorkspaceLive.Composer.restore_draft/2` 已经是「追加文本 + 追加附件」：草稿非空时另起一行追加文本，附件拼到 `pending_attachments` 末尾。`MessageSubmission` 在发送失败时就用它把草稿放回去。
- `Composer.consume_images/2` 生成的上传附件形状是 `id`、`kind: "image"`、`mime_type`、`size_bytes`、`filename`、`storage_path`、`relative_path`、`url`。上限为 4 张、单张 5_000_000 字节。
- `Handbean.Browser.Cli` 支持注入 `:runner` / `:find_executable`，测试可以不启动 Chromium。
- `Handbean.Browser.Session` 按 conversation 管理 Agent 的 `agent-browser` 会话名，用 `Browser.Registry` 的 `"default"` slot 注册。
- `websockex` 已在 `mix.lock`，但只是传递依赖，`mix.exs` 里没有直接声明。依赖里没有图片处理库。

## 第 10 节未决项的默认选择

| 未决项 | 默认 | 理由 |
| --- | --- | --- |
| 桌面宿主 | `agent-browser` stream | 页面在独立 Chromium 里，与 LiveView 文档和 Handbean cookie 隔离；不用自建代理浏览器的安全边界 |
| 第一版含手机 | 不含 | 桌面 LiveView 就能走完「标注 → 当前对话草稿」 |
| 草稿已有文字 | 追加到末尾，另起一行 | 即 `restore_text` 现有行为 |
| 尚无当前对话 | Send 禁用并给一行提示 | 标注留在面板，不缓存、不在对话创建后补写 |
| 人和 Agent 共用浏览器会话 | 不共用 | 避免两边同时驱动同一页面；第一版跑通后再考虑加锁共享 |

## 总体结构

```text
WorkspaceLive 右侧 BrowserPanel（LiveComponent + JS hook BrowserSurface）
   │  地址栏 / 后退 / 前进 / 刷新 / Design / "{n} marked" / Clear / Send to composer
   │  canvas 画帧；序号标记与评论框画在 canvas 上方的 Handbean 自有 DOM 里
   ▼  pushEventTo（输入、标注、发送）        ▲ push_event("frame")
Handbean.Browser.UserSurface（每个 conversation 一个 GenServer）
   ├─ agent-browser 会话（headless，与 Agent 的 browser 会话分开）
   ├─ Handbean.Browser.StreamClient（WebSockex，连 127.0.0.1:<stream port>）
   └─ annotations 列表（只在内存，不持久化）
   ▼  Send 时
Handbean.BrowserAnnotation（纯函数：按字段重建 + format_prompt）
   ▼
Composer.restore_draft(socket, %{content: prompt, attachments: [截图]})
```

### 关键设计

1. **页面里不常驻 overlay。** pace 把覆盖层注入页面，是因为它的画面就是页面本身。这里画面是 canvas，高亮、序号和评论框放在 Handbean 自己的 DOM 里，页面脚本碰不到。Design mode 下点击不转发给页面，由 `UserSurface` 调一次 `eval` 做 `document.elementFromPoint` 命中检测，返回 selector、tag、截断后的可见文本、rect、`data-source` / `data-inspector-*`。
2. **标记跟随滚动。** 标记时记录页面坐标（视口 rect 加当时的 `scrollOffsetX/Y`）。显示时用每帧 metadata 的滚动量换算回视口坐标。pace 的「rect 不随滚动更新」限制在画面上可以去掉；回传给模型的 rect 仍是截图时刻的视口坐标。
3. **帧经服务端转发。** 浏览器端不直连 stream 端口：端口只在 Handbean 所在机器的 localhost 上，而且 Design mode 的点击拦截要发生在服务端。每个 surface 只保留最新一帧，按约 10fps 节流推给 LiveView。
4. **人用的会话与 Agent 的会话分开。** 会话名独立（例如 `u<hex>`），在 `Browser.Registry` 用 `"user"` slot 注册。Agent 的 `browser` 工具行为不变。
5. **不持久化 URL、标注和截图。** 打开面板从空白态开始，与 pace PRD 2026-09-17 的更新一致。截图只有进入草稿后，才作为普通上传附件落到对话 upload 目录。

## 阶段

### 阶段 0：验证 agent-browser 行为（约 1 天，不写产品代码）

用一个本地 loopback 静态页逐条确认，结果补进分析文档的事实节：

- [ ] `stream status --json` 能拿到端口；端口只绑 127.0.0.1。
- [ ] headless 下 `input_mouse` 点击、`input_keyboard` 输入真的生效；帧 metadata 的滚动量随滚动更新。
- [ ] 命中检测 `eval` 的返回大小与耗时。
- [ ] viewport 设为面板 CSS 尺寸时，JPEG 截图能稳定低于 5_000_000 字节。
- [ ] 页面能否自行跳转到 `file:`；能否触发下载；能否弹出摄像头、麦克风、通知、地理位置权限请求。这几项决定阶段 2 要补哪道闸。
- [ ] 一个 `X-Frame-Options: DENY` 的公网站点能正常打开（这是不用 iframe 的直接收益）。

### 阶段 1：载荷与草稿写入（不依赖真浏览器）

1. 新建 `lib/handbean/browser_annotation.ex`：
   - 结构对齐 pace core。元素：`index`（从 1 起）、`selector`、`tag`、`text`、`rect`、`source: %{file, line, column}`、`comment`。载荷：`url`、`title`、`viewport: %{width, height, dpr}`、`elements`、`captured_at`、`screenshot`。不承诺 React 组件名。
   - `from_untrusted/1`：逐字段重建，限制长度，丢弃未知字段。
   - `format_prompt/1`：有截图时不写 rect；无截图时每条多一行 rect；没写评论的标记写 `(no comment)`；所有字符串折成单行。
2. 从 `Composer.consume_images/2` 抽出「把一个本地文件登记成图片附件」的函数，返回与上传附件相同形状的 map。上传路径和标注截图共用它。
3. `WorkspaceLive` 增加 `handle_info({:browser_annotation_ready, conversation_id, revision, payload, screenshot_path})`：
   - `conversation_id` 不等于当前 `current_conversation_id`，或 `revision` 已过期，就丢弃。
   - `pending_attachments` 已有 4 张时只送文本，并把 `screenshot` 置为 false 再格式化。
   - 最后调用 `Composer.restore_draft/2`。
4. 测试（遵守 `AGENTS.md` 测试约定）：
   - `BrowserAnnotation` 是纯函数边界，允许单元测试，但先在测试文件顶部写失败清单（超长 selector、换行与 markdown 注入、缺字段、非 http(s) URL、负数或非数字 rect），再写实现。
   - Web 流程用 `HandbeanWeb.FeatureCase`，`UserSurface` 换成假 runner（沿用 `Cli` 的 `:runner` 注入方式）。断言：Send 后输入框里是固定 markdown，有一张待发附件；随后发送，`ConversationTranscriptStore` 中的 inbound entry 带这张附件。

### 阶段 2：UserSurface 与面板

1. `lib/handbean/browser/user_surface.ex`：
   - 挂在现有 `Handbean.Browser.Supervisor` 下，用 `Browser.Registry` 的 `"user"` slot 注册。
   - 命令：`navigate`、`back`、`forward`、`reload`、`set_viewport`、`set_design_mode`、`mark(x, y)`、`comment(index, text)`、`remove(index)`、`clear`、`capture`。
   - monitor 打开面板的 LiveView 进程；没有观察者 10 分钟后关闭 `agent-browser` 会话。
2. `lib/handbean/browser/stream_client.ex`：WebSockex 客户端，只与 `UserSurface` 通信。把 `websockex` 提升为 `mix.exs` 的直接依赖。
3. 导航闸：
   - 命令入口只放行 http/https。把 `Tool.Builtin.Browser.maybe_reject_url/2` 的判断挪进 `Handbean.Browser.Policy` 共用。
   - 页面自行跳转：以帧 metadata 或定期 `get url` 为准，scheme 不是 http(s) 就导航到 `about:blank`。
   - 下载、权限按阶段 0 的结果补。
4. `lib/handbean_web/live/workspace_live/browser_panel.ex` 与 `assets/js/hooks/browser_surface.js`：
   - hook 负责画帧、把指针坐标按 `deviceWidth` / `deviceHeight` 换算、mousemove 节流、用 `ResizeObserver` 把面板尺寸同步成 viewport。
   - 键盘只在 canvas 获得焦点且不在 Design mode 时转发。
   - 面板只在 `Handbean.Host.browser_backend() == :cli` 且找得到 `agent-browser` 时出现；找不到时复用 `Handbean.Browser.InstallPrompt`。

### 阶段 3：截图与发送

Send 的顺序：

1. `eval` 注入临时序号徽标：closed Shadow DOM，结构用 DOM API、样式用 CSSOM，按 selector 重新测量位置。
2. `screenshot --screenshot-format jpeg` 写入当前对话的 upload 目录。
3. `eval` 移除徽标。

降级规则：

- 徽标注入 500ms 无应答，就不再等，直接截图。
- 截图失败或超过 5_000_000 字节，只送文本，模板改走 rect。不丢掉整次标注。
- 每次 capture 带递增 `revision`；切换对话时作废在途结果。

### 阶段 4（可选）：手机

手机端用现有 `Handbean.Browser.WebViewSession` 的 JS 做命中检测，共用阶段 1 的载荷、`format_prompt/1` 与草稿写入。桌面版落地前不做。

## 安全

- 命中检测的 `eval` 跑在页面主世界，敌意页面可以伪造返回值。所有回传字段一律当不可信字符串：重建、截断、单行折叠，绝不作为 HTML 插进 LiveView。
- 页面无法调用 `Coordinator`，读不到 transcript，碰不到 LiveView socket。它唯一的输出是重建后的标注字段，而且只进草稿，由人决定是否发送。
- 浏览器是独立 Chromium，Handbean 工作台的 cookie 不会带给目标站，目标站的 cookie 也不会写进工作台。
- 导航白名单在「我们发起加载」和「页面自行跳转」两处都做。
- 下载、摄像头、麦克风、通知、地理位置默认不开（具体做法以阶段 0 结果为准）。

## 已知限制（第一版接受）

- 跨源 iframe 内的元素选不中，命中检测停在 iframe 元素本身。
- 页面自有 shadow DOM 内的元素，selector 停在 shadow root。
- Design mode 期间点击不转发给页面，不能先点开菜单再标注菜单项。
- 滚出视口的标记仍出现在文本里，但不在截图上。
- 帧是 JPEG 有损画面，经 LiveView 转发，远程访问工作台时会有延迟与带宽开销。
- 截图不在草稿之外持久化；重载页面前未发送的草稿行为与现有上传附件一致。

## 文件清单

| 文件 | 阶段 | 内容 |
| --- | --- | --- |
| `lib/handbean/browser_annotation.ex` | 1 | 载荷结构、`from_untrusted/1`、`format_prompt/1` |
| `test/handbean/browser_annotation_test.exs` | 1 | 失败清单 + 断言 |
| `lib/handbean_web/live/workspace_live/composer.ex` | 1 | 抽出本地文件登记为附件的函数 |
| `lib/handbean_web/live/workspace_live.ex` | 1–2 | `browser_annotation_ready` 处理、面板挂载 |
| `test/feature/browser_annotation_feature_test.exs` | 1 | FeatureCase 端到端 |
| `lib/handbean/browser/user_surface.ex` | 2 | 人用浏览器会话 owner |
| `lib/handbean/browser/stream_client.ex` | 2 | WebSockex stream 客户端 |
| `lib/handbean/browser/policy.ex` | 2 | 共用 URL 白名单 |
| `lib/handbean_web/live/workspace_live/browser_panel.ex` | 2 | 面板 LiveComponent |
| `assets/js/hooks/browser_surface.js` | 2 | 画帧、输入转发、标记层 |
| `mix.exs` | 2 | `websockex` 提升为直接依赖 |
| `docs/embedded-browser-annotation-analysis.md` | 0 | 补阶段 0 验证结果 |
