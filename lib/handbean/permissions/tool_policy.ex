defmodule Handbean.Permissions.ToolPolicy do
  @moduledoc """
  Compiled workspace tool permission policy.
  """

  alias Handbean.Browser.Policy, as: BrowserPolicy
  alias Handbean.Permissions.{ApprovalMode, Boundary, Matcher}

  require Logger

  defstruct default_mode: :auto,
            allow: [],
            deny: [],
            per_tool: %{},
            mcp: %{},
            overrides: %{},
            session_allow: [],
            settings_error: nil,
            workspace_root: nil

  @type t :: %__MODULE__{
          default_mode: ApprovalMode.t(),
          allow: [String.t()],
          deny: [String.t()],
          per_tool: %{String.t() => ApprovalMode.t()},
          mcp: %{String.t() => ApprovalMode.t()},
          overrides: %{String.t() => ApprovalMode.t()},
          session_allow: [String.t()],
          settings_error: atom() | nil,
          workspace_root: String.t() | nil
        }

  @spec from_workspace(Path.t() | nil, map(), [String.t()]) :: t()
  def from_workspace(workspace_root, overrides \\ %{}, session_allow \\ []) do
    from_workspace(workspace_root, workspace_root, overrides, session_allow)
  end

  @spec from_workspace(Path.t() | nil, Path.t() | nil, map(), [String.t()]) :: t()
  def from_workspace(workspace_root, checkout_root, overrides, session_allow)

  def from_workspace(workspace_root, checkout_root, overrides, session_allow)
      when is_binary(workspace_root) and workspace_root != "" do
    policy =
      case Handbean.WorkspaceSettings.load(workspace_root) do
        {:ok, settings} ->
          from_settings(settings, overrides, session_allow)

        {:error, _reason} ->
          Logger.error("[ToolPolicy] workspace settings unavailable; denying tool execution")
          %__MODULE__{default_mode: :deny, settings_error: :unavailable}
      end

    Map.put(policy, :workspace_root, checkout_root)
  end

  def from_workspace(_workspace_root, checkout_root, overrides, session_allow) do
    %__MODULE__{
      default_mode: :deny,
      allow: ["mem_*", "web_fetch", "browser", "open_url", "publish_media"],
      overrides: normalize_overrides(overrides),
      session_allow: string_list(session_allow),
      workspace_root: checkout_root
    }
  end

  @spec from_settings(map(), map(), [String.t()]) :: t()
  def from_settings(settings, overrides \\ %{}, session_allow \\ []) when is_map(settings) do
    tools = Map.get(settings, "tools", %{})

    if valid_tools_settings?(tools) do
      %__MODULE__{
        default_mode: ApprovalMode.parse(Map.get(tools, "default_mode", :auto), :deny),
        allow: string_list(Map.get(tools, "allow", [])),
        deny: string_list(Map.get(tools, "deny", [])),
        per_tool: parse_mode_map(Map.get(tools, "per_tool", %{})),
        mcp: parse_mode_map(Map.get(tools, "mcp", %{})),
        overrides: normalize_overrides(overrides),
        session_allow: string_list(session_allow)
      }
    else
      %__MODULE__{default_mode: :deny, settings_error: :invalid_tools}
    end
  end

  @builtin_prompt_tools MapSet.new(["ext__term_send"])
  @mount_prompt_tools MapSet.new(["ext__mount__apply", "ext__mount__drop"])

  @type assessment :: %{
          decision: ApprovalMode.t(),
          requirement: map() | nil,
          reason: term() | nil
        }

  @doc "Evaluate ordinary tool policy together with checkout/workspace boundaries."
  @spec assess(t(), map(), map()) :: assessment()
  def assess(%__MODULE__{} = policy, call, context \\ %{})
      when is_map(call) and is_map(context) do
    ordinary = decision(policy, call)

    case Boundary.requirement(call, context) do
      {:deny, reason} ->
        %{decision: :deny, requirement: nil, reason: reason}

      nil ->
        %{decision: ordinary, requirement: nil, reason: nil}

      requirement when is_map(requirement) ->
        boundary_decision =
          cond do
            policy.default_mode == :deny -> :deny
            ordinary in [:deny, :prompt] -> ordinary
            policy.default_mode == :yolo -> :auto
            true -> :prompt
          end

        %{decision: boundary_decision, requirement: requirement, reason: nil}
    end
  end

  @spec decision(t(), map()) :: ApprovalMode.t()
  def decision(%__MODULE__{settings_error: error}, call) when not is_nil(error) and is_map(call),
    do: :deny

  def decision(%__MODULE__{} = policy, call) when is_map(call) do
    name = to_string(Handbean.Utils.SafeMap.get_any(call, :name, "name") || "")

    cond do
      Map.get(policy.overrides, name) == :deny ->
        :deny

      Enum.any?(policy.deny, &Matcher.match?(&1, call)) ->
        :deny

      # Credential paths are a hard reject. Allow rules, session grants,
      # per-tool auto, and unsandboxed approval cannot release them, and they
      # are not sent to auto-review.
      sensitive_call?(policy, call) ->
        :deny

      # Explicit per-tool prompts are a workspace boundary, including in YOLO.
      # They may strengthen capability-specific behavior but never weaken a hard deny.
      Map.get(policy.per_tool, name) == :prompt ->
        :prompt

      # Native host independently approves the app and every input. Workspace
      # rules (including yolo) cannot grant desktop control or remember it.
      name == "computer" ->
        computer_decision(policy, call)

      name == "schedule" ->
        schedule_decision(policy, call)

      # Capability deny: wrapping agent-browser stays denied even when bash
      # leaves the OS sandbox. YOLO skips this deny below.
      bash_browser_mode = bash_browser_decision(policy, name, call) ->
        bash_browser_mode

      Map.get(policy.per_tool, name) == :deny ->
        :deny

      # Allow rules and session grants were given for sandboxed execution.
      # Leaving the OS sandbox is a fresh decision, except in yolo.
      # Native Windows has no OS sandbox, so every bash call uses this gate.
      unsandboxed_bash?(name, call) ->
        escalate(policy)

      # Applying a subagent worktree writes an unreviewed diff into the workspace.
      worktree_apply?(name, call) ->
        escalate(policy)

      # Session grants remember a pattern, not the whole tool. They stay under
      # the unsandboxed and worktree gates, so one "this session" click cannot
      # skip later unrelated prompts or leave the sandbox.
      Enum.any?(policy.session_allow, &Matcher.match?(&1, call)) ->
        :auto

      Map.has_key?(policy.per_tool, name) ->
        release(Map.fetch!(policy.per_tool, name))

      Map.has_key?(policy.overrides, name) ->
        release(Map.fetch!(policy.overrides, name))

      mcp_mode = mcp_decision(policy, name) ->
        release(mcp_mode)

      browser_mode = browser_decision(policy, name, call) ->
        browser_mode

      Enum.any?(policy.allow, &Matcher.match?(&1, call)) ->
        :auto

      bash_browser_mode = bash_browser_decision(policy, name, call) ->
        bash_browser_mode

      raw_sql_mode = raw_sql_decision(policy, name) ->
        raw_sql_mode

      capability_prompt?(policy, name) ->
        :prompt

      true ->
        release(policy.default_mode)
    end
  end

  # YOLO auto-approves the gates that full access still asks about, and the
  @schedule_prompt_actions MapSet.new(["create", "run_now"])

  defp schedule_decision(policy, call) do
    input = Handbean.Utils.SafeMap.get_any(call, :input, "input") || %{}
    action = to_string(Handbean.Utils.SafeMap.get_any(input, "action", :action) || "")

    cond do
      action in ["list", "get", "history", "pause", "resume", "delete"] ->
        :auto

      # A one-shot appears as a card. The switch is the control, so creating
      # or retiming it does not stop for approval.
      once_schedule?(input) and action in ["create", "update"] ->
        :auto

      action == "update" and not schedule_update_prompts?(input) ->
        :auto

      policy.default_mode == :yolo ->
        :auto

      action in @schedule_prompt_actions or schedule_update_prompts?(input) ->
        :prompt

      true ->
        :prompt
    end
  end

  defp once_schedule?(input) do
    rule = Handbean.Utils.SafeMap.get_any(input, "rule", :rule)

    is_map(rule) and
      Handbean.Utils.SafeMap.get_any(rule, "kind", :kind) in ["once", :once]
  end

  defp schedule_update_prompts?(input) do
    Map.has_key?(input, "rule") or Map.has_key?(input, :rule) or
      Map.has_key?(input, "instruction") or Map.has_key?(input, :instruction)
  end

  defp computer_decision(policy, call) do
    input = Handbean.Utils.SafeMap.get_any(call, :input, "input") || %{}

    action = Handbean.Utils.SafeMap.get_any(input, "action", :action)

    cond do
      action == "stop" -> :auto
      not Handbean.ComputerUse.enabled?() -> :deny
      action in ["list", "observe"] -> :auto
      policy.default_mode == :deny -> :deny
      true -> :prompt
    end
  end

  # YOLO auto-approves the gates that full access still asks about, and the
  # capability denies full access keeps. Built-in sensitive-path intercepts
  # (including `.env`) stay above this and still deny.
  defp escalate(%__MODULE__{default_mode: :deny}), do: :deny
  defp escalate(%__MODULE__{default_mode: :yolo}), do: :auto
  defp escalate(%__MODULE__{}), do: :prompt

  defp release(:yolo), do: :auto
  defp release(mode), do: mode

  defp raw_sql_decision(policy, "ext__beam__sql"), do: escalate(policy)
  defp raw_sql_decision(_policy, _name), do: nil

  # Full access (`default_mode: :auto`) means capability-level prompts do not
  # interrupt. Capability denies (local file URLs, bash wrapping agent-browser)
  # still apply. Safe mode (`:prompt`) and read-only (`:deny`) keep asking.
  # YOLO skips those prompts and capability denies. Host-privileged script
  # execution and system UI ask even in full-access workspaces.
  # Deny, per_tool, session overrides, and allow-list/always-allow stay above
  # this, so "allow for this session" / "always allow" are honored for them.
  defp capability_prompt?(%__MODULE__{default_mode: :yolo}, _name), do: false
  defp capability_prompt?(_policy, "run_elixir_script"), do: true
  defp capability_prompt?(_policy, "mix_project"), do: true

  defp capability_prompt?(%__MODULE__{default_mode: :auto}, name) do
    name in Handbean.ArtifactDelivery.tool_names()
  end

  defp capability_prompt?(_policy, name) do
    name in Handbean.ArtifactDelivery.tool_names() or
      MapSet.member?(@builtin_prompt_tools, name) or
      MapSet.member?(@mount_prompt_tools, name)
  end

  defp browser_decision(%__MODULE__{} = policy, "browser", call) do
    case classify_browser_call(call) do
      {:auto, _} -> nil
      {:prompt, _} when policy.default_mode in [:auto, :yolo] -> nil
      {:prompt, _} -> :prompt
      {:deny, _} when policy.default_mode == :yolo -> nil
      {:deny, _} -> :deny
    end
  end

  defp browser_decision(_policy, _name, _call), do: nil

  defp bash_browser_decision(%__MODULE__{default_mode: :yolo}, _name, _call), do: nil

  defp bash_browser_decision(_policy, "bash", call) do
    command = bash_command(call)

    if agent_browser_command?(command) do
      :deny
    end
  end

  defp bash_browser_decision(_policy, _name, _call), do: nil

  defp unsandboxed_bash?("bash", call) do
    input = Handbean.Utils.SafeMap.get_any(call, :input, "input") || %{}

    Map.get(input, "unsandboxed") == true or Map.get(input, :unsandboxed) == true or
      not Handbean.Platform.ProcessSandbox.os_enforced?()
  end

  defp unsandboxed_bash?(_name, _call), do: false

  @doc false
  @spec sensitive_call?(t(), map()) :: boolean()
  def sensitive_call?(%__MODULE__{} = policy, call) when is_map(call) do
    name = to_string(Handbean.Utils.SafeMap.get_any(call, :name, "name") || "")
    input = Handbean.Utils.SafeMap.get_any(call, :input, "input") || %{}
    root = policy.workspace_root

    case name do
      name when name in ["read", "write", "edit"] ->
        sensitive_input_path?(input, ["file_path"], root)

      "publish_media" ->
        sensitive_input_path?(input, ["path"], root)

      "grep" ->
        path = input_value(input, "path") || input_value(input, "file_path") || root
        is_binary(path) and path != "" and sensitive_path?(path, root)

      "code_search" ->
        case input_value(input, "path") do
          path when is_binary(path) and path != "" -> sensitive_path?(path, root)
          _ -> false
        end

      "bash" ->
        command = input_value(input, "command") || ""
        cwd = input_value(input, "cwd")
        base = if is_binary(cwd) and cwd != "", do: cwd, else: root
        Handbean.Security.PathValidator.reject_sensitive_command(to_string(command), base) != :ok

      "browser" ->
        args = Handbean.Utils.SafeMap.get_any(input, "args", :args) || []
        BrowserPolicy.sensitive_local_path?(args, root)

      _ ->
        false
    end
  end

  def sensitive_call?(_policy, _call), do: false

  defp sensitive_input_path?(input, keys, root) do
    Enum.any?(keys, fn key ->
      case input_value(input, key) do
        path when is_binary(path) and path != "" -> sensitive_path?(path, root)
        _ -> false
      end
    end)
  end

  defp sensitive_path?(path, root) do
    expanded = Handbean.Agent.Tool.Helpers.expand_tilde(path)

    lexical =
      if Path.type(expanded) == :absolute do
        expanded
      else
        path
      end

    resolved =
      cond do
        Path.type(expanded) == :absolute ->
          Path.expand(expanded)

        is_binary(root) and root != "" ->
          Path.expand(expanded, root)

        true ->
          nil
      end

    Handbean.Security.PathValidator.reject_sensitive(lexical) != :ok or
      (is_binary(resolved) and Handbean.Security.PathValidator.reject_resolved(resolved) != :ok)
  end

  defp input_value(input, "file_path"), do: map_value(input, "file_path", :file_path)
  defp input_value(input, "path"), do: map_value(input, "path", :path)
  defp input_value(input, "command"), do: map_value(input, "command", :command)
  defp input_value(input, "cwd"), do: map_value(input, "cwd", :cwd)
  defp input_value(_input, _key), do: nil

  defp map_value(input, string_key, atom_key) when is_map(input) do
    Map.get(input, string_key) || Map.get(input, atom_key)
  end

  defp map_value(_input, _string_key, _atom_key), do: nil

  defp worktree_apply?("task_status", call) do
    input = Handbean.Utils.SafeMap.get_any(call, :input, "input") || %{}
    Handbean.Utils.SafeMap.get_any(input, "action", :action) == "apply"
  end

  defp worktree_apply?(_name, _call), do: false

  defp bash_command(call) when is_map(call) do
    input = Handbean.Utils.SafeMap.get_any(call, :input, "input") || %{}
    Handbean.Utils.SafeMap.get_any(input, "command", :command) || ""
  end

  defp agent_browser_command?(command) when is_binary(command) do
    String.match?(command, ~r/(^|[;&|`\n]|&&|\|\|)\s*(npx\s+)?agent-browser(\s|$)/)
  end

  defp agent_browser_command?(_), do: false

  defp classify_browser_call(call) when is_map(call) do
    input = Handbean.Utils.SafeMap.get_any(call, :input, "input") || %{}

    if Handbean.Tool.Builtin.Browser.backend() == :webview do
      BrowserPolicy.classify_native(input)
    else
      args = Handbean.Utils.SafeMap.get_any(input, "args", :args) || []
      BrowserPolicy.classify(args)
    end
  end

  defp mcp_decision(%__MODULE__{mcp: mcp}, name) do
    cond do
      Map.has_key?(mcp, name) ->
        Map.fetch!(mcp, name)

      match =
          Enum.find(mcp, fn {pattern, _mode} ->
            Matcher.match?(pattern, %{name: name, input: %{}})
          end) ->
        elem(match, 1)

      true ->
        nil
    end
  end

  defp string_list(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp string_list(_), do: []

  defp valid_tools_settings?(tools) when is_map(tools) do
    Enum.all?(["allow", "deny"], fn key ->
      list = Map.get(tools, key, [])
      is_list(list) and Enum.all?(list, &is_binary/1)
    end) and Enum.all?(["per_tool", "mcp"], &is_map(Map.get(tools, &1, %{})))
  end

  defp valid_tools_settings?(_tools), do: false

  defp parse_mode_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), ApprovalMode.parse(value, :deny)} end)
  end

  defp parse_mode_map(_), do: %{}

  defp normalize_overrides(overrides) when is_map(overrides) do
    Map.new(overrides, fn {key, value} -> {to_string(key), ApprovalMode.parse(value, :deny)} end)
  end

  defp normalize_overrides(_), do: %{}
end
