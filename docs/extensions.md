# 给 Handbean 开发插件（Extension）

用当前工作区给 **Handbean 产品**加能力，不是去改 Handbean 仓库源码。
Web / BEAM 发行包里的 Agent 可以加载随包 skill `developing-handbean-extensions` 按同样的契约写插件。

运行时边界（hook 能改什么、不能改什么）以
[`runtime-contracts.md`](runtime-contracts.md) 为准。源码与测试是实现事实来源。

这不是 OS 沙箱。加载进同一 BEAM 的 Elixir 扩展是受信任代码。只安装你信任的插件。

## 和 MCP、Skill 的区别

| 机制 | 用途 |
| --- | --- |
| **Extension** | 本页。工作区里的 Elixir 插件：工具、hook、长期 worker。 |
| **MCP** | 外部 Model Context Protocol 服务器，不是 `extension.json`。 |
| **Skill** | 给 Agent 加载的操作说明（`SKILL.md`）。不会注册工具或 hook。 |

## 放置位置

每个插件一个目录，内含 `extension.json`（或 `manifest.json`；前者优先）：

- 工作区：`{workspace}/.handbean/extensions/<name>/`
- 用户级：`~/.handbean/extensions/<name>/`（Windows 为 `%USERPROFILE%\.handbean\extensions\`）

同名时 **工作区覆盖用户**。

工作区 `{workspace}/.handbean/extensions` **默认不执行**。这是项目代码信任开关，不是清单里的 `enabled`，也不是工具 auto/prompt/deny。要加载工作区插件，必须在宿主环境设置 `HANDBEAN_TRUST_PROJECT_CODE` 为 `1`、`true` 或 `yes` 后**重启** Handbean。未开启时，写了文件也不会编译或注册工具。用户级 `~/.handbean/extensions` 不依赖该开关。

热加载：

- 启动时加载用户级扩展；工作区扩展只在上述信任开启时加载。
- 文件监视器只看**受信任的 project**（开启信任时通常是进程 cwd）和用户级扩展目录。用外部编辑器改另一个目录里的插件，监视器看不到。
- 内置 `write` / `edit` 可以通知热加载；工作区路径仍要求已开启信任，未信任的通知会被忽略。即使对话工作区不是 cwd，在信任开启时也可以这样加载。
- 编译失败会留下上一份成功的工具、hook 和 worker。

发现规则（实现约束，不是建议）：

- 不跟随符号链接，跳过隐藏目录和 `node_modules`
- 清单文件最大 1 MiB
- `entry` 必须解析在插件根目录之内

临时试验可用工具 `ext__mount__apply`（内存编译，不写盘）。要保留插件，把文件写到上面的目录，不要只挂在内存里。

## 目录示例

```text
{workspace}/.handbean/extensions/demo-ping/
  extension.json
  extension.ex
```

`extension.json`：

```json
{
  "name": "demo-ping",
  "version": "0.1.0",
  "description": "Ping tool for Handbean",
  "entry": "extension.ex",
  "enabled": true,
  "tools": [
    {"name": "ping", "description": "Return pong"}
  ],
  "hooks": []
}
```

`name`：小写字母、数字、单连字符；不能为空、不能首尾连字符、不能连续连字符。
`enabled: false` 时发现该插件但不编译、不注册工具。
`entry` 相对插件根目录，指向要 `Code.compile_file/1` 的 Elixir 源文件。

可选字段：`version`、`description`、`permissions`、`hooks`、`tools`、`commands`、`providers`。未知字段进入 metadata，不执行。

`permissions` 默认是 `{"network": [], "filesystem": "none", "tools": []}`。
`filesystem` 允许 `none` / `workspace` / `read-only`；`network` 是 URL 列表，不能含 `"*"`。
**清单里的 permissions 是元数据，不是沙箱，也不会替代工作区工具审批。**

`commands` 和 `providers` 目前只解析进清单，**不会**接到 LiveView 斜杠命令或 `ModelConfig`。不要指望声明它们就能换模型或出现 `/ext:` 命令。

## 工具

清单 `tools[].name` 必须匹配 `~r/\A[a-z][a-z0-9_]*\z/`。
运行时工具名是 `ext__<extension>__<tool>`，例如 `ext__demo-ping__ping`。

`entry` 编译出的模块必须实现 `Handbean.Agent.Tool`：

- 必选：`name/0`、`description/0`、`input_schema/0`、`execute/2`
- `name/0` 必须返回上面的 `ext__...` 全名
- 可选：`concurrent?/0`（默认并行）、`max_result_chars/0`、`timeout_ms/0`、`hint/0`

`execute/2` 返回 `{:ok, text}` 或 `{:error, text}`（也可带第三项 map）。
`context` 可能含 `:working_directory`、`:session_id`。文件路径用 `Handbean.Agent.Tool.resolve_path/2`，不要自己拼出工作区外的路径。

```elixir
defmodule DemoPing.Ping do
  @behaviour Handbean.Agent.Tool

  def name, do: "ext__demo-ping__ping"
  def description, do: "Return pong"
  def input_schema, do: %{"type" => "object", "properties" => %{}}
  def execute(_input, _context), do: {:ok, "pong"}
end
```

清单里声明了但编译结果里找不到对应模块时，该工具不会注册（可能记一条诊断），不会让整个运行时退出。

不要用内置工具短名（如 `read`、`bash`）当插件工具名。插件工具仍走工作区权限策略（auto / prompt / deny）。

## Hook

清单 `hooks` 列出关心的事件名。`entry` 里第一个导出 `handle_event/2` 的模块会作为该插件的 hook。

```elixir
defmodule DemoPing.Hook do
  @behaviour Handbean.Extension.Hook

  def handle_event(%{name: :context}, _ctx), do: :ok
  def handle_event(_event, _ctx), do: :ok
end
```

返回值：`:ok`、`{:ok, map}`（改 payload）、`{:halt, reason}`（可拦截的事件上会阻止后续）、`{:error, reason}`（记失败但继续）。

**只有** `before_agent_start`、`tool_call`、`context` 可以拦截或改写。其它已发出的生命周期事件是只读通知：halt / 改写会被忽略，后面的观察者仍能收到。
`message_delta` / `thinking_delta` **不会**进入 hook 管道。

可拦截事件的实际能力：

| 事件 | 可做 | 不可做 |
| --- | --- | --- |
| `before_agent_start` | halt；改 `system_prompt` / `metadata` | 改 run 身份或工具授权 |
| `context` | halt（不发本次 provider 请求）；改本次 `messages` / `system_prompt` | 改持久 State / transcript |
| `tool_call` | halt；合并 `args` | 改工具名或调用 ID。改写后仍检查当前工具集和工作区策略，不继承原调用的临时批准 |

已知事件名不等于每次运行都会发出。完整契约见 `runtime-contracts.md`。

Turn 读取的是 **atom 键**：`:system_prompt`、`:metadata`、`:messages`、`:args`。

## 长期进程

`entry` 编译出的模块如果导出 `child_spec/1`，会挂到 `Handbean.Extension.Supervisor`。
成功热加载且模块仍在名单里时保留 pid；模块从成功编译结果中消失才停掉。失败的编译不得清空正在跑的 worker。

## 内存挂载

`ext__mount__apply` 把一段 Elixir 源码编译进内存并注册 `ext__<mount_id>__*` 工具和 `child_spec/1` worker。`ext__mount__drop` 按 id 卸掉。
重新 apply 同一 id 会替换注册，但不会回收刚编译的模块名（每次挂载有独立生成命名空间）。
这不是持久插件。

## 不要做的事

- 不要复制 Coordinator / Runner / 权限状态机 / 持久化
- 不要把客户端做成任务生命周期的事实源
- 不要用 NIF 或外部 C 工具链；插件是纯 Elixir，在宿主 BEAM 里编译
- 不要把 MCP 服务器或 `SKILL.md` 当成 extension
- 不要假设 `commands` / `providers` 已经接通 UI 或模型目录
