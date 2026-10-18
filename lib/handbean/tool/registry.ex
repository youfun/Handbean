defmodule Handbean.Tool.Registry do
  @moduledoc """
  Tool Registry — central registry for all available tools.

  Tools are registered with their unique name and module. The registry
  provides lookup, listing, and tool definition generation for providers.

  ## Design principle

  Even in MVP, all tools (builtin + memory) go through the registry.
  This prevents hardcoding tool modules into the Agent Core and makes
  V1 extension loading a non-breaking addition.
  """

  use GenServer

  require Logger

  @snapshot_key :state
  @snapshot_table __MODULE__

  # ── Client API ──

  @doc "Start the registry."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Register a tool module. Pass `override: true` to replace an existing name."
  @spec register(module()) :: :ok | {:error, term()}
  @spec register(module(), keyword()) :: :ok | {:error, term()}
  def register(tool_mod, opts \\ []) when is_atom(tool_mod) and is_list(opts) do
    GenServer.call(__MODULE__, {:register, tool_mod, opts})
  end

  @doc """
  Atomically replace every module-owned tool with `tool_mods`.

  An owner may replace its own entries, but it cannot overwrite a tool
  belonging to another owner (including an unowned builtin/programmatic
  entry). This is the primitive used by extension reload and in-memory
  mounts so stale tools cannot survive a successful replacement.
  """
  @spec replace_owner(term(), [module()]) :: :ok | {:error, term()}
  def replace_owner(owner, tool_mods) when is_list(tool_mods) do
    GenServer.call(__MODULE__, {:replace_owner, owner, tool_mods})
  end

  @doc "Remove all tools owned by `owner`."
  @spec remove_owner(term()) :: :ok
  def remove_owner(owner) do
    GenServer.call(__MODULE__, {:remove_owner, owner})
  end

  @doc "Register a virtual tool backed by an executor function."
  @spec register_virtual(String.t(), String.t() | nil, map(), (map(), map() -> any()), keyword()) ::
          :ok | {:error, term()}
  def register_virtual(name, description, input_schema, executor, opts \\ [])

  def register_virtual(name, description, input_schema, executor, opts)
      when is_binary(name) and is_function(executor, 2) do
    GenServer.call(
      __MODULE__,
      {:register_virtual, name, description, input_schema, executor, opts}
    )
  end

  @doc "Get a tool entry by name."
  @spec get(String.t()) :: {:ok, map()} | :error
  def get(name) when is_binary(name) do
    state = snapshot()

    case Map.fetch(state.tools, name) do
      {:ok, entry} -> {:ok, entry}
      :error -> :error
    end
  end

  @doc "List all registered tool names."
  @spec list() :: [String.t()]
  def list do
    snapshot().tools
    |> Map.keys()
  end

  @doc """
  Tool definitions declared to the provider.

  Nested-only and deferred tools stay registered. Nested-only tools are
  executable only through `Executor.execute_nested/4`. Deferred tools are
  omitted until a conversation loads them.
  """
  @spec tool_defs() :: [map()]
  def tool_defs do
    state = snapshot()
    declared_defs(state.tools, nil)
  end

  @doc "Get tool_name => tool entry map for executor lookups."
  @spec tool_fns() :: %{String.t() => map()}
  def tool_fns do
    snapshot().tools
  end

  @doc """
  Deferred tools with the fields needed for search and later declaration.

  Each map has `name`, `description`, `input_schema`, `server`, and
  `server_description`. These tools are absent from `tool_defs/0`.
  """
  @spec deferred_catalog() :: [map()]
  def deferred_catalog do
    snapshot().tools
    |> Map.values()
    |> Enum.filter(&deferred_entry?/1)
    |> Enum.sort_by(& &1.name)
    |> Enum.map(&catalog_entry/1)
  end

  @doc "Remove a tool by name."
  @spec unregister(String.t()) :: :ok
  def unregister(name) when is_binary(name) do
    GenServer.call(__MODULE__, {:unregister, name})
  end

  @doc "Reset the registry, clearing all registered tools."
  @spec reset() :: :ok
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  @doc "Set the active tool list for a session (nil means all available)."
  @spec set_active_for_session(String.t(), [String.t()] | nil) :: :ok
  def set_active_for_session(session_id, tool_names) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:set_active_for_session, session_id, tool_names})
  end

  @doc "Get the active tool list for a session."
  @spec active_for_session(String.t()) :: [String.t()] | nil
  def active_for_session(session_id) when is_binary(session_id) do
    snapshot().active_sets
    |> Map.get(session_id)
  end

  @doc """
  Session tool definitions declared to the provider.

  Nested-only and deferred tools are omitted even when the session active set
  names them. `nil` means every declared tool, not every registered tool.
  """
  @spec tool_defs_for_session(String.t()) :: [map()]
  def tool_defs_for_session(session_id) when is_binary(session_id) do
    state = snapshot()
    declared_defs(state.tools, Map.get(state.active_sets, session_id))
  end

  @doc """
  Prompt text for tools the provider is allowed to see.

  Nested-only and deferred tools are omitted. An empty active set yields an empty string.
  """
  @spec prompt_snippets() :: String.t()
  def prompt_snippets do
    state = snapshot()
    format_prompt_snippets(state.tools, nil)
  end

  @doc "Session-scoped prompt snippets. Nested-only and deferred tools are omitted."
  @spec prompt_snippets_for_session(String.t()) :: String.t()
  def prompt_snippets_for_session(session_id) when is_binary(session_id) do
    state = snapshot()
    format_prompt_snippets(state.tools, Map.get(state.active_sets, session_id))
  end

  # ── Server Callbacks ──

  @doc """
  Builtin modules seeded from the current `Handbean.Host` declarations.

  Single source of truth for host-gated tool seeding: registry `init/1`
  and `Handbean.Agent.default_tools/0` both read this list. The host writes
  backends before starting `:handbean`. Registration follows the declared
  backend, not the OS, UI entry, or another capability.
  """
  @spec host_tool_modules() :: [module()]
  def host_tool_modules do
    for %{module: mod, enabled: true} <- host_tool_configuration(), do: mod
  end

  @doc "Host seed decisions, not registration, dependency or run authorization facts."
  def host_tool_configuration do
    alias Handbean.Host

    base = [
      Handbean.Tool.Builtin.CodeSearch,
      Handbean.Tool.Builtin.Edit,
      Handbean.Tool.Builtin.FileSearch,
      Handbean.Tool.Builtin.Grep,
      Handbean.Tool.Builtin.JobStatus,
      Handbean.Tool.Builtin.JobCancel,
      Handbean.Tool.Builtin.Read,
      Handbean.Tool.Builtin.Skill,
      Handbean.Tool.Builtin.Advisor,
      Handbean.Tool.Builtin.Task,
      Handbean.Tool.Builtin.TaskStatus,
      Handbean.Tool.Builtin.ToolSearch,
      Handbean.Tool.Builtin.ListModels,
      Handbean.Tool.Builtin.PublishMedia,
      Handbean.Tool.Builtin.ReadContext,
      Handbean.Tool.Builtin.EditContext,
      Handbean.Tool.Builtin.WebFetch,
      Handbean.Tool.Builtin.Write,
      Handbean.Tool.Builtin.ListConversations,
      Handbean.Tool.Builtin.FindConversation,
      Handbean.Tool.Builtin.ReadConversation,
      Handbean.Tool.Builtin.GetConversationStatus,
      Handbean.Tool.Builtin.GetConversationTrajectory,
      Handbean.Tool.Builtin.SendConversationMessage,
      Handbean.Tool.Builtin.ReplyToParentConversation,
      Handbean.Tool.Builtin.CreateConversation,
      Handbean.Tool.Builtin.Schedule,
      Handbean.Tool.Builtin.ErrorTracker,
      Handbean.Tool.Memory.MemAssociate,
      Handbean.Tool.Memory.MemForget,
      Handbean.Tool.Memory.MemLearn,
      Handbean.Tool.Memory.MemRecall,
      Handbean.Tool.Memory.MemReflect,
      Handbean.Tool.Memory.MemReinforce,
      Handbean.Tool.Memory.MemUpdate,
      Handbean.Tool.Extension.MountApply,
      Handbean.Tool.Extension.MountDrop
    ]

    base
    |> Enum.map(&%{module: &1, enabled: true, source: :agent_runtime})
    |> host_gate(
      Host.packaged_mix_toolchain?(),
      Handbean.Tool.Builtin.MixProject,
      :packaged_mix_toolchain
    )
    |> host_gate(not is_nil(Host.get(:git_backend)), Handbean.Tool.Builtin.Git, :git_backend)
    |> host_gate(
      not is_nil(Host.get(:computer_use_backend)),
      Handbean.Tool.Builtin.Computer,
      :computer_use_backend
    )
    |> host_gate(Host.shell?(), Handbean.Tool.Builtin.Bash, :shell)
    |> host_gate(
      not is_nil(Host.browser_backend()),
      Handbean.Tool.Builtin.Browser,
      :browser_backend
    )
    |> host_gate(
      Host.browser_backend() == :webview,
      Handbean.Tool.Builtin.PreviewServe,
      :browser_backend
    )
    |> host_gate(
      not is_nil(Host.artifact_delivery_backend()),
      Handbean.Tool.Builtin.OpenUrl,
      :artifact_delivery_backend
    )
    |> host_gate(
      not is_nil(Host.artifact_delivery_backend()),
      Handbean.Tool.Builtin.OpenFile,
      :artifact_delivery_backend
    )
    |> host_gate(
      not is_nil(Host.artifact_delivery_backend()),
      Handbean.Tool.Builtin.ShareFile,
      :artifact_delivery_backend
    )
    |> host_gate(
      not is_nil(Host.artifact_delivery_backend()),
      Handbean.Tool.Builtin.DeviceCalendar,
      :artifact_delivery_backend
    )
    |> host_gate(
      not is_nil(Host.artifact_delivery_backend()),
      Handbean.Tool.Builtin.DeviceAlarm,
      :artifact_delivery_backend
    )
    |> host_gate(Host.host_script?(), Handbean.Tool.Builtin.RunElixirScript, :host_script)
  end

  defp host_gate(list, enabled, mod, source),
    do: list ++ [%{module: mod, enabled: enabled, source: source}]

  # ── BEAM introspection tools (registered on-demand for security) ──

  @beam_tools %{
    # P0 — safe read-only introspection
    docs: Handbean.Tool.Extension.Beam.Docs,
    source: Handbean.Tool.Extension.Beam.Source,
    db_schema: Handbean.Tool.Extension.Beam.DbSchema,
    schemas: Handbean.Tool.Extension.Beam.Schemas,
    sup_tree: Handbean.Tool.Extension.Beam.SupTree,
    top: Handbean.Tool.Extension.Beam.Top,
    # P1 — sensitive or mutating
    sql: Handbean.Tool.Extension.Beam.Sql,
    process_info: Handbean.Tool.Extension.Beam.ProcessInfo,
    # P1 — powerful (executes code)
    eval: Handbean.Tool.Extension.Beam.Eval,
    # Cross-session (reads/writes other sessions)
    sessions: Handbean.Tool.Extension.Beam.Sessions,
    session_snapshot: Handbean.Tool.Extension.Beam.SessionSnapshot,
    session_steer: Handbean.Tool.Extension.Beam.SessionSteer
  }

  @doc """
  Register all BEAM introspection and cross-session tools.

  These are NOT registered by default for security — call this explicitly
  when you want to enable BEAM-level introspection and cross-session operations.

  Can be called with `:safe_only` to register only read-only tools
  (docs, source, db_schema, schemas, sup_tree, top, sessions, session_snapshot),
  excluding `sql`, `eval`, `process_info`, and `session_steer`.
  """
  @spec register_beam_tools(atom()) :: :ok
  def register_beam_tools(level \\ :all) do
    allowed =
      case level do
        :safe_only ->
          Map.drop(@beam_tools, [:sql, :eval, :process_info, :session_steer])

        :all ->
          @beam_tools
      end

    Enum.each(allowed, fn {_key, mod} ->
      register(mod)
    end)

    :ok
  end

  @impl true
  def init(_opts) do
    _table =
      :ets.new(@snapshot_table, [
        :named_table,
        :set,
        :protected,
        read_concurrency: true
      ])

    tools =
      Enum.reduce(host_tool_modules(), %{}, fn mod, acc ->
        entry = build_module_entry(mod, nil)
        Map.put(acc, entry.name, entry)
      end)

    Logger.debug(
      "[ToolRegistry] Registered #{map_size(tools)} tools: #{inspect(Map.keys(tools))}"
    )

    state = %{tools: tools, active_sets: %{}}
    :ok = publish_snapshot(state)
    {:ok, state}
  end

  @impl true
  def handle_call({:register, tool_mod, opts}, _from, state) do
    entry = build_module_entry(tool_mod, Keyword.get(opts, :owner))
    override? = Keyword.get(opts, :override, false)

    if Map.has_key?(state.tools, entry.name) and not override? do
      {:reply, :ok, state}
    else
      new_state = %{state | tools: Map.put(state.tools, entry.name, entry)}
      reply_with_snapshot(:ok, new_state)
    end
  rescue
    exception ->
      {:reply, {:error, {:invalid_tool, Exception.message(exception)}}, state}
  end

  def handle_call({:replace_owner, owner, tool_mods}, _from, state) do
    try do
      entries =
        tool_mods
        |> Enum.uniq()
        |> Enum.map(&build_module_entry(&1, owner))

      incoming = Map.new(entries, &{&1.name, &1})

      conflicts =
        Enum.find_value(incoming, fn {name, _entry} ->
          case Map.get(state.tools, name) do
            nil ->
              nil

            existing ->
              if Map.get(existing.meta, :owner) != owner do
                {name, existing}
              else
                nil
              end
          end
        end)

      case conflicts do
        nil ->
          tools =
            state.tools
            |> remove_owned_tools(owner)
            |> Map.merge(incoming)

          new_state = %{state | tools: tools}
          reply_with_snapshot(:ok, new_state)

        {name, existing} ->
          {:reply, {:error, {:tool_name_collision, name, Map.get(existing.meta, :owner)}}, state}
      end
    rescue
      exception ->
        {:reply, {:error, {:invalid_tool, Exception.message(exception)}}, state}
    end
  end

  def handle_call({:remove_owner, owner}, _from, state) do
    new_state = %{state | tools: remove_owned_tools(state.tools, owner)}
    reply_with_snapshot(:ok, new_state)
  end

  def handle_call(
        {:register_virtual, name, description, input_schema, executor, opts},
        _from,
        state
      ) do
    entry = build_virtual_entry(name, description, input_schema, executor, opts)

    if Map.has_key?(state.tools, entry.name) do
      {:reply, :ok, state}
    else
      new_state = %{state | tools: Map.put(state.tools, entry.name, entry)}
      reply_with_snapshot(:ok, new_state)
    end
  end

  def handle_call({:get, name}, _from, state) do
    result =
      case Map.fetch(state.tools, name) do
        {:ok, entry} -> {:ok, entry}
        :error -> :error
      end

    {:reply, result, state}
  end

  def handle_call(:list, _from, state) do
    {:reply, Map.keys(state.tools), state}
  end

  def handle_call(:tool_defs, _from, state) do
    {:reply, declared_defs(state.tools, nil), state}
  end

  def handle_call(:tool_fns, _from, state) do
    {:reply, state.tools, state}
  end

  def handle_call(:deferred_catalog, _from, state) do
    catalog =
      state.tools
      |> Map.values()
      |> Enum.filter(&deferred_entry?/1)
      |> Enum.sort_by(& &1.name)
      |> Enum.map(&catalog_entry/1)

    {:reply, catalog, state}
  end

  def handle_call({:unregister, name}, _from, state) do
    new_state = %{state | tools: Map.delete(state.tools, name)}
    reply_with_snapshot(:ok, new_state)
  end

  def handle_call(:reset, _from, _state) do
    reply_with_snapshot(:ok, %{tools: %{}, active_sets: %{}})
  end

  def handle_call({:set_active_for_session, session_id, tool_names}, _from, state) do
    new_active_sets =
      case tool_names do
        nil -> Map.delete(state.active_sets, session_id)
        names -> Map.put(state.active_sets, session_id, names)
      end

    new_state = %{state | active_sets: new_active_sets}
    reply_with_snapshot(:ok, new_state)
  end

  def handle_call(:snapshot, _from, state) do
    {:reply, state, state}
  end

  def handle_call({:active_for_session, session_id}, _from, state) do
    {:reply, Map.get(state.active_sets, session_id), state}
  end

  def handle_call({:tool_defs_for_session, session_id}, _from, state) do
    {:reply, declared_defs(state.tools, Map.get(state.active_sets, session_id)), state}
  end

  def handle_call(:prompt_snippets, _from, state) do
    {:reply, format_prompt_snippets(state.tools, nil), state}
  end

  def handle_call({:prompt_snippets_for_session, session_id}, _from, state) do
    {:reply, format_prompt_snippets(state.tools, Map.get(state.active_sets, session_id)), state}
  end

  defp snapshot do
    case :ets.lookup(@snapshot_table, @snapshot_key) do
      [{@snapshot_key, state}] -> state
      [] -> GenServer.call(__MODULE__, :snapshot)
    end
  rescue
    ArgumentError -> GenServer.call(__MODULE__, :snapshot)
  end

  defp reply_with_snapshot(reply, state) do
    :ok = publish_snapshot(state)
    {:reply, reply, state}
  end

  defp publish_snapshot(state) do
    true = :ets.insert(@snapshot_table, {@snapshot_key, state})
    :ok
  end

  defp build_module_entry(mod, owner) do
    meta = if is_nil(owner), do: %{}, else: %{owner: owner}

    %{
      kind: :module,
      name: mod.name(),
      description: mod.description(),
      input_schema: mod.input_schema(),
      module: mod,
      executor: &mod.execute/2,
      max_result_chars:
        if(function_exported?(mod, :max_result_chars, 0),
          do: mod.max_result_chars(),
          else: :unlimited
        ),
      concurrent?:
        if(function_exported?(mod, :concurrent?, 0), do: mod.concurrent?(), else: true),
      timeout_ms: if(function_exported?(mod, :timeout_ms, 0), do: mod.timeout_ms(), else: nil),
      hint: tool_hint(mod),
      nested_only?: nested_only?(mod, meta),
      deferred?: deferred?(mod),
      meta: meta
    }
  end

  defp remove_owned_tools(tools, owner) do
    Map.reject(tools, fn {_name, entry} -> Map.get(entry.meta, :owner) == owner end)
  end

  defp build_virtual_entry(name, description, input_schema, executor, opts) do
    meta = Keyword.get(opts, :meta, %{})

    %{
      kind: :virtual,
      name: name,
      description: description,
      input_schema: input_schema || %{},
      module: nil,
      executor: executor,
      max_result_chars: Keyword.get(opts, :max_result_chars, :unlimited),
      concurrent?: Keyword.get(opts, :concurrent?, true),
      timeout_ms: Keyword.get(opts, :timeout_ms),
      hint: tool_hint(Keyword.get(opts, :hint)),
      nested_only?: nested_only?(nil, meta) or Keyword.get(opts, :nested_only?, false),
      deferred?: Keyword.get(opts, :deferred?, false) or deferred_exposure?(meta),
      meta: meta
    }
  end

  defp tool_hint(mod) when is_atom(mod) do
    if function_exported?(mod, :hint, 0), do: tool_hint(mod.hint()), else: nil
  end

  defp tool_hint(hint) when is_binary(hint) do
    case String.trim(hint) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp tool_hint(_hint), do: nil

  defp deferred?(mod) when is_atom(mod) do
    function_exported?(mod, :deferred?, 0) and mod.deferred?()
  end

  # Entries registered before `:deferred?` existed stay in the GenServer
  # across a code reload. Missing means eager, the only exposure those tools had.
  defp deferred_entry?(entry) when is_map(entry), do: Map.get(entry, :deferred?, false)

  defp deferred_exposure?(meta) do
    meta[:exposure] in ["deferred", "nested"] or meta["exposure"] in ["deferred", "nested"]
  end

  defp nested_only?(mod, meta) do
    module_flag =
      is_atom(mod) and function_exported?(mod, :nested_only?, 0) and mod.nested_only?()

    module_flag or truthy?(meta[:nested_only]) or truthy?(meta["nested_only"])
  end

  defp truthy?(value), do: value in [true, "true"]

  defp catalog_entry(entry) do
    %{
      name: entry.name,
      description: entry.description,
      input_schema: entry.input_schema,
      server: entry.meta[:server] || entry.meta["server"],
      server_description: entry.meta[:server_description] || entry.meta["server_description"]
    }
  end

  defp declared_defs(tools, active_names) do
    tools
    |> declared_entries(active_names)
    |> Enum.map(fn entry ->
      %{name: entry.name, description: entry.description, input_schema: entry.input_schema}
    end)
  end

  defp format_prompt_snippets(tools, active_names) do
    tools
    |> declared_entries(active_names)
    |> Enum.map_join("\n", fn entry ->
      "- #{entry.name}: #{entry.description}"
    end)
  end

  defp declared_entries(tools, active_names) do
    name_set = if is_list(active_names), do: MapSet.new(active_names)

    tools
    |> Map.values()
    |> Enum.filter(fn entry ->
      not entry.nested_only? and not deferred_entry?(entry) and
        (is_nil(name_set) or MapSet.member?(name_set, entry.name))
    end)
    |> Enum.sort_by(& &1.name)
  end
end
