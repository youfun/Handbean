defmodule Handbean.Agent do
  @moduledoc """
  Agent entry point.

  Creates an agent configuration, initializes state, and runs the loop.

  ## Examples

      {:ok, state} = Handbean.Agent.run("List the files", tools: [Handbean.Tool.Builtin.Bash])
  """

  require Logger
  alias Handbean.Agent.Config
  alias Handbean.Agent.State
  alias Handbean.Agent.Turn
  alias Handbean.PubSub.Session

  @doc """
  Resume agent execution after tool approval decisions.

  Called by Runner when the user has made decisions on pending tool calls.
  Wraps `Turn.resume_after_tool_approval/3` with the same Session event
  callback and tool registration that `run/2` provides.

  ## Options
    - `:tools` - tool modules (inherited from original run opts)
    - `:session_id` - session id (required)
    - `:on_event` - event callback (overridden by session callback)
  """
  @spec resume_after_tool_approval(State.t(), [map()], keyword()) ::
          {:ok, State.t()} | {:error, term()}
  def resume_after_tool_approval(%State{} = interrupted_state, decisions, opts) do
    # Register tools (same as run)
    working_dir = Keyword.get(opts, :working_directory)
    tools = tools_for_run(opts, working_dir)
    Enum.each(tools, &Handbean.Tool.Registry.register/1)

    if Handbean.Terminal.available?() do
      Handbean.Tool.Extension.Terminal.register()
    end

    opts = maybe_bootstrap_mcp(opts)

    interrupted_state =
      put_in(interrupted_state.config.context[:mcp_scope], opts[:context][:mcp_scope])

    # Re-wrap on_event with session broadcast (same pattern as run/2 but for resume)
    wrapped_opts =
      case Keyword.get(opts, :session_id) do
        nil ->
          opts

        session_id ->
          Keyword.put(
            opts,
            :on_event,
            session_event_callback(session_id, Keyword.get(opts, :on_event))
          )
      end

    result = Turn.resume_after_tool_approval(interrupted_state, decisions, wrapped_opts)
    {:ok, result}
  end

  @doc "Continue a run paused by the progress guard."
  def resume_after_stall_check(interrupted_state, decisions, opts) do
    opts = maybe_bootstrap_mcp(opts)

    wrapped_opts =
      case Keyword.get(opts, :session_id) do
        nil ->
          opts

        session_id ->
          Keyword.put(
            opts,
            :on_event,
            session_event_callback(session_id, Keyword.get(opts, :on_event))
          )
      end

    {:ok, Turn.resume_after_stall_check(interrupted_state, decisions, wrapped_opts)}
  end

  @doc """
  Run the agent with the given prompt and options.

  ## Options
    - `:tools` - list of tool modules (default: all built-in + memory tools)
    - `:model` - provider model string (default: configured in config)
    - `:system_prompt` - system prompt override
    - `:max_turns` - optional agent loop cap. Omitted means unlimited; callers such as subagents may still set one.
    - `:working_directory` - file access root (default: cwd)
    - `:streaming` - enable streaming chunks (default: true)
    - `:on_chunk` - stream callback fn
    - `:on_event` - event callback fn
  """
  @spec run(String.t(), keyword()) :: {:ok, State.t()} | {:error, term()}
  def run(prompt, opts \\ []) do
    # Register tools with the central registry.
    # Default: all built-in + memory tools.
    working_dir = Keyword.get(opts, :working_directory)
    tools = tools_for_run(opts, working_dir)
    Enum.each(tools, &Handbean.Tool.Registry.register/1)

    if Handbean.Terminal.available?() do
      Handbean.Tool.Extension.Terminal.register()
    end

    opts = maybe_bootstrap_mcp(opts)

    opts =
      Keyword.update(
        opts,
        :context,
        %{run_deadline: Keyword.get(opts, :run_deadline)},
        fn context ->
          Map.put(context || %{}, :run_deadline, Keyword.get(opts, :run_deadline))
        end
      )

    config = Config.from_opts(opts)

    {state, opts, session_id, queue_pid} =
      case Keyword.get(opts, :session_id) do
        nil ->
          {State.init(config, prompt) |> prepend_history(opts), opts, nil, nil}

        session_id ->
          {:ok, _pid} = Session.start_or_get(session_id: session_id, model: config.model)
          next_turn_messages = Session.drain_next_turn(session_id)

          {queue_pid, owns_queue?} =
            case Keyword.get(opts, :candidate_queue) do
              pid when is_pid(pid) ->
                {pid, false}

              nil ->
                {:ok, pid} =
                  Handbean.Agent.CandidateQueue.start_link(session_id: session_id, owner: self())

                :ok = Session.attach_run(session_id, self(), pid)
                {pid, true}
            end

          state =
            config
            |> State.init(prompt)
            |> prepend_history(opts)
            |> prepend_messages(next_turn_messages)
            |> State.merge_run_metadata(%{
              session_id: session_id,
              conversation_id: Keyword.get(opts, :conversation_id, session_id)
            })

          opts =
            opts
            |> Keyword.put(:candidate_queue, queue_pid)
            |> Keyword.put(
              :on_event,
              session_event_callback(session_id, Keyword.get(opts, :on_event))
            )

          {state, opts, session_id, {queue_pid, owns_queue?}}
      end

    try do
      result = Turn.run_loop(state, opts)
      {:ok, result}
    after
      case queue_pid do
        {pid, true} when is_pid(pid) ->
          Handbean.Agent.CandidateQueue.seal(pid)
          if session_id, do: Session.mark_run_finished(session_id)

        {_pid, false} ->
          :ok

        _ ->
          :ok
      end
    end
  end

  defp prepend_messages(%State{} = state, []), do: state

  defp prepend_messages(%State{} = state, messages) do
    %{state | messages: messages ++ state.messages}
  end

  defp prepend_history(%State{} = state, opts) do
    prepend_messages(state, Keyword.get(opts, :history_messages, []))
  end

  # Runner's persistence callback already broadcasts. Wrapping again duplicates
  # message_delta and can deliver the same assistant text twice.
  defp session_event_callback(_session_id, nil), do: fn _event -> :ok end

  defp session_event_callback(_session_id, user_on_event) when is_function(user_on_event, 1) do
    fn event -> user_on_event.(event) end
  end

  # ── Default tool set ──

  @doc """
  Default tool modules for this BEAM.

  Assembled from `Handbean.Host` capabilities, not from env sniffing. The list
  is owned by `Handbean.Tool.Registry.host_tool_modules/0` (the same seed the
  registry uses at init); this is only the agent-facing name for it.
  """
  @spec default_tools() :: [module()]
  def default_tools, do: Handbean.Tool.Registry.host_tool_modules()

  @doc """
  Tools for a workspace-independent chat.

  Memory, public page fetch, the in-app browser, opening a page in the system
  browser, and device calendar/alarm when the host has an artifact-delivery
  backend. File, shell, search, MCP, and skill tools stay off so a chat without
  a project root cannot fall through to the process working directory. Web and
  system-browser tools do not need workspace approval. Calendar and alarm still
  ask before they touch the device.
  """
  def free_chat_tools do
    base = [
      Handbean.Tool.Builtin.WebFetch,
      Handbean.Tool.Builtin.Browser,
      Handbean.Tool.Builtin.OpenUrl,
      Handbean.Tool.Memory.MemAssociate,
      Handbean.Tool.Memory.MemLearn,
      Handbean.Tool.Memory.MemRecall,
      Handbean.Tool.Memory.MemReinforce
    ]

    if Handbean.Host.artifact_delivery_backend() do
      base ++
        [
          Handbean.Tool.Builtin.DeviceCalendar,
          Handbean.Tool.Builtin.DeviceAlarm
        ]
    else
      base
    end
  end

  # ── BEAM tools auto-detection ──

  @beam_tools [
    Handbean.Tool.Extension.Beam.Docs,
    Handbean.Tool.Extension.Beam.Source,
    Handbean.Tool.Extension.Beam.DbSchema,
    Handbean.Tool.Extension.Beam.Sql
  ]

  @beam_eval_tool Handbean.Tool.Extension.Beam.Eval

  defp tools_for_run(opts, working_dir) do
    case Keyword.fetch(opts, :tools) do
      {:ok, tools} -> tools
      :error -> maybe_append_beam_tools(default_tools(), working_dir)
    end
  end

  defp maybe_append_beam_tools(tools, working_dir)
       when is_binary(working_dir) and working_dir != "" do
    tools ++ beam_tools_for_workspace(working_dir)
  end

  defp maybe_append_beam_tools(tools, _), do: tools

  defp beam_tools_for_workspace(working_dir) do
    config = Handbean.WorkspaceSettings.beam_tools_config(working_dir)
    mix_project? = File.exists?(Path.join(working_dir, "mix.exs"))
    allow_eval? = Handbean.Host.beam_eval?()

    auto_tools =
      if mix_project? and config.auto do
        @beam_tools
      else
        []
      end

    eval_tools =
      if allow_eval? and (config.eval or "ext__beam__eval" in config.explicit) do
        [@beam_eval_tool]
      else
        []
      end

    Enum.uniq(auto_tools ++ eval_tools)
  end

  defp maybe_bootstrap_mcp(opts) do
    mcp_opts = Handbean.MCP.Access.options(opts)

    enabled? =
      case Keyword.fetch(opts, :mcp) do
        {:ok, value} -> value
        :error -> Handbean.Host.mcp?() and Keyword.get(opts, :chat_scope) != :free
      end

    if enabled? do
      case Handbean.MCP.bootstrap(mcp_opts) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning(fn ->
            "MCP bootstrap failed (will retry on next run): #{inspect(reason)}"
          end)
      end
    end

    context = Keyword.get(opts, :context, %{})
    Keyword.put(opts, :context, Map.put(context, :mcp_scope, if(enabled?, do: mcp_opts)))
  end
end
