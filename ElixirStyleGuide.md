# Elixir 专家开发规范 (Ultimate Version)

这份文档整合了 BEAM 核心哲学、架构设计原则与微观编码规范，旨在指导生成“单次通过（Single Pass）”的高质量、地道 Elixir 代码。

除 Elixir/Phoenix 本身明确规定的语法和 API 契约外，本文中的“必须”“禁止”表示 Handbean 团队偏好，不代表 Elixir 生态的官方规则。维护现有代码时应结合上下文，不为套用偏好而做无关重构。

---

## 1. 核心哲学与原则 (Core Philosophy)

1.  **不可变性为魂 (Immutability)**
    * 函数是数学公式，而非操作指令。
    * **规则**：一切状态改变必须显式地通过返回值体现。
    * *Good:* `data = transform(data)`
    * *Bad:* `data.update()`

2.  **显式胜于隐式 (Explicit > Implicit)**
    * **规则**：严禁依赖进程字典或隐式全局状态。函数的输入输出必须透明。
    * **数据流**：利用管道 (`|>`) 将数据转换步骤线性化，减少上下文切换负担。

3.  **信任 BEAM 与标准库**
    * 优先使用 `Enum`, `Stream`, `Registry` 等内置工具。
    * **原则**：不要过早引入 Redis、RabbitMQ 等外部依赖，除非 BEAM 无法满足需求。

4.  **让崩溃发生 (Let it Crash)**
    * **规则**：不要试图用 `try/rescue` 捕获所有错误。
    * **策略**：编写能够自我修复的监控树结构（Supervision Trees），让 Supervisor 处理进程重启。

---

## 2. 模块结构模板 (Module Structure)

所有模块应严格遵循以下物理布局，以增强一致性与可读性：

```elixir
defmodule MyApp.Context.Entity do
  @moduledoc """
  简要描述模块用途。
  """

  # 1. 编译指令 (分组并按字母排序)
  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias MyApp.Repo
  alias MyApp.Utils

  require Logger

  # 2. 行为与属性
  @behaviour SomeBehaviour
  @primary_key {:id, :binary_id, autogenerate: true}

  # 3. 数据定义 (Schema/Struct)
  schema "table" do
    field :name, :string
    timestamps()
  end

  # 4. 公共 API (@doc 必须包含 Doctest iex>)
  @doc """
  简述功能。

  ## Examples

      iex> MyApp.Context.Entity.add(1, 2)
      3
  """
  def public_function(arg), do: do_private(arg)

  # 5. 回调实现 (Callback Implementations)
  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # 6. 私有函数 (Private Functions - 建议前缀 do_)
  defp do_private(arg), do: :ok
end

```

---

## 3. 命名规范 (Naming Conventions)

* **`snake_case`**：用于函数、变量、原子（Atoms）、模块属性、文件名。
* *注意*：文件名必须与模块名对应（如 `lib/my_app/user.ex` -> `MyApp.User`）。

* **`PascalCase`**：仅用于模块名和结构体。
* **谓词函数 (`?`)**：返回布尔值的函数必须以 `?` 结尾。
* *Good:* `valid?(user)`, `empty?(list)`
* *Rule:* `is_` 前缀仅限用于 Guards（如 `is_binary/1`）。

* **危险函数 (`!`)**：会抛出异常（而非返回 error tuple）的函数必须以 `!` 结尾。
* *Good:* `get!(id)`, `File.read!`

---

## 4. 编码禁令与避坑指南 (Pitfalls & Bans)

### 4.1 变量作用域陷阱

Elixir 变量可重绑定，但 `if`, `case`, `with` 内部的绑定**不会泄漏**到外部。

### 4.2 列表与集合性能

* **禁止索引访问**：严禁使用 `list[0]`（链表不支持随机访问）。请用 `Enum.at/2` 或模式匹配。
* **追加元素**：
* **✅ 推荐**：`[new | list]` (O(1) 复杂度)。
* **❌ 禁止**：`list ++ [new]` (O(n) 复杂度)，在循环中会导致灾难级性能下降。

* **Stream 使用**：处理大型文件、无限序列或数据库流时，**必须**使用 `Stream` 模块进行惰性求值。

### 4.3 Map vs Struct

* **Struct**：**必须**使用点语法 `struct.field`。这能在编译时捕获拼写错误。
* **Map 必需键**：团队偏好点语法 `map.key` 或模式匹配 `%{key: value}`，让缺键尽早失败并表达数据契约。
* **Map 可选键**：使用 Access 语法 `map[:key]`（或合适的 `get_in/2`）；缺键返回 `nil`。不要把 Access 用于实际必需的键来掩盖错误。

### 4.4 逻辑控制与管道

* **模式匹配优先**：能在函数头解决的判断，绝不写在函数体内。
* **管道与控制流**：Handbean 团队偏好先给管道结果命名，再交给 `case`、`if` 或 `with`，尤其当管道或分支较长时。短小、清晰的 `value |> fun() |> case do ... end` 是合法 Elixir，并非生态禁令；以可读性和现有上下文为准。

* **`with` 语句规范**：
* 仅用于处理一连串的“快乐路径”。
* **禁止**：手动加 Tag（如 `{:step1, val} <- ...`）。
* **避免**：使用 `else` 分支（除非是为了统一转换错误格式）。如果 `else` 逻辑复杂，请改用 `case` 或拆分函数。

---

## 5. 架构设计与工具选择 (Architecture & Tools)

### 5.1 外部交互 (HTTP)

* **强制库**：**Req**。
* **禁止库**：`HTTPoison`, `Tesla`。
* **模式**：封装 API Client 时使用 `Req.new(base_url: ...)` 复用连接配置。

### 5.2 数据库 (Ecto)

* **Changeset 优先**：始终通过 `Ecto.Changeset` 进行数据清洗和验证。
* **分离关注点**：区分 `create_changeset` 和 `update_changeset`。
* **查询优化**：复杂查询使用 `from` 宏；避免 N+1 查询，积极使用 `preload`。

### 5.3 OTP 与并发

* **GenServer 定位**：用于管理运行时状态（连接池、聚合器）、序列化访问。**不要**将其用作单纯的数据存储对象。
* **背压控制 (Back-pressure)**：并发处理集合时，**强制使用** `Task.async_stream/3`，严禁无限制的 `Task.async`派生。
* **初始化**：耗时操作应放在 `handle_continue/2` 中，避免阻塞父进程的 `init`。

### 5.4 并发与测试原则

#### 禁止用 timeout/sleep 掩盖因果顺序问题

在 Elixir/BEAM 上，并发正确性的首要目标是保证**因果顺序**，而不是“给异步流程更多时间完成”。

禁止以下做法作为并发问题的默认修复手段：

* 随意增加测试 timeout
* 使用 `Process.sleep/1` 等待异步完成
* 用更长的轮询窗口掩盖竞态条件
* 在未定位因果链路前，用 retry / eventually 风格断言替代正确同步

优先采用以下方式修复问题：

* 明确消息传递边界，使用 `send/receive`
* 使用 `Task.await/2`、`GenServer.call/3`、monitor、link 等明确同步机制
* 为异步副作用提供可观察完成信号
* 通过事务边界、唯一约束、状态校验保证执行顺序
* 在测试中验证“事件已经发生”的因果证据，而不是猜测等待多久足够

原则：

* 如果一个测试只有在“多等几秒”后才能稳定通过，通常说明实现或测试违反了因果顺序
* timeout 只应用于定义外部边界，不应用于掩盖内部并发缺陷
* 修复并发问题时，优先修正事件顺序、状态流转和完成信号，不允许先增加 timeout 作为默认方案

#### AI Agent 额外约束

AI Agent 遇到异步失败、偶发超时、测试不稳定时：

* 不得先通过增加 timeout 解决
* 不得先加入 `Process.sleep/1`
* 必须先定位缺失的因果链路、完成信号或状态约束
* 只有在确认 timeout 表示真实外部 SLA 边界时，才允许调整 timeout，并必须说明理由

---

## 6. 错误处理与调试 (Error Handling)

* **Tuple 模式**：
* 成功：`{:ok, value}`
* 失败：`{:error, reason}`

* **异常**：仅用于不可恢复的错误（如启动配置缺失）。
* **调试禁令**：生产代码中**严禁**保留 `IO.inspect`。本地调试推荐使用 `dbg/2`（能够显示完整的管道上下文）。
* **日志**：使用 `Logger.info/2` 等，并采用结构化日志（Metadata）。
* **安全红线**：**绝对禁止**对用户输入使用 `String.to_atom/1`（防止 DoS 攻击）。

---

## 7. 开发者工具 (Usage Rules)

在编写代码前，养成查阅文档的习惯：

* **查阅模块**：`mix usage_rules.docs Enum`
* **查阅函数**：`mix usage_rules.docs Enum.zip/2`
* **全局搜索**：`mix usage_rules.search_docs "back-pressure"`

## 8. Mix 工作流与代码生成 (Mix Workflow & Generators)

Mix 是 Elixir 的核心构建工具，熟练使用 Mix 能显著提升开发效率。

### 8.1 优先使用代码生成器 (Generators First)

Phoenix 生成器适合为标准 CRUD 快速搭建 Context、Schema、Migration 和 Web 层脚手架，但并不要求每个业务 Context 都由生成器创建，也不要求所有 Context 都采用 CRUD 形态。非 CRUD 领域逻辑、既有架构约束或小型定制可直接实现；迁移仍优先用生成器取得有序时间戳。

* **团队偏好**：标准 CRUD 场景采用 **Generate, then Modify (生成 -> 重构)**。
* **理由**：生成器不仅创建了标准的文件结构，还自动处理了 Ecto 映射、Changeset 基础逻辑以及**配套的测试文件**。手动创建极易遗漏测试或引入拼写错误。

#### 核心生成器对比：Phoenix vs BCC

在选择生成器时，需根据业务场景区分“数据驱动”与“契约驱动”：

| 维度 | `mix phx.gen.*` (Phoenix) | `bcc` (Backend Compiler) |
| :--- | :--- | :--- |
| **核心定位** | **数据驱动**。侧重于快速实现数据库 CRUD。 | **契约驱动**。侧重于定义架构契约与接口规范。 |
| **适用场景** | 标准的管理后台、简单的基础表维护。 | 复杂的业务逻辑、跨系统集成、AI 协作开发。 |
| **架构模式** | MVC / Context 模式（通常与 Ecto 紧耦合）。 | 六边形架构（Ports & Adapters，解耦具体实现）。 |
| **错误处理** | 侧重于 Changeset 校验错误。 | 显式的业务错误码（Error Codes），更易于审计。 |
| **协作方式** | 适合人类开发者快速起步。 | 适合 Agent 通过 YAML 声明契约，生成标准代码。 |

#### 推荐的生成策略：

1.  **数据层与业务逻辑 (Context & Schema)**
    * **命令**：`mix phx.gen.context`
    * **场景**：当你需要标准的 CRUD 逻辑和数据库表支持时。
    * *示例*：
        ```bash
        # 生成 Accounts 上下文和 User 实体
        mix phx.gen.context Accounts User users name:string age:integer email:string:unique
        ```

2.  **业务服务与架构契约 (BCC Compiler)**
    * **命令**：`.github/tools/bcc-linux-x86_64 compile`
    * **场景**：当你需要定义严谨的业务接口、处理跨系统集成（如 SNS 接入配置）或需要 AI Agent 深度参与设计的服务时。
    * **文档参考**：`.agent/skills/bcc_compiler/SKILL.md`

3.  **Web 层 (LiveView / HTML / JSON)**
    * **命令**：`mix phx.gen.live` (推荐), `mix phx.gen.html`, `mix phx.gen.json`
    * **场景**：快速生成增删改查的前端页面或 API 接口。
    * **最佳实践**：生成后，立即删除不需要的字段和页面，将其作为“脚手架”而非最终代码。

3.  **仅数据库表 (Schema Only)**
    * **命令**：`mix phx.gen.schema`
    * **场景**：用于关联表或不需要 Context 封装的底层数据结构。

4.  **自定义迁移**
    * **命令**：`mix ecto.gen.migration name_of_operation`
    * **规则**：永远不要手动创建迁移文件，必须使用生成器以确保时间戳顺序正确。

### 8.2 常用 Mix 命令清单 (Essential Commands)

你应该将以下命令视为肌肉记忆：

#### 依赖管理与编译
* `mix deps.get `  `mix compile`：编译项目（注意警告）。
* `mix clean`：清理构建工件（遇到诡异编译问题时的第一招）。

#### 代码质量与测试
* `mix format`：**提交前必跑**。保持代码风格统一。
* `mix test`：运行所有测试。
* `mix test test/path/to/file.exs:24`：仅运行特定行号的测试（大幅提升 TDD 速度）。
* `mix credo` (需安装)：静态代码分析，检查代码风格和潜在错误。

#### Phoenix 专用
* `mix phx.routes`：查看所有定义的路由及其对应的 Controller/LiveView（调试 404 时的神器）。
* `mix phx.server`：
* `iex -S mix phx.server`：启动服务器并进入交互式终端（调试用）。

#### 数据库操作
* `mix ecto.migrate`：运行待处理的数据库迁移。
* `mix ecto.rollback`：回滚上一次迁移（开发阶段常用）。
* `mix ecto.reset`：删库、建库、跑迁移、跑种子数据（一条龙重置）。
