defmodule Handbean.Plugins.Catalog do
  @moduledoc """
  Curated plugin catalog for the Plugins settings Discover tab, plus local
  directory import dispatch across Extensions and Skills.
  """

  alias Handbean.Extension.Settings, as: ExtensionSettings
  alias Handbean.Skills.Settings, as: SkillSettings

  @mcp_presets [
    %{
      id: "cat-mcp-github",
      mech: :mcp,
      name: "GitHub",
      version: "HTTP",
      source_label: "MCP",
      description: "访问 Issues、Pull Requests、Actions 状态与代码搜索。",
      url: "https://api.githubcopilot.com/mcp/",
      auth: "bearer"
    },
    %{
      id: "cat-mcp-linear",
      mech: :mcp,
      name: "Linear",
      version: "HTTP",
      source_label: "MCP",
      description: "读取、搜索和关联 Linear 团队 Issue、Cycle 与项目进度。",
      url: "https://mcp.linear.app/sse",
      auth: "bearer"
    },
    %{
      id: "cat-mcp-context7",
      mech: :mcp,
      name: "Context7",
      version: "HTTP",
      source_label: "MCP",
      description: "按版本拉取第三方框架与 SDK 的最新官方文档。",
      url: "https://mcp.context7.com/mcp",
      auth: "none"
    },
    %{
      id: "cat-mcp-sentry",
      mech: :mcp,
      name: "Sentry",
      version: "HTTP",
      source_label: "MCP",
      description: "查询线上异常堆栈、版本回归与高频错误分组。",
      url: "https://mcp.sentry.dev/sse",
      auth: "bearer"
    }
  ]

  @skill_templates [
    %{
      id: "cat-skill-code-review",
      mech: :skill,
      name: "code-review-checklist",
      version: nil,
      source_label: "Skill",
      description: "代码变更的边界、安全、并发与回归测试审查清单。",
      content: """
      ---
      name: code-review-checklist
      description: 代码变更的边界、安全、并发与回归测试审查清单。
      ---

      # Code Review Checklist

      1. 核对模块职责边界，确认未引入重复状态或越权调用。
      2. 检查输入校验、路径边界与凭据脱敏。
      3. 检查并发、超时与错误分支返回值。
      4. 确认新增或修改的用户可见行为有对应回归测试覆盖。
      """
    },
    %{
      id: "cat-skill-sql-tuning",
      mech: :skill,
      name: "sql-query-tuning",
      version: nil,
      source_label: "Skill",
      description: "分析慢查询执行计划、索引覆盖与事务锁等待。",
      content: """
      ---
      name: sql-query-tuning
      description: 分析慢查询执行计划、索引覆盖与事务锁等待。
      ---

      # SQL Query Tuning

      1. 使用 `EXPLAIN (ANALYZE, BUFFERS)` 获取真实执行计划。
      2. 识别全表扫描、行数估算偏差与排序溢盘。
      3. 给出的索引或改写方案需附带读写开销评估。
      """
    },
    %{
      id: "cat-skill-postmortem",
      mech: :skill,
      name: "incident-postmortem",
      version: nil,
      source_label: "Skill",
      description: "整理故障时间线、根因定位与后续修复验证项。",
      content: """
      ---
      name: incident-postmortem
      description: 整理故障时间线、根因定位与后续修复验证项。
      ---

      # Incident Postmortem

      1. 汇总影响范围、触发条件与恢复时间线。
      2. 区分直接触发因素与底层架构根因。
      3. 输出可验证的修复项与回归测试计划。
      """
    }
  ]

  @extension_templates [
    %{
      id: "cat-ext-workspace-ping",
      mech: :ext,
      name: "workspace-ping",
      version: "0.1.0",
      source_label: "扩展",
      description: "提供工作区连通性自检工具与基础状态返回。",
      manifest: %{
        "name" => "workspace-ping",
        "version" => "0.1.0",
        "description" => "提供工作区连通性自检工具与基础状态返回。",
        "entry" => "extension.ex",
        "enabled" => true,
        "tools" => [
          %{
            "name" => "ping",
            "description" => "Return pong"
          }
        ]
      },
      entry_code: """
      defmodule HandbeanExt.WorkspacePing.Tool do
        @behaviour Handbean.Agent.Tool

        @impl true
        def name, do: "ext__workspace-ping__ping"

        @impl true
        def description, do: "Check workspace extension connectivity and return pong."

        @impl true
        def input_schema do
          %{
            "type" => "object",
            "properties" => %{},
            "additionalProperties" => false
          }
        end

        @impl true
        def execute(_input, _context) do
          {:ok, "pong"}
        end
      end
      """
    },
    %{
      id: "cat-ext-run-audit",
      mech: :ext,
      name: "run-audit-logger",
      version: "0.1.0",
      source_label: "扩展",
      description: "监听代理生命周期事件并记录轻量执行摘要。",
      manifest: %{
        "name" => "run-audit-logger",
        "version" => "0.1.0",
        "description" => "监听代理生命周期事件并记录轻量执行摘要。",
        "entry" => "extension.ex",
        "enabled" => true,
        "hooks" => ["agent_end"]
      },
      entry_code: """
      defmodule HandbeanExt.RunAuditLogger.Hook do
        @behaviour Handbean.Extension.Hook

        @impl true
        def handle_event(%{name: :agent_end}, _ctx), do: :ok
        def handle_event(_event, _ctx), do: :ok
      end
      """
    }
  ]

  @doc """
  Returns all curated catalog entries annotated with `installed: boolean()`.
  """
  @spec list(map()) :: [map()]
  def list(installed_sets \\ %{}) do
    installed_mcp = Map.get(installed_sets, :mcp, MapSet.new())
    installed_skills = Map.get(installed_sets, :skill, MapSet.new())
    installed_exts = Map.get(installed_sets, :ext, MapSet.new())

    mcp =
      Enum.map(@mcp_presets, fn item ->
        Map.put(item, :installed, MapSet.member?(installed_mcp, String.downcase(item.name)))
      end)

    skills =
      Enum.map(@skill_templates, fn item ->
        Map.put(item, :installed, MapSet.member?(installed_skills, String.downcase(item.name)))
      end)

    exts =
      Enum.map(@extension_templates, fn item ->
        Map.put(item, :installed, MapSet.member?(installed_exts, String.downcase(item.name)))
      end)

    mcp ++ skills ++ exts
  end

  @doc """
  Finds a single catalog entry by ID.
  """
  @spec get(String.t()) :: {:ok, map()} | {:error, String.t()}
  def get(id) when is_binary(id) do
    all = @mcp_presets ++ @skill_templates ++ @extension_templates

    case Enum.find(all, &(&1.id == id)) do
      nil -> {:error, "模板不存在"}
      item -> {:ok, item}
    end
  end

  @doc """
  Installs a curated Skill or Extension catalog entry into `"workspace"` or `"user"`.
  """
  @spec install(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def install(id, scope, opts \\ []) when is_binary(id) and scope in ["workspace", "user"] do
    with {:ok, item} <- get(id) do
      case item.mech do
        :skill ->
          SkillSettings.install_template(item, scope,
            workspace: Keyword.get(opts, :project),
            user_home: Keyword.get(opts, :user_home, Handbean.Home.path())
          )

        :ext ->
          ExtensionSettings.install_template(item, scope, opts)

        :mcp ->
          {:error, "MCP 预设请通过连接配置弹窗添加"}
      end
    end
  end

  @doc """
  Imports a local directory containing either an Extension (`extension.json` / `manifest.json`)
  or a Skill (`SKILL.md`).
  """
  @spec import_from_dir(String.t(), String.t(), keyword()) ::
          {:ok, {:ext | :skill, String.t()}} | {:error, String.t()}
  def import_from_dir(source_dir, scope, opts \\ [])
      when is_binary(source_dir) and scope in ["workspace", "user"] do
    expanded = Path.expand(String.trim(source_dir))

    cond do
      not File.dir?(expanded) ->
        {:error, "目录不存在: #{source_dir}"}

      File.exists?(Path.join(expanded, "extension.json")) or
          File.exists?(Path.join(expanded, "manifest.json")) ->
        case ExtensionSettings.import_from_dir(expanded, scope, opts) do
          {:ok, name} -> {:ok, {:ext, name}}
          {:error, reason} -> {:error, reason}
        end

      File.exists?(Path.join(expanded, "SKILL.md")) ->
        skill_opts = [
          workspace: Keyword.get(opts, :project),
          user_home: Keyword.get(opts, :user_home, Handbean.Home.path())
        ]

        case SkillSettings.import_from_dir(expanded, scope, skill_opts) do
          {:ok, name} -> {:ok, {:skill, name}}
          {:error, reason} -> {:error, reason}
        end

      true ->
        {:error, "该目录下未找到 extension.json 或 SKILL.md"}
    end
  end
end
