# 内置浏览器与标注回传：对照 pace 的分析

日期：2026-10-10。状态：只分析，没有实现。

用户要求基于 [bubbleptr/pace](https://github.com/bubbleptr/pace) 做「内置浏览器 + 标注发到当前对话」。随后说明附件截图来自另一个 agent，并要求先写分析、不改功能代码。

## 怎么读

本文分成两块。

- **事实**：某份文件、某次 GitHub 文件树、或本仓库源码里写明的内容。引用处标了路径。文档之间互相矛盾时，两份都记下，不在事实节里裁定谁代表当前运行行为。
- **推理**：对照这些事实之后的判断、缺口和未拍板的选择。推理不是 pace 的决策，也不是 Handbean 已有行为。

## 读过什么

pace（`main`，通过 GitHub API 读取，不是本地 clone）：

- `.scratch/embedded-browser/PRD.md`（全文）
- `docs/adr/0029-embedded-browser-surface.md`（从标题读到「验证」一节；若文件在此之后还有内容，本文未覆盖）
- `packages/core/src/browser-annotation.ts`（全文）
- `apps/desktop/electron/browser-annotation-overlay.ts`（文件头注释与 overlay 工厂的前段）
- `apps/desktop/src/shared/ui/browser/browser-surface.tsx`（只检索到计数与按钮文案附近）
- 文件名过滤：树中路径含 `browser`、且不含 `test` / `node_modules` / `.scratch` 的列表

没有通读 `browser-host.ts`、`browser-annotation.ts`（electron 侧）、`browser-annotation-preload.ts`、`composer-injections.ts`、`session-browser-panel.tsx`。下面凡是「ADR 写」「PRD 写」的句子，都还没有用这些实现文件逐行复核。

Handbean（本仓库当前工作区）：

- `lib/handbean/host.ex`、`lib/handbean/tool/builtin/browser.ex`、`lib/handbean/tool/builtin/preview_serve.ex`、`lib/handbean/tool/registry.ex` 的 host gate
- `lib/handbean/preview/url.ex`、`lib/handbean_web/controllers/preview_controller.ex`
- `lib/handbean_web/router.ex`、`lib/handbean_web/live/workspace_live.ex` 的上传与 composer 事件、`lib/handbean_web/live/workspace_live/composer.ex`
- `lib/handbean/attachments.ex` 的图片字节上限
- `docs/macos-computer-use.md` 的开头
- `AGENTS.md` 里 browser / preview_serve / Coordinator 的现有说明

附件图像只经过读取工具转写，没有逐像素复核。用户已说明这些截图属于另一个 agent。

---

# 事实

## 1. pace 要解决的问题

PRD 与 ADR-0029 的背景同一句：用户改完前端后，要到外部浏览器看效果，再回 Chat 用文字描述「哪个元素哪里不对」。两者都把 Codex / Claude Desktop / Cursor 的「内嵌预览 + 点选元素 + 结构化回传」写成既有产品先例。

ADR-0029 状态为 Accepted，日期 2026-09-03，来源写明 PRD、PR #149 / #153 / #154、issue #86。

## 2. pace 写成文档的决策

以下是 PRD 与 ADR 的文字，不是我对 Handbean 的建议。

### 2.1 宿主

- 用 Electron `WebContentsView`。文档明确不用 `<webview>` 标签，也不用 iframe。不用 iframe 的理由写的是：跨源不能注入，`X-Frame-Options` 会直接拒绝加载。
- 视图由主进程创建和持有。命令走主进程截留，不进 Runtime Gateway，不进 utilityProcess。嵌入页碰不到后端 MessagePort。
- 作为会话里的 `browser` surface。每个 Session 一组 tab，每个已导航 tab 一个原生视图。只显示激活 tab。
- URL 由用户输入。文档写明不做端口探测、不读项目配置猜 URL、不代启 dev server。

ADR 列出的页面命令包括：`browser_navigate` / `back` / `forward` / `reload` / `set_bounds` / `set_visible` / `open_external` / `capture` / `set_design_mode` / `clear_annotations` / `capture_annotation`。实例命令包括 attach / list / open / close / activate / hide_session。

### 2.2 安全边界（ADR 表格与补充句）

| 项 | 文档决定 |
| --- | --- |
| session | 独立分区 `persist:pigui-browser`，与 renderer session 隔离；全局单分区 |
| webPreferences | `sandbox`、`contextIsolation`、`nodeIntegration: false`、`webSecurity: true`；preload 只指向标注层 |
| 导航 | 命令入口先只放行 `http:` / `https:`；`will-navigate` 再拦页面自己的跳转。两道都要有 |
| 新窗口 | `setWindowOpenHandler` 拒绝；`_blank` 改在当前视图里导航 |
| 权限 | 摄像头、麦克风、通知、地理位置等默认全拒 |
| 下载 | `will-download` 直接取消 |
| 页面回传 | 只走独立 channel `pigui:browser-annotation`；按 `event.sender` 认 webContents；消息逐字段重建。不复用没有 sender 校验的 `pigui:invoke` |

PRD 记录了 spike 实测：主进程 `loadURL("file:///etc/hosts")` 不会触发 `will-navigate`，所以白名单必须做在命令入口。

### 2.3 标注交互（文档 + overlay 文件头）

ADR 与 overlay 文件头一致的部分：

- 覆盖层挂在 `document.documentElement` 下，closed Shadow DOM。
- 结构用 DOM API，样式用 CSSOM，不用 `innerHTML`，不用 `<style>`。文件头写明这是为了过 Trusted Types 和严格 `style-src`。
- design mode 打开后：悬停高亮、点击落下序号、评论输入在页内覆盖层里。指针事件在 design mode 期间被吞掉，文件头列出的事件包括 `pointerdown`、`mousedown`、`mouseup`、`click`、`dblclick`、`contextmenu`。
- 工具条只用普通按钮。ADR 的理由：PiGUI 自己的 Popover / Tooltip / Select 会把原生视图换成静态截图，在弹层上标注会标到冻结画面。
- v1 不接 CDP。跨源 iframe 里的元素选不中。
- `reactName` 不做。理由写明：isolated world 共享 DOM，不共享 JS wrapper，读不到主世界的 `__reactFiber$`。`source` 只从 `data-source` / `data-inspector-*` 这类属性 best-effort 读取。

overlay 源码里的强调色常量是 `#6d28d9`。文件头描述的可视物是 hover 高亮、序号标记、评论气泡。我读到的这段没有自由箭头或画笔。

`browser-surface.tsx` 里，激活且有标注时显示 `` `${annotationCount} marked` ``。发送按钮的 `label` 是 `Send to composer`，在页面未就绪、标注数为 0、或正在发送时 `isDisabled`。

### 2.4 回传契约（我读过的 core 源码）

`packages/core/src/browser-annotation.ts` 定义：

- 元素：`index`（从 1 起）、`selector`、`tag`、可选 `text`、视口相对 `rect`、可选 `source: { file, line, column? }`、可选 `comment`。类型注释写明没有 `reactName`。
- 载荷：`url`、可选 `title`、`viewport: { width, height, dpr }`、`elements`、`capturedAt`、`screenshot: boolean`。
- `formatBrowserAnnotationPrompt` 输出固定 markdown。有截图与无截图用不同的首行。无截图时每条多一行 `rect`。有 `text` / `source` / `comment` 才写对应行；没有评论写成 `(no comment)`。注释写明：标记即使用户没写评论也保留这一行。

ADR 对截图路径的写法（实现文件我未通读）：

- `browser_capture_annotation` 先让 overlay `prepare-capture`（收起评论气泡、隐藏 hover、重测视口），再 `capturePage`。序号画在页面里，截图自然带上，不用 canvas 叠印。
- 按面板 CSS 宽度做 `nativeImage.resize` 降采样。
- 页面 500ms 不应答则用主进程最后收到的标注直接截图。
- 只放进当前 Session 已挂载 composer 的草稿，不直接 `send_prompt`，不加 `Send now`。文本追加进草稿；截图走既有图片附件，上限写的是 8 MiB。图片不进 localStorage。未被挂载 composer 消费时，surface 给一行纯文本提示。

### 2.5 两份文档对「记住 URL」的写法不一致

- ADR-0029（含 2026-09-06 的多 tab 修订）仍写：新 Session 或重启后，用户点 “Open browser” 才从项目的 `pigui.browserTabs.v1` 恢复 URL 列表和激活项。只持久化 URL 与激活项，不持久化标注、截图和历史。
- PRD 有一条日期为 2026-09-17、issue #224 的更新：打开 Browser 一律从空白空态开始；不再从 `pigui.browserTabs.v1` / `pigui.browserUrls.v1` 恢复；`browser-url-memory.ts` 已整体删除。原文保留作历史。

我拉到的、路径含 `browser` 的文件列表里没有 `browser-url-memory.ts`。这只说明该路径不在这次列表中。我没有打开渲染层去确认恢复逻辑现在是否还在。

### 2.6 ADR 自己列出的限制

与「标注发到对话」直接相关的几条：

- 敌意页面能删掉覆盖层宿主，但读不到 shadow 内容。
- 覆盖层只在主框架。iframe 内元素标不到，design mode 也拦不住 iframe 内点击。
- 页面自有 shadow DOM 里的元素能选中，selector 停在 shadow root。
- design mode 期间页面指针事件被吞，不能先点开菜单再标注菜单项。
- 回传的 `rect` 是标记当时的视口坐标，不随滚动更新。无截图时这份 rect 会过时。
- 滚出视口的标记仍出现在文本里，但不在截图上。
- 降采样到面板 CSS 宽度，HiDPI 下模型看到的是 1x 图。
- 注入只到达当前已挂载的 composer。文本会当 follow-up 草稿持久化，截图不持久化，重载后只剩文本。
- 快照占位期间页面不可交互。

PRD 的范围外还包括：插件化浏览器面板、Session 之间共享原生视图、dev server 探测、CDP、把 selector 做成独立结构化附件类型、让 Agent 在页面里代点代填。

## 3. 附件截图

事实只有用户的说明：这些截图是另一个 agent 的，不是本次要我当作 pace 源码的材料。

读取工具对三张图的转写（未逐像素复核）：

1. 左侧会话栏有 New Chat、Trajectory、Usage、Packages、Chats、Projects、FIGUI。右侧是带地址栏的浏览器，转写提到 “2 marked” 和 “To composer”，以及一条指向页面标签的浅蓝色箭头。
2. 浏览器工具条上有 “Design”，页面上有指向 “Design” 和 reCAPTCHA / iframe 区域的蓝色箭头，以及 “Describe the change” 评论框。
3. 工具条上有 “Design Mode”。

pace 源码里的按钮文案是 `Send to composer`，计数文案是 `{n} marked`，overlay 强调色是 `#6d28d9`，可视物是序号和评论气泡。转写里的 “To composer”、浅蓝色自由箭头、“Describe the change”、“Design Mode” 与我读到的 pace 源码用词不一致。

## 4. Handbean 现在有的浏览器相关能力

这些是本仓库源码，与 pace 无关。

### 4.1 桌面工作台是 LiveView，不是 Electron

`lib/handbean_web/router.ex` 把 `/`、`/c/:conversation_id`、`/w/:workspace_id/c/:conversation_id` 都挂到 `WorkspaceLive`。没有独立的桌面主进程，也没有 `WebContentsView`。

### 4.2 `browser` 工具是 Agent 在开车，不是用户标注面

`Handbean.Host.browser_backend/0`：声明值为 `:cli` 或 `:webview`，其他值当成没有浏览器。未声明时桌面默认 `:cli`。

`Handbean.Tool.Builtin.Browser`：

- `:cli`：把参数交给 `agent-browser`。描述写的是打开、snapshot、点击、填表、截图、抽取内容。
- `:webview`：窄动作 `open` / `snapshot` / `eval` / `click` / `fill` / `back` / `show` / `hide` / `close`，打在独立的 Agent WebView 上。模块文档写明这不是系统浏览器。

`Handbean.Tool.Registry`：`browser` 在 `browser_backend` 非空时注册。`preview_serve` 只在 `browser_backend == :webview` 时注册。桌面默认 `:cli`，因此桌面默认有 `browser`、没有 `preview_serve`。

聊天里已有一张「接管浏览器」卡：`takeover_browser` 调用 `Handbean.Browser.WebViewSession.user_takeover/1`。这是把已有 WebView 会话交给用户，不是标注层。

### 4.3 PreviewShell 只预览已登记的本地内容

`preview_serve` 的描述：登记工作区静态目录，或一台已经在跑的 loopback 端口，返回 `preview_id`。用户从对话卡片打开 PreviewShell。

`Handbean.Preview.URL`：顶层只允许 loopback 上的 PreviewShell 路径。

`HandbeanWeb.PreviewController`：

- 壳页面带 `frame-ancestors 'none'`。
- `files` 读登记目录里的文件。
- `port` 反向代理该预览登记的 loopback 端口。
- WebSocket / HMR 升级返回 501。
- 转发响应头时丢掉 `content-security-policy`、`set-cookie`、`set-cookie2`。
- 指到登记端口之外的重定向不解开。

这条链路没有地址栏、没有 design mode、没有标注载荷。

### 4.4 系统浏览器是另一条能力

`open_url` 只在 host 注入了 `artifact_delivery_backend` 时注册。`AGENTS.md` 写明成功只表示系统界面已经出现。

### 4.5 macOS computer use 也不是内嵌浏览器

`docs/macos-computer-use.md`：`computer` 工具由 Handbean.app 持有屏幕录制与辅助功能权限，对选中的原生窗口做 `observe` / `click` / `type` / `key` / `scroll`。同一文档写明普通 `click` / `scroll` 仍返回 `unsupportedPointer`，不真正派发。它观察的是 macOS 窗口，不是会话里的一个浏览器 surface。

### 4.6 Composer 没有外部注入口

草稿在 LiveView socket 里：`input_value`、`pending_attachments`，切换会话时收进 `composer_drafts`（`WorkspaceLive.Composer`）。这是进程内 assigns，不是一份可被其他页面写入的存储。

本次检索到的 `input_value` 写入点是：mount 置空、`launch_skill` 填入技能 prompt、`update_input`、技能补全、`Composer` 的草稿切换与清空、`MessageSubmission` 发送失败时把草稿放回去或发送成功后清空。没有一个事件表示「把浏览器标注追加进草稿」。

图片上传（`WorkspaceLive.mount`）：`accept` 为 `.png .jpg .jpeg .gif .webp`，`max_entries: 4`，`max_file_size: 5_000_000`。`Handbean.Attachments` 的 `@max_image_bytes` 也是 `5_000_000`。`Composer` 合并附件时 `Enum.take(..., 4)`。

用户发出去的唯一入口是 `Coordinator.add_message/3`（`send_message` / `steer_message` / `queue_message`）。`AGENTS.md` 写明：会话 idle 时起新 run；会话 running 时，LiveView 的 Send / Enter 默认 steer，显式排队才是 follow_up。

---

# 推理

本节全部是判断。pace 没有这些句子，Handbean 也还没有这些行为。

## 5. 用户要的能力和两边现有代码的关系

用户要的是：人在 Handbean 里打开一个页面，在页面上做标注，把标注送进**当前这条对话**，让模型知道「哪个元素、什么问题」。

pace 已经把这件事做成会话里的一个 surface：真页面、design mode、序号和评论、截图加固定 markdown、放进 composer 草稿，由人再决定发送。

Handbean 现有的四条相邻路径都不是这件事：

| 现有路径 | 它实际是什么 | 和这次目标的差距 |
| --- | --- | --- |
| `browser` + `agent-browser` | Agent 自己开浏览器做研究或操作 | 人没有一块可标注的画面，也没有回 composer 的载荷 |
| WebView + 「接管浏览器」 | 手机宿主上的 Agent WebView，人可以接手看 | 桌面默认不走这条；没有 design mode，没有标注模板 |
| PreviewShell | 已登记的静态目录或 loopback 端口 | 不能当通用地址栏；不能点选元素回对话 |
| `computer` | 对原生窗口截图，指针派发未完成 | 不是浏览器，也没有元素 selector |

所以这是一块新的用户界面，不是把现有工具按钮再暴露一次。

## 6. 不能把 pace 的宿主原样搬过来

pace 选 `WebContentsView` 是因为他们有 Electron 主进程。Handbean 桌面工作台是 Phoenix LiveView，跑在浏览器或系统 webview 里，没有那层主进程。

iframe 被 pace 否决，理由在他们的壳里成立：跨源注不进脚本，`X-Frame-Options: DENY` 的站装不进去。Handbean 若用 iframe 直连目标站，会撞上同一堵墙。PreviewShell 的反向代理只覆盖「已经登记的 loopback」，而且会丢掉上游 CSP 和 `Set-Cookie`，不能当成通用浏览器的半成品。

因此宿主形态是实现前的分叉，不是实现细节。三条都接得上 pace 的载荷，接不上的是「页面怎么被拿住」：

1. **桌面继续用 `agent-browser` / CDP，由 Handbean 进程持有一个 headed 或嵌入页面。** 标注脚本用 isolated world 注入，截图用 CDP 的 page capture。这最接近 pace 的安全模型：页面不在 LiveView 的文档里，cookie 不进 Handbean 的 session。代价是要有一块真正的浏览器画面，以及和 LiveView 面板对齐的尺寸同步。pace 用 `ResizeObserver` → `setBounds` 做的就是这件事；他们的 spike 记录了视图比 DOM 晚大约一个 IPC 往返。
2. **服务端代理进沙箱 iframe，并注入标注脚本。** LiveView 里能做，但必须是独立 origin 或带 sandbox 的框架，不能把敌意页面放进工作台文档。还要自己做 pace 已经列过的闸：只允许 `http`/`https`、拒绝下载和权限、不把 Handbean 的 cookie 带给目标站、不把目标站的 cookie 写进工作台。Preview 控制器今天丢弃 `Set-Cookie`，通用浏览器若也丢弃，本地 dev 站的登录态留不住；pace 用独立 `persist:` 分区就是为了留下这块登录态，同时不污染自己的壳。
3. **只标注 PreviewShell 已经能打开的 loopback / 静态预览。** 范围小于用户说的「内置浏览器」。`X-Frame-Options: DENY` 的任意网站不在范围内。pace 把「这类站点能打开」写成了验收项。

我倾向 1：Handbean 桌面已经依赖 `agent-browser`，而且页面与 LiveView 隔离。2 要在 Phoenix 里重做一套浏览器安全边界，敌意 JS 和 SSRF 的面都比 1 大。3 可以当更小的预览标注，但是另一项产品，不该叫内置浏览器。

手机宿主已经有独立 WebView。若做，桌面和手机应各用自己的画面，共用同一份载荷和同一段 markdown。这和现在的 `browser_backend` 分叉一致：能力在 host 启动前定死，不在运行中从操作系统猜测。

## 7. 应该原样保留的契约

与宿主无关、值得直接对齐 pace core 的部分：

- 元素字段就是 core 里那一组：序号、selector、tag、截断后的可见文本、标记时的视口 rect、可选 `data-*` source、可选评论。不要在 v1 承诺 React 组件名。
- `screenshot: boolean` 决定模板怎么写。有图靠序号对图；没图才写 rect。rect 会过期，模板不该在有图时再写一份可能指错的坐标。
- 没写评论的标记仍占一行。丢掉等于用户的指向消失。
- **进草稿，不调用 `Coordinator.add_message/3`。** Handbean 里直接发送会在 idle 时开新 run，在 running 时默认 steer。pace 把「人先改再发」当成已拍板项。Handbean 的三条发送路径（新消息 / steer / 排队）已经在 composer 上，草稿进去之后自然覆盖。
- 截图走现有图片附件，不新开 transcript 附件类型。pace 也没有新类型。
- 注入只针对当前已挂载的对话。切换会话后，标注留在浏览器那一页，不跟着写进别的对话。pace 用在途截图的 revision 丢掉过期结果；Handbean 至少要在切换 `current_conversation_id` 时作废还没写进草稿的那一次。

Handbean 侧需要新建的只有两小块，而且 pace 也是后补的：一段纯函数 `format`（对应 `formatBrowserAnnotationPrompt`），以及一个只给当前 LiveView 用的草稿写入（追加文本、把 PNG 放进 `pending_attachments`）。`launch_skill` 已经会改 `input_value`，但那是替换成技能 prompt，不是追加，也不能带图片。

图片上限要对齐 Handbean 已有约束，而不是 pace 的 8 MiB：最多 4 张，单张 5_000_000 字节，类型限于 png/jpeg/gif/webp。2x 全幅 PNG 很容易超过 5MB，所以要在进草稿之前降采样。降完仍超限就只送文本，并把 `screenshot` 设为 false，让模板改走 rect。不要静默丢掉整次标注。

## 8. 不该照抄的部分

- Electron 的 bounds、vibrancy、1280px Dialog 遮罩、Popover `toggle` 监听。那是原生视图盖住 DOM 的补丁。LiveView 里没有 `WebContentsView`，这套不存在。
- 自由箭头和 “Describe the change”。那是附件里另一个 agent / Cursor Design Mode 的样子。pace 落地的是元素命中、序号、评论框。两套定位语义不同：箭头是画面坐标，序号是 DOM selector。按 pace 做就做后者。
- ADR 里的 `pigui.browserTabs.v1` 恢复。更新更晚的 PRD 写明这套已删除，而我还没用当前渲染层证实。v1 用空白空态更符合那条更新，也少一块持久化。
- 让 Agent 用这块浏览器代点击。pace 把 browser-use 划在范围外。Handbean 的 `browser` 工具继续负责 Agent 驾驶；人的标注面不要变成第二套工具执行器。
- 多 tab、弹层截图占位、跨源 iframe 内元素。pace 的 v1 已知限制可以原样接受，不必在第一版补 CDP。

## 9. 安全上我不会放宽的点

无论最后用 CDP 还是代理 iframe：

- 导航白名单在「我们发起加载」和「页面自己跳转」两处都做。pace 的 spike 说明只靠后一处会漏掉 `file:`。
- 标注结果在进入草稿前按字段重建。selector、评论、文本都当不可信字符串，模板里只做单行折叠（pace 的 `oneLine`）。不要把页面回传的 HTML 插进 LiveView。
- 页面脚本不能调用 `Coordinator`、不能读 transcript、不能碰 LiveView socket。pace 用独立 IPC 和 sender 校验换来的就是这条。
- 下载、摄像头、麦克风、通知、地理位置默认不开。

## 10. 还没定、本文不替用户拍板的事

1. 桌面画面用 `agent-browser`/CDP，还是沙箱代理 iframe，还是只做 PreviewShell。第 6 节是我的倾向，不是已确认决策。
2. 第一版是否包含手机 WebView。桌面 LiveView 自己就能演示「标注 → 当前对话草稿」。
3. 草稿里已有文字时是追加还是另起一段。pace 的 ADR 写的是追加。我未读 `composer-injections.ts`，不断言它的换行和光标行为。
4. 没有当前对话（新聊天、尚未创建 conversation）时，标注先留在面板，等这条对话存在再写入，还是直接拒绝。pace 要求 composer 已经挂载。

在第 1 点确定之前，不值得写 LiveView 面板或标注脚本。载荷纯函数和草稿写入都依赖「页面由谁持有、截图从哪来」。
