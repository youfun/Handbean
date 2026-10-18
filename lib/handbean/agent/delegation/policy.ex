defmodule Handbean.Agent.Delegation.Policy do
  @moduledoc """
  Delegation policy. A profile can only narrow the parent run.

  Recursive delegation and monetary budgets stay rejected. Sync children are
  bounded by the parent tool timeout; background children by the profile
  timeout only.
  """

  alias Handbean.Agent.Subagent.Profile
  alias Handbean.Agent.{Config, ModelConfig, Reasoning}

  @delegation_tools Profile.delegation_tools()

  def budget(timeout) when is_integer(timeout) and timeout >= 4_000,
    do: {:ok, min(45_000, div(timeout, 2))}

  def budget(_), do: {:error, "Tool timeout is too short for delegation (minimum 4000ms)"}

  def budget(:advisor, :consult), do: {:ok, Handbean.Agent.Advisor.consult_timeout_ms()}
  def budget(:advisor, _kind), do: {:ok, Handbean.Agent.Advisor.review_timeout_ms()}

  def validate(context), do: validate(context, Profile.researcher(), :sync)

  @doc "Returns `{:ok, budget_ms, profile}` or `{:error, reason}`."
  def validate(context, %Profile{} = profile, mode) when mode in [:sync, :background] do
    with :ok <- parent_shape(context, mode),
         :ok <- reject_recursion(context),
         :ok <- reject_budget(context),
         :ok <- reject_write_sync(profile, mode),
         :ok <- resolve_model(context, profile),
         {:ok, budget} <- mode_budget(profile, mode, context[:tool_timeout]) do
      {:ok, budget, profile}
    end
  end

  def validate_advisor(
        %{
          delegation_config: _config,
          runner_pid: pid,
          run_id: run_id,
          conversation_id: conversation,
          advisor_request_id: request_id,
          profile: :advisor
        } = context
      )
      when is_pid(pid) and is_binary(run_id) and is_binary(conversation) and is_binary(request_id) do
    kind = Map.get(context, :advisor_kind, :review)

    with :ok <- reject_recursion(context),
         :ok <- reject_budget(context),
         true <- live_parent?(context) || {:error, "Parent run is no longer active"},
         {:ok, budget} <- budget(:advisor, kind) do
      {:ok, budget, Profile.advisor(kind)}
    end
  end

  def validate_advisor(_), do: {:error, "Delegation requires a trusted active Runner context"}

  def live_parent?(%{conversation_id: id, runner_pid: pid, run_id: run_id}) do
    Handbean.Agent.Runner.active?(id, run_id, pid)
  end

  def live_parent?(_), do: false

  @doc """
  Whether a delegated run may still use its tools. Sync children live only
  while the parent run does; background children while Delegation holds
  their job open.
  """
  def authorized_child?(%{mode: :background, child_id: child_id}, run_id),
    do: Handbean.Agent.Delegation.child_active?(child_id, run_id)

  def authorized_child?(parent, _run_id), do: live_parent?(parent)

  def allowed_tools(names, %Profile{} = profile) when is_list(names) do
    profile
    |> Profile.intersect_tools(names)
    |> Profile.host_tools(shell?: Handbean.Host.shell?())
    |> Enum.reject(&(&1 in @delegation_tools))
    |> Enum.reject(&(profile.mode == :read_only and &1 in Profile.write_tools()))
  end

  def allowed_tools(_names, _profile), do: []

  def provider_config(config) do
    # Provider-native tools bypass Registry/Executor authorization; only web search survives.
    native =
      Enum.filter(Map.get(config, :built_in_tools, []) || [], fn tool ->
        is_map(tool) and
          Handbean.Utils.SafeMap.get_any(tool, :type, "type") in [
            "web_search",
            "web_search_preview"
          ]
      end)

    config
    |> Map.put(:built_in_tools, native)
    |> Map.drop([
      :x_search,
      :previous_response_id,
      :provider_state,
      :tool_choice,
      :on_event,
      :on_chunk
    ])
    |> Map.put(:use_previous_response_id, false)
  end

  def child_opts(context, budget), do: child_opts(context, budget, Profile.researcher())

  @doc """
  Runner opts for a child run. `parent` identifies the authority the child's
  tools depend on (see `authorized_child?/2`).
  """
  def child_opts(context, budget, %Profile{} = profile, parent \\ %{}) do
    with {:ok, model, provider, provider_config, reasoning_level} <-
           model_opts(context, profile) do
      delegation_parent =
        context
        |> Map.take([:conversation_id, :run_id, :runner_pid])
        |> Map.merge(parent)

      opts =
        [
          workspace_path: policy_workspace(context),
          working_directory: context.working_directory,
          workspace_id: context[:workspace_id],
          model: model,
          provider: provider,
          provider_config: provider_config(provider_config),
          tools: [],
          context: %{delegation_parent: delegation_parent},
          allowed_tools: allowed_tools(context[:authorized_tools] || [], profile),
          source: :delegation,
          channel: :internal,
          delivery: Handbean.Delivery.Noop,
          delegated?: true,
          history_messages: [],
          mcp: false,
          max_turns: profile.max_turns,
          tool_timeout: min(budget, 10_000),
          timeout_ms: budget,
          middleware: [Handbean.Agent.Middleware.Security, Handbean.Agent.Middleware.ToolGuard],
          system_prompt: profile.system_prompt
        ]

      opts =
        if is_binary(reasoning_level),
          do: Keyword.put(opts, :reasoning_level, reasoning_level),
          else: opts

      {:ok, opts}
    end
  end

  defp parent_shape(
         %{runner_pid: pid, run_id: run_id, conversation_id: conversation, tool_call_id: call_id},
         _mode
       )
       when is_pid(pid) and is_binary(run_id) and is_binary(conversation) and is_binary(call_id),
       do: :ok

  defp parent_shape(_, _), do: {:error, "Delegation requires a trusted active Runner context"}

  defp reject_recursion(%{delegation_config: %{delegated?: true}}),
    do: {:error, "Recursive delegation is not allowed"}

  defp reject_recursion(_), do: :ok

  defp reject_budget(%{delegation_config: %{max_budget_cents: cents}}) when not is_nil(cents) do
    {:error,
     "Delegation unavailable with a monetary budget: reliable provider cost accounting is not configured"}
  end

  defp reject_budget(_), do: :ok

  defp reject_write_sync(%Profile{mode: :write}, :sync),
    do: {:error, "Write profiles can only run in the background"}

  defp reject_write_sync(%Profile{isolation: :worktree}, :sync),
    do: {:error, "Worktree profiles can only run in the background"}

  defp reject_write_sync(%Profile{background_allowed?: false}, :background),
    do: {:error, "This subagent_type does not allow background mode; pass background: false"}

  defp reject_write_sync(_, _), do: :ok

  defp resolve_model(_context, %Profile{model: :inherit}), do: :ok

  defp resolve_model(context, %Profile{} = profile) do
    case model_opts(context, profile) do
      {:ok, _, _, _, _} -> :ok
      error -> error
    end
  end

  defp mode_budget(profile, :background, _timeout), do: {:ok, profile.timeout_ms}

  defp mode_budget(profile, :sync, timeout) do
    with {:ok, parent_budget} <- budget(timeout),
         do: {:ok, min(profile.timeout_ms, parent_budget)}
  end

  defp model_opts(context, %Profile{model: :inherit, name: "advisor", source: :builtin}) do
    advisor = context.delegation_config.advisor

    if is_map(advisor) and is_binary(advisor[:provider_id]) do
      configured_model(context, advisor.provider_id, advisor.model_id, advisor[:reasoning])
    else
      inherit_model(context)
    end
  end

  defp model_opts(context, %Profile{model: :inherit}), do: inherit_model(context)

  defp model_opts(context, %Profile{model: {provider_id, model_id}}),
    do: configured_model(context, provider_id, model_id)

  defp configured_model(context, provider_id, model_id, selected_reasoning \\ nil) do
    case ModelConfig.provider_config_for(policy_workspace(context), provider_id, model_id) do
      {:ok, provider_config} ->
        entry =
          Enum.find(ModelConfig.all_global_models(), &(&1.id == "#{provider_id}/#{model_id}"))

        reasoning_level = if is_binary(selected_reasoning), do: selected_reasoning

        provider =
          Config.resolve_provider_from_api(
            provider_config[:api],
            model_id,
            provider_config[:provider]
          )

        provider_config =
          if is_binary(reasoning_level),
            do: Reasoning.apply_provider_options(provider_config, entry, reasoning_level),
            else: provider_config

        {:ok, model_id, provider, provider_config, reasoning_level}

      {:error, reason} ->
        {:error, model_error(reason)}
    end
  end

  defp inherit_model(context) do
    config = context.delegation_config
    {:ok, config.model, config.provider, config.provider_config, config.reasoning_level}
  end

  defp policy_workspace(context) do
    context[:workspace_path] || context.delegation_config.workspace_path ||
      context.working_directory
  end

  defp model_error(reason) when is_binary(reason), do: reason
  defp model_error(reason), do: "Subagent model is not configured: #{inspect(reason)}"
end
