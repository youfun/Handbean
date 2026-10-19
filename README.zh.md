# Handbean

[English](README.md) · [中文](README.zh.md)

本地 AI 编程与 Agent 助手。对话交互、工具调度与长期记忆全部保留在本机。LiveView Web 界面与移动端（Android / iOS）共享同一套 Elixir/OTP 运行时。本项目曾用名为 **Handbeam**。

- **工作区操作**：读写与编辑文件、执行 Shell 命令、基于模糊匹配快速搜文件、基于符号检索精确定位代码位置
- **权限管控**：细粒度工作区权限管理，支持自动执行（auto）、人工审批（prompt）与拒绝（deny）
- **实时响应**：支持文本流式生成与工具执行状态实时反馈
- **多模型支持**：支持 Anthropic 及各类 OpenAI 兼容接口（StepFun、Ollama、OpenCode Go、DeepSeek、OpenRouter 等）
- **扩展与记忆**：支持 MCP（Model Context Protocol）、[工作区 Elixir 插件](docs/extensions.md)、BEAM 虚拟机深度内省与跨会话记忆
- **多端同核**：Web 与 Android / iOS 移动端共用同一套 Coordinator 与 Runner 调度核心

## 聊天内 HTML / 交互组件（Web）

在 Web 聊天中要求可视化、计算器或小型交互界面，助手可用 `html` / `widget`
代码块直接展示预览。支持流式静态预览、源码切换和复制；代码块闭合后运行内联
JavaScript。历史仍保存为对话 Markdown，重新打开可恢复预览，交互中的临时值不持久化。

预览使用不含 `allow-same-origin` 的 iframe 沙箱，不能访问应用 DOM、cookie、存储
或宿主工具。CSP 阻止外部脚本、fetch 和表单提交；组件需自包含，不依赖 CDN。
这不是操作系统级或完整的无网络沙箱（iframe 自身导航仍受浏览器规则控制）。
Android / iOS 原生聊天目前仍显示代码，不支持此内联预览。

## 应用截图

Android 原生界面真机截图：

<img src="docs/screenshots/android-chat-en.png" alt="Handbean Android 聊天界面" width="360">

### 手机端 Elixir 项目编程（实验性）

在手机上通过对话交互，即可让 Agent 在工作区中创建、修改和运行 Elixir/Mix 项目。该能力完全基于客户端内置的 Elixir/OTP 运行，无需在手机上额外配置 Linux 容器或终端环境：

- **依赖支持**：支持与当前内置运行时兼容的纯 Elixir/Erlang 依赖；不支持含 C 扩展的原生构建（NIF）或依赖外部编译链的库。
- **执行环境**：项目代码直接在宿主应用的 BEAM 虚拟机中执行，非沙箱隔离环境，请仅运行信任的代码。
- **多端现状**：Android 真机已完成端到端验证；iOS 目前仅在模拟器中通过测试，真机与发布版仍在适配中。

## Web UI 预编译包（开箱即用）

GitHub Releases 的 `web-latest` 及各版本标签提供了开箱即用的自包含运行时包。解压后即可直接运行 Web 界面，无需在本机安装 Elixir 或 Erlang：

| 平台 / 架构 | 包名 | 说明 |
|-------------|------|------|
| Linux (x86_64) | `handbean-web-linux-x86_64.tar.gz` | 执行 `./start.sh` 启动 |
| Linux (ARM64) | `handbean-web-linux-arm64.tar.gz` | 执行 `./start.sh` 启动 |
| macOS (Apple Silicon) | `handbean-web-macos-arm64.tar.gz` | 执行 `./start.sh` 启动 |
| macOS (Apple Silicon 原生应用) | `Handbean-macos-arm64.zip` | 解压后直接打开 `Handbean.app`（基于系统 WebKit，无 Electron 开销） |
| Windows (x86_64) | `handbean-web-windows-amd64.zip` | 执行 `start.bat` 启动 |
| Windows (带开发工具链，实验性) | `handbean-web-windows-amd64-toolchain.zip` | 启动时临时在当前进程 PATH 注入 Elixir、Mix、Hex、Rebar3 和 MinGit（不含 C 编译器） |

**使用说明**：
- **访问地址**：解压启动后，默认服务地址为 `http://localhost:5008`。
- **Windows 终端说明**：由于内置 Web 终端引擎（Ghostty）暂无 Windows 原生 NIF 支持，Windows 发行包暂未内置浏览器终端组件。
- 暂不提供 Windows ARM64 预编译包。

### 局域网访问

Windows / Linux / macOS 的逐步说明见[局域网部署](docs/lan-deployment.md)。

默认启动只接受本机连接。需要让受信任局域网内的其他设备访问时，指定服务端的
主机名或 IPv4 地址（不是访问设备的地址）：

```bash
# Linux / macOS，在解压后的 Web UI 包中运行
./start.sh --lan 192.168.1.10
```

```powershell
# Windows，在解压后的 Web UI 包中运行
.\start.bat -LanHost 192.168.1.10
```

脚本会用中英文提醒设置足够长、随机且不重复使用的强密码，再提示输入且不回显；
通过环境变量提供密码时也会显示提醒。用户名默认 `handbean`，可通过
`HANDBEAN_ACCESS_USERNAME` 覆盖。无人值守启动时，通过宿主环境提供
`HANDBEAN_ACCESS_PASSWORD`；脚本不保存密码。其他设备打开
`http://192.168.1.10:5008` 即可；必要时在服务端防火墙放行端口，可用 `PORT` 修改默认 5008。

局域网模式会显式开启全部 IPv4 网卡监听、密码认证和 HTTP。
**HTTP 不加密密码、会话或通信内容，只用于受信任网络。** 公网部署需要 TLS
反向代理，不要使用局域网参数。默认 HTTPS 强制策略和来源校验保持开启。
详见[部署安全说明](docs/security.md)。

## 源码运行

如果你希望参与开发或直接从源码构建，需满足以下环境要求：
- **Elixir**：`>= 1.20.0`
- **Erlang/OTP**：`28+`
- **Node.js**：`24`（LTS，用于前端资源构建）
- **Zig**：Linux/macOS 需要 `0.16.0`，Linux 还需要 **patchelf**，用于构建 fork 中的 Ghostty 终端引擎和 NIF。`mix compile` 会自动构建依赖锁定的引擎；首次构建需要下载 Ghostty 源码及 Zig 依赖。

### 启动步骤

```bash
# 1. 配置模型接口（填写 apiKey，或配置系统环境变量 OPENAI_API_KEY）
cp models.example.json models.json

# 2. 安装依赖并构建静态资源
mix setup

# 3. 启动开发服务器（默认端口 5002）
mix phx.server
```

启动后在浏览器打开 `http://localhost:5002`，选择工作区目录即可开始使用。

### 编译并运行生产版 Web UI

Linux/macOS 按构建机器选择 `linux-x86_64`、`linux-arm64` 或 `macos-arm64`：

```bash
bash scripts/pack_webui.sh linux-x86_64
bash scripts/start.sh                     # 仅本机访问
# 或者不执行上一条，改为：
bash scripts/start.sh --lan 192.168.1.10   # 受信任局域网，提示输入密码
```

Windows：

```powershell
.\scripts\build_webui.bat                 # 编译并选中一个新的本地版本
.\start.bat                               # 仅本机访问
# 或者不执行上一条，改为：
.\start.bat -LanHost 192.168.1.10
```

Windows 本机一键编译用 `scripts\build_webui.bat`（或 `build_webui.ps1`）：先检查
工具链（Elixir/Mix、Node.js、tar、MSVC cl/nmake），缺失时用双语报错指出安装方法，
然后加载 MSVC 环境，再调用与 CI 相同的 `pack_webui.ps1` 编译。每次成功的本地构建
都会写入 `_build/local-webui/versions` 下的独立目录，只更新
`_build/local-webui/current.txt` 指针，因此不会覆盖仍由当前 Web UI 进程占用的旧目录。
退出旧实例后，再次运行仓库根目录的 `.\start.bat` 即切换到刚选中的新构建；启动器
仍兼容以前位于 `_build/prod/rel/handbean` 的构建。

解压包中的启动脚本仍运行自身所在目录的 release。两种启动方式都不会启动开发服务器；
根目录启动器会透传 `-LanHost` 等参数。正式数据库默认位于
`~/.handbean/handbean.db`（Windows 使用 `%USERPROFILE%`），可用 `DATABASE_PATH`
覆盖。工作区索引默认同目录 `workspaces.json`，可用 `HANDBEAN_WORKSPACES_FILE`
覆盖。不要让 GUI 与 Web UI 同时使用同一个数据库。

### 静态资源开发说明

- 静态资源源码位于 `assets/` 目录；`priv/static/assets/` 下的构建产物不纳入版本控制。
- 样式源码位于 `assets/css/`，预生成的默认基础样式位于 `assets/default.css`。
- `mix setup` 会自动安装依赖并构建资源。如仅需重新构建前端资源，可运行 `mix assets.setup` 和 `mix assets.build`。
- `mix phx.server` 在开发模式下会自动监听前端文件变动并触发热更新；生产构建使用 `mix assets.deploy` 压缩资源并生成静态摘要。
- `mix compile` 仅编译 Elixir 后端代码。

### 运行测试

```bash
mix test --exclude slow --exclude e2e
```

## 迁移已有数据

从 Handbeam 升级时，可使用[迁移脚本](scripts/MIGRATION.md)复制配置、工作区登记文件及正式数据库到新路径，保留会话与工作区的关联。先运行 `python3 scripts/migrate_legacy_data.py` 预览，确认后添加 `--apply` 执行。已有目标文件和原文件均会保留。

## 检查宿主生效配置（Inspect Config）

在不启动完整服务、不初始化存储目录、不暴露真实凭据且不连接 MCP 的前提下，你可以通过诊断工具导出当前环境的配置解析报告：

```bash
mix handbean.inspect_config --workspace /path/to/workspace
```

若在运行中的宿主内部调用，可使用 `Handbean.ConfigInspection.report(workspace: path)`。

**报告特点与覆盖规则**：
- **分层决策解析**：清晰区分宿主初始能力（Host seed）、工具注册表状态、依赖静态检查，以及未声明的运行时权限。
- **配置覆盖顺序**：全局配置优先于内置默认值，工作区特定配置优先于全局配置；运行时的 Provider 环境变量覆盖配置文件中的目录值。
- **安全脱敏**：报告会自动隐藏绝对路径、模型 ID、权限正则、动态工具名、网络 URL、凭据及提示词正文，方便安全共享与故障排查。
- **静态诊断**：诊断过程纯静态分析，不会执行任何外部命令、本地回调或发起真实网络探测。

## ChatGPT / Codex 订阅登录

如果你拥有 ChatGPT 订阅（Codex 权益），可以直接使用账号登录，无需配置 API 平台充值余额：

1. 在 Web 端进入 **设置 → 可用模型 → 订阅登录**，选择 **ChatGPT (Codex subscription)**。
2. 按照提示在 OpenAI 授权页面输入设备码完成验证，随后在模型列表中选择对应模型即可。
3. 可通过“刷新订阅模型”按钮同步最新的可用模型目录。

**注意事项**：
- 无需在本地安装 Codex CLI，推理直接走 Codex Responses 协议；工具执行与权限审批仍由 Handbean 控制。
- 该功能扣除的是 ChatGPT 订阅包含的使用额度，而非 OpenAI Platform API 预充值余额；可用模型及调用额度受 OpenAI 账号订阅套餐限制。
- 认证凭证安全保存在本地 `~/.handbean/auth.json`（权限为 0600），请勿共享或将该文件提交至版本库。
- 移动端设置界面暂未接入此登录流程。

## Git 私有仓库认证

`git` 工具仅接收预先命名的凭据标识（`credential` 参数），杜绝在对话中直接传输明文密码或个人访问令牌（PAT）。

请在宿主启动配置中声明凭据，不要保存在工作区或对话上下文中。例如在宿主运行时配置中：

```elixir
config :handbean, :git_credentials, %{
  "project-origin" => [
    endpoint: "https://github.com",
    password: System.fetch_env!("PROJECT_GIT_TOKEN")
  ]
}
```

Agent 发起 Git 操作时仅需传递凭据名称：
```json
{"action": "push", "credential": "project-origin"}
```

**安全边界**：
- 认证质询必须与配置中的 HTTPS endpoint 完全匹配。
- 底层 libgit2 库会拒绝跨主机重定向与明文 HTTP 降级，但在同一主机的其他端口或路径上可能会复用凭据。
- **配置凭据代表信任该主机名下的全部 HTTPS 服务**，并不提供按端口或具体仓库路径的绝对隔离。请勿为包含不可信服务的主机配置凭据，并建议使用只针对特定仓库授权的最小权限 PAT。
- 不传 `credential` 时默认走匿名访问。移动端也可在启动时注入上述配置。

## 移动端开发（Android / iOS）

```bash
cd mobile
mix deps.get
mix test

# 构建 Android APK
bash script/pack_android_apks.sh --abi arm64-v8a

# 启动 iOS 模拟器（需要 macOS 及 Xcode）
mix ios.native
```

详细指南请参阅 [`mobile/README.md`](mobile/README.md)。ChromeOS 设备构建参数请使用 `--abi x86_64`。iOS 测试应用 Bundle ID 为 `com.example.handbean_probe`。

## 许可协议

源码以及非 iOS 发行采用 [FSL-1.1-ALv2](LICENSE)（Functional Source License 1.1, Apache-2.0 Future License）。Copyright (C) 2026 youfun。

静态链接 [ish-arm64](https://github.com/youfun/ish-arm64) 的 iOS 发行采用 [GPLv3](LICENSE.GPLv3)。该二进制的对应源码，包括链入其中的 Handbean 代码，按 GPLv3 提供。见 [LICENSE.iOS](LICENSE.iOS)。
