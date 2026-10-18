defmodule Handbean.Agent.Config do
  @moduledoc """
  Agent configuration struct.

  Holds provider, tools, middleware, and runtime settings.
  """

  alias Handbean.Memory.{Policy, PromptPolicy}
  alias Handbean.Agent.ContextLoader
  alias Handbean.Skills.{Loader, PromptFormatter}

  require Logger

  # Module attributes used as defaults (defined before defstruct to allow use in struct default)
  @default_context %{}
  @default_tool_timeout 60_000

  defstruct [
    :provider,
    :system_prompt,
    :working_directory,
    :workspace_path,
    :model,
    :max_turns,
    :max_budget_cents,
    :timeout_ms,
    :until_tool,
    :reasoning_level,
    :memory,
    :middleware,
    :provider_config,
    :max_messages,
    :max_tokens,
    :compaction,
    :on_compaction,
    :on_compaction_complete,
    :allowed_tools,
    :runner_pid,
    :run_task_supervisor,
    :run_id,
    :advisor,
    source: nil,
    skill_paths: [],
    delegated?: false,
    builtin_memory_enabled: true,
    context: @default_context,
    tool_timeout: @default_tool_timeout
  ]

  @type t :: %__MODULE__{
          provider: module(),
          system_prompt: String.t() | nil,
          working_directory: String.t() | nil,
          workspace_path: String.t() | nil,
          model: String.t(),
          max_turns: pos_integer() | nil,
          max_budget_cents: pos_integer() | nil,
          timeout_ms: pos_integer(),
          tool_timeout: pos_integer(),
          allowed_tools: [String.t()] | nil,
          runner_pid: pid() | nil,
          run_task_supervisor: GenServer.server() | nil,
          run_id: String.t() | nil,
          advisor: map() | nil,
          skill_paths: [String.t()],
          delegated?: boolean(),
          builtin_memory_enabled: boolean(),
          until_tool: String.t() | nil,
          reasoning_level: String.t(),
          memory: module() | nil,
          context: map(),
          middleware: [module()] | nil,
          provider_config: map(),
          max_messages: pos_integer(),
          max_tokens: pos_integer(),
          compaction: %{
            reserve_tokens: pos_integer(),
            keep_recent_tokens: pos_integer(),
            fallback: :truncate
          },
          on_compaction: (list(), t() -> any()) | nil,
          on_compaction_complete: (map(), t() -> any()) | nil
        }

  @default_model "step-router-v1"
  @default_timeout_ms 300_000
  @default_max_messages 200
  @default_max_tokens 200_000
  @default_compaction %{reserve_tokens: 16_384, keep_recent_tokens: 20_000, fallback: :truncate}

  @doc """
  Build configuration from keyword options.

  Provider selection priority:
    1. Explicit `:provider` module in opts
    2. `:test_provider` application env, used by tests so a LiveView send does not call a catalog adapter
    3. `provider_config[:provider]` → maps "stepfun" to StepFun, "openai" to OpenAI Responses, "openai-compat" to OpenAICompat
    4. Default → `Handbean.Agent.Provider.OpenAICompat`
  """
  @spec from_opts(keyword()) :: t()
  def from_opts(opts \\ []) do
    provider_config = Keyword.get(opts, :provider_config, %{})
    builtin_memory_enabled = builtin_memory_enabled(opts)
    opts = Keyword.put(opts, :builtin_memory_enabled, builtin_memory_enabled)

    provider =
      Keyword.get(opts, :provider) ||
        test_provider_module() ||
        resolve_provider_from_api(
          provider_config[:api],
          Keyword.get(opts, :model),
          provider_config[:provider]
        )

    observational = observational_config(opts)

    %__MODULE__{
      provider: provider,
      allowed_tools: Keyword.get(opts, :allowed_tools),
      runner_pid: Keyword.get(opts, :runner_pid),
      run_task_supervisor: Keyword.get(opts, :run_task_supervisor),
      run_id: Keyword.get(opts, :run_id),
      advisor: Keyword.get(opts, :advisor),
      source: Keyword.get(opts, :source),
      skill_paths: List.wrap(Keyword.get(opts, :skill_paths, [])),
      delegated?: Keyword.get(opts, :delegated?, false),
      builtin_memory_enabled: builtin_memory_enabled,
      system_prompt: build_system_prompt(opts, provider),
      working_directory: working_directory(opts),
      workspace_path: Keyword.get(opts, :workspace_path),
      model: Keyword.get(opts, :model, @default_model),
      max_turns: Keyword.get(opts, :max_turns),
      max_budget_cents: Keyword.get(opts, :max_budget_cents),
      timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms),
      tool_timeout: Keyword.get(opts, :tool_timeout, @default_tool_timeout),
      until_tool: Keyword.get(opts, :until_tool),
      reasoning_level:
        Keyword.get(
          opts,
          :reasoning_level,
          Handbean.Settings.ModelAISettings.defaults().reasoning
        ),
      memory: Keyword.get(opts, :memory),
      context: build_context(opts, observational),
      middleware: Keyword.get(opts, :middleware, default_middleware(observational)),
      provider_config: provider_config,
      max_messages: Keyword.get(opts, :max_messages, @default_max_messages),
      max_tokens: context_window(opts, provider_config),
      compaction: build_compaction(opts),
      on_compaction: Keyword.get(opts, :on_compaction),
      on_compaction_complete: Keyword.get(opts, :on_compaction_complete)
    }
  end

  # `Config.max_tokens` is the request context window. Provider
  # `:max_tokens` remains the independent response-output limit.
  defp context_window(opts, provider_config) do
    case Keyword.get(opts, :max_tokens) do
      value when is_integer(value) and value > 0 ->
        value

      _ ->
        model_meta = provider_config[:model_meta] || provider_config["model_meta"] || %{}

        case model_meta["contextWindow"] ||
               model_meta[:context_window] ||
               model_meta["context_window"] do
          value when is_integer(value) and value > 0 -> value
          _ -> @default_max_tokens
        end
    end
  end

  @doc """
  Resolve provider module from model configuration.

  Mapping:
    - `provider_config[:provider] == "zenmux"` → `Handbean.Agent.Provider.ZenMux`
    - `provider_config[:provider] == "openrouter"` → `Handbean.Agent.Provider.OpenRouter`
    - `provider_config[:provider] == "deepseek"` → `Handbean.Agent.Provider.DeepSeek`
    - `provider_config[:provider] == "ollama"` → `Handbean.Agent.Provider.Ollama`
    - `provider_config[:provider] == "opencode-go"` → `Handbean.Agent.Provider.OpenCodeGo`
    - `provider_config[:api] == :anthropic` → `Handbean.Agent.Provider.Anthropic`
      (even when the provider key is StepFun/Step Plan; this is the
      Anthropic Messages wire protocol)
    - `provider_config[:provider] == "stepfun"` → `Handbean.Agent.Provider.StepFun`
    - `provider_config[:api] == :stepfun` → `Handbean.Agent.Provider.StepFun`
    - `provider_config[:provider] == "openai"` → `Handbean.Agent.Provider.OpenAI`
    - `provider_config[:api] == :openai_responses` → `Handbean.Agent.Provider.OpenAI`
    - `provider_config[:api] == :anthropic` → `Handbean.Agent.Provider.Anthropic`
    - `provider_config[:provider] == "cursor"` / `api == :cursor_agent` → `Handbean.Agent.Provider.Cursor`
    - `provider_config[:provider] == "openai-compat"` → `Handbean.Agent.Provider.OpenAICompat`
    - default → `Handbean.Agent.Provider.OpenAICompat`
  """
  @spec resolve_provider_from_api(atom() | nil, String.t() | nil, String.t() | nil) :: module()
  def resolve_provider_from_api(:openai_codex_responses, _model, _provider),
    do: Handbean.Agent.Provider.Codex

  def resolve_provider_from_api(_api, _model, "openai_codex"), do: Handbean.Agent.Provider.Codex

  def resolve_provider_from_api(:anthropic, _model, _provider),
    do: Handbean.Agent.Provider.Anthropic

  def resolve_provider_from_api(_api, _model, "zenmux"), do: Handbean.Agent.Provider.ZenMux

  def resolve_provider_from_api(_api, _model, "openrouter"),
    do: Handbean.Agent.Provider.OpenRouter

  def resolve_provider_from_api(_api, _model, "deepseek"), do: Handbean.Agent.Provider.DeepSeek
  def resolve_provider_from_api(_api, _model, "ollama"), do: Handbean.Agent.Provider.Ollama

  def resolve_provider_from_api(_api, _model, "opencode-go"),
    do: Handbean.Agent.Provider.OpenCodeGo

  def resolve_provider_from_api(_api, _model, "cursor"), do: Handbean.Agent.Provider.Cursor

  def resolve_provider_from_api(:cursor_agent, _model, _provider),
    do: Handbean.Agent.Provider.Cursor

  def resolve_provider_from_api(_api, _model, "stepfun"), do: Handbean.Agent.Provider.StepFun

  def resolve_provider_from_api(_api, _model, "openai-compat"),
    do: Handbean.Agent.Provider.OpenAICompat

  def resolve_provider_from_api(_api, _model, "openai"), do: Handbean.Agent.Provider.OpenAI
  def resolve_provider_from_api(:stepfun, _model, _provider), do: Handbean.Agent.Provider.StepFun

  def resolve_provider_from_api(:openai_responses, _model, _provider),
    do: Handbean.Agent.Provider.OpenAI

  def resolve_provider_from_api(_api, _model, _provider), do: Handbean.Agent.Provider.OpenAICompat

  defp observational_config(opts) do
    enabled = Keyword.fetch!(opts, :builtin_memory_enabled)

    om =
      opts
      |> Keyword.get(:om, %{})
      |> then(&if(is_map(&1), do: &1, else: %{}))
      |> Map.delete("enabled")
      |> Map.put(:enabled, enabled)

    Handbean.Memory.ObservationalConfig.from_runtime(om)
  end

  defp builtin_memory_enabled(opts) do
    case Keyword.fetch(opts, :builtin_memory_enabled) do
      {:ok, enabled} when is_boolean(enabled) ->
        enabled

      _ ->
        path = Keyword.get(opts, :workspace_path) || Keyword.get(opts, :working_directory)

        if is_binary(path) and path != "",
          do: Handbean.WorkspaceSettings.builtin_memory_enabled(path),
          else: true
    end
  end

  defp build_context(opts, observational) do
    om = if is_map(Keyword.get(opts, :om)), do: Keyword.get(opts, :om), else: %{}

    opts
    |> Keyword.get(:context, @default_context)
    |> Map.merge(%{
      workspace_id: Keyword.get(opts, :workspace_id),
      workspace_path: Keyword.get(opts, :workspace_path),
      checkout_path: Keyword.get(opts, :working_directory),
      conversation_id: Keyword.get(opts, :conversation_id),
      created_by_conversation_id: Keyword.get(opts, :created_by_conversation_id),
      run_id: Keyword.get(opts, :run_id),
      source: Keyword.get(opts, :source),
      user_time_zone: Keyword.get(opts, :user_time_zone),
      thread_origin_conversation_id:
        get_in(Keyword.get(opts, :origin) || %{}, ["conversation_id"]),
      thread_handoff_id: get_in(Keyword.get(opts, :origin) || %{}, ["handoff_id"]),
      delegated_read_only: Keyword.get(opts, :delegated_read_only, false),
      delegated_approval: Keyword.get(opts, :delegated_approval),
      browser_runner: Keyword.get(opts, :browser_runner),
      memory_scope: om_value(om, :memory_scope),
      privacy_mode: om_value(om, :privacy_mode),
      observational: observational
    })
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp om_value(om, key), do: Map.get(om, key, Map.get(om, Atom.to_string(key)))

  defp test_provider_module do
    case Application.get_env(:handbean, :test_provider) do
      %{module: module} when is_atom(module) -> module
      _ -> nil
    end
  end

  defp working_directory(opts) do
    case Keyword.get(opts, :working_directory) do
      path when is_binary(path) and path != "" -> path
      _ -> nil
    end
  end

  defp build_system_prompt(opts, provider) do
    base =
      Keyword.get_lazy(opts, :system_prompt, fn ->
        if Keyword.get(opts, :chat_scope) == :free,
          do: free_chat_system_prompt(),
          else: default_system_prompt(opts)
      end)

    base
    |> maybe_inject_thread_context(opts)
    |> maybe_inject_advisor(opts)
    |> maybe_inject_workspace_contract(opts)
    |> maybe_inject_project_context(opts)
    |> maybe_inject_skills(opts)
    |> maybe_append_task_instructions(opts)
    |> maybe_inject_inline_previews(opts)
    |> append_prompt_section(Handbean.Tool.Deferred.prompt_section(opts))
    |> maybe_append_model_context(provider)
    |> append_prompt_section(Handbean.Agent.HostEnvironment.describe())
  end

  defp maybe_inject_thread_context(system_prompt, opts) do
    conversation_id = Keyword.get(opts, :conversation_id)
    created_by = Keyword.get(opts, :created_by_conversation_id)
    origin = get_in(Keyword.get(opts, :origin) || %{}, ["conversation_id"])
    handoff_id = get_in(Keyword.get(opts, :origin) || %{}, ["handoff_id"])

    if is_binary(conversation_id) and Keyword.get(opts, :chat_scope) != :free do
      details =
        [
          "- conversation_id: #{conversation_id}",
          if(is_binary(created_by), do: "- created_by_conversation_id: #{created_by}"),
          if(is_binary(origin), do: "- active_origin_conversation_id: #{origin}"),
          if(is_binary(handoff_id), do: "- active_handoff_id: #{handoff_id}")
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")

      append_prompt_section(
        system_prompt,
        """

        ## Current thread

        #{details}

        `created_by_conversation_id`, when present, records which thread created this
        thread. It is provenance, not an automatic reply target. An active origin,
        when present, identifies the thread that sent the message which started this
        run; it also does not require a reply. This thread runs independently. To
        message any authorized thread whose id you know, call `send_thread_message`
        with that explicit thread id. Finishing this run does not send a message
        automatically.
        """
      )
    else
      system_prompt
    end
  end

  defp maybe_append_model_context(prompt, provider) do
    if Handbean.Agent.Provider.context_editing?(provider) do
      append_prompt_section(prompt, Handbean.Agent.ModelContext.prompt_section())
    else
      prompt
    end
  end

  defp maybe_inject_inline_previews(system_prompt, opts) do
    if Keyword.get(opts, :source) == :live_view do
      append_prompt_section(system_prompt, """

      ## Inline HTML previews

      This Web chat renders fenced `html` and `widget` blocks as inline previews.
      When the user requests an interactive visualization, calculator, or small UI,
      return a self-contained HTML block with inline CSS and JavaScript. Use ordinary
      Markdown for explanations; do not create a widget unless it helps the request.
      Content appears while streaming; JavaScript runs only after the closing fence.
      The iframe has an opaque origin: no parent DOM, cookies, storage, host tools,
      external scripts, network fetches, or form submissions. Use local data and
      vanilla JavaScript; no CDN dependencies. Make layouts responsive. Interaction
      stays inside the widget and cannot send messages or perform host actions.
      Never claim a preview was verified unless you actually tested it.
      """)
    else
      system_prompt
    end
  end

  defp free_chat_system_prompt do
    """
    You are Handbean, a conversational assistant. This chat is not bound to a project.

    Answer from the conversation. You do not have a workspace, shell, or file tools.
    Do not claim to have read, edited, or executed anything on the user's machine.
    If device_calendar or device_alarm is exposed, use it when the user asks about
    their calendar or a clock alarm. Do not claim an event was saved or an alarm
    was set unless the tool result says so.
    """
  end

  defp maybe_inject_advisor(system_prompt, opts) do
    if Handbean.Agent.Advisor.tool_visible?(Keyword.get(opts, :advisor)) do
      append_prompt_section(
        system_prompt,
        "\n\n## Advisor\n\nAn advisor tool is available. Call it only when a second judgment would help. Its answer is advice, not permission to act.\n"
      )
    else
      system_prompt
    end
  end

  defp maybe_append_task_instructions(system_prompt, opts) do
    case Keyword.get(opts, :task_instructions) do
      text when is_binary(text) ->
        case String.trim(text) do
          "" ->
            system_prompt

          trimmed ->
            append_prompt_section(
              system_prompt,
              "\n\n## Task instructions\n\n" <> trimmed <> "\n"
            )
        end

      _ ->
        system_prompt
    end
  end

  defp maybe_inject_workspace_contract(system_prompt, opts) do
    cond do
      Keyword.get(opts, :chat_scope) == :free ->
        system_prompt

      Keyword.has_key?(opts, :system_prompt) ->
        system_prompt

      true ->
        inject_workspace_contract(system_prompt, opts)
    end
  end

  defp inject_workspace_contract(system_prompt, opts) do
    working_directory = Keyword.get(opts, :working_directory, File.cwd!())
    workspace_path = Keyword.get(opts, :workspace_path)

    system_prompt <>
      """

      ## Current checkout

      Current checkout: #{working_directory}
      #{workspace_identity_line(workspace_path, working_directory)}
      #{workspace_tool_contract(working_directory)}
      """
  end

  defp workspace_identity_line(workspace_path, working_directory)
       when is_binary(workspace_path) and workspace_path != "" and
              workspace_path != working_directory do
    "Workspace: #{workspace_path}. Same-repo linked worktrees stay in this workspace; do not ask the user to switch workspaces to read another checkout."
  end

  defp workspace_identity_line(_workspace_path, _working_directory), do: ""

  defp workspace_tool_contract(working_directory) do
    tools =
      cond do
        Handbean.Host.shell?() ->
          "`read`, `edit`, `write`, `bash`, `grep`, `file_search`, `code_search`"

        Handbean.Host.host_script?() ->
          "`read`, `edit`, `write`, `grep`, `file_search`, `code_search`, `run_elixir_script`"

        true ->
          "`read`, `edit`, `write`, `grep`, `file_search`, `code_search`"
      end

    extra =
      cond do
        Handbean.Host.shell?() ->
          "The `bash` tool runs commands from the current checkout by default. Do not prefix commands with `cd #{working_directory} &&`; call the command directly, or set the `cwd` argument only when you need to run inside a subdirectory of the checkout."

        true ->
          ""
      end

    """
    Prefer checkout-relative file paths in tool calls (#{tools}), for example `workspace-check.txt` or `reports/summary.md`. Relative paths are joined with the current checkout; do not prepend the checkout directory name. The checkout is NOT the filesystem root `/`: `/workspace-check.txt` refers to the filesystem root, not this checkout. Absolute and `~`-expanded paths remain subject to tool path permissions; use paths inside the current checkout for generated files. Ask the user to open another conversation on that checkout instead of switching workspaces.

    #{extra}
    """
  end

  defp maybe_inject_project_context(system_prompt, opts) do
    # If the user explicitly provided a system_prompt, skip context injection
    # (host execution facts are still appended). Otherwise, inject AGENTS.md context.
    # Free chats have no workspace, so they never load workspace context.
    if Keyword.has_key?(opts, :system_prompt) or Keyword.get(opts, :chat_scope) == :free do
      system_prompt
    else
      workspace = Keyword.get(opts, :working_directory, File.cwd!())
      paths = ContextLoader.discover(workspace)
      {:ok, context} = ContextLoader.load(paths)
      {context, _truncated?} = ContextLoader.truncate(context)
      ContextLoader.inject(system_prompt, context)
    end
  end

  defp maybe_inject_skills(system_prompt, opts) do
    cond do
      not Keyword.get(opts, :skills, false) ->
        system_prompt

      Keyword.has_key?(opts, :system_prompt) and
          not Keyword.get(opts, :inject_skills_into_custom_prompt, false) ->
        system_prompt

      true ->
        opts
        |> load_skills()
        |> PromptFormatter.format_available_skills()
        |> then(&append_prompt_section(system_prompt, &1))
    end
  end

  defp load_skills(opts) do
    working_directory = Keyword.get(opts, :working_directory, File.cwd!())

    result =
      Loader.load(workspace: working_directory, skill_paths: Keyword.get(opts, :skill_paths, []))

    log_skill_diagnostics(result.diagnostics)

    result.skills
  end

  defp log_skill_diagnostics(diagnostics) do
    Enum.each(diagnostics, fn diagnostic ->
      level = if diagnostic[:type] == :error, do: :warning, else: :info
      path = Map.get(diagnostic, :path, "unknown path")
      message = Map.get(diagnostic, :message, inspect(diagnostic))

      Logger.log(level, "[Skills] #{message} (#{path})")
    end)
  end

  defp append_prompt_section(system_prompt, ""), do: system_prompt
  defp append_prompt_section(nil, section), do: section
  defp append_prompt_section(system_prompt, section), do: system_prompt <> section

  defp build_compaction(opts) do
    raw = Keyword.get(opts, :compaction, %{}) |> Enum.into(%{})

    %{
      reserve_tokens: Map.get(raw, :reserve_tokens, @default_compaction.reserve_tokens),
      keep_recent_tokens:
        Map.get(raw, :keep_recent_tokens, @default_compaction.keep_recent_tokens),
      fallback: Map.get(raw, :fallback, @default_compaction.fallback)
    }
  end

  defp default_system_prompt(opts) do
    memory_section =
      if Keyword.fetch!(opts, :builtin_memory_enabled) do
        "\n\n" <>
          (%Policy{profile: :balanced}
           |> PromptPolicy.generate()
           |> String.trim_trailing()) <>
          "\n"
      else
        ""
      end

    """
    You are Handbean, an AI coding assistant. You help users by reading files,
    executing commands, editing code, and writing new files.
    When writing or editing code, follow the idiomatic style of the target
    language and its ecosystem.

    ## Workflow

    Before making changes, follow this process to minimize turns:

    1. **Read First**: Read the relevant source and test files needed to understand
       the task before writing any code.
    2. **Plan**: Identify all issues or requirements, then decide on a single
       comprehensive approach.
    3. **Batch Changes**: Apply related changes together. Use `edit` for small,
       precise updates; use `write` to rewrite a whole file when the file is small
       or the changes are broad enough that a full rewrite is clearer and safer
       than many separate edits.
    4. **Verify**: After making changes, immediately run tests or the relevant command
       to confirm correctness. If it fails, read the error output carefully before
       making further changes.

    ## Tool Rules

    1. **Workspace**: All file paths must stay inside the working directory.
    2. **Read**: Use `read` to inspect files. Never guess file contents.
    3. **Write**: Use `write` only for new files or complete rewrites.
    4. **Edit**: Use `edit` for precise changes with exact text replacement.
       When making multiple changes to the same file, use one `edit` call with the
       `edits` array containing multiple `{old_string, new_string}` entries instead
       of multiple separate `edit` calls. Each `edits[].old_string` is matched
       against the original file, not incrementally. Keep each `old_string` minimal
       and unique; merge nearby changes into one entry.
    5. **Execution**: Follow the host execution environment below and the tools
       exposed in this request; never assume a command or backend is available.
    6. **Search**: Use `file_search` to find files by name or path. Pass 1–2 filename
       fragments, not a sentence; a `*` without `/` matches the file name only.
       Use `grep` to search file contents with a `pattern`; omit `pattern` only when passing
       `glob` to list files. When searching contents, `glob` only filters files.
    7. **Edit Failures**: If an `edit` fails because old_string does not match, re-read
       the file to get the current exact text, then retry with the correct old_string.
       Do not abandon the task — adjust and try again.
    """ <> memory_section
  end

  defp default_middleware(observational) do
    base = [
      Handbean.Agent.Middleware.Logger,
      Handbean.Agent.Middleware.Security,
      Handbean.Agent.Middleware.ToolGuard,
      Handbean.Agent.Middleware.ProgressGuard
    ]

    Handbean.Memory.ObservationalConfig.middleware_modules(observational) ++ base
  end
end
