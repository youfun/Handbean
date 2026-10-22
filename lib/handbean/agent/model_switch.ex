defmodule Handbean.Agent.ModelSwitch do
  @moduledoc false

  alias Handbean.Agent.{Config, Runner, State}

  @spec apply_pending(State.t()) :: {:ok, State.t()} | {:error, State.t()}
  def apply_pending(%State{config: %{runner_pid: runner_pid, run_id: run_id}} = state)
      when is_pid(runner_pid) and is_binary(run_id) do
    checkout_and_apply(state, runner_pid, run_id)
  end

  def apply_pending(%State{} = state), do: {:ok, state}

  defp checkout_and_apply(state, runner_pid, run_id) do
    case Runner.checkout_model_switch(runner_pid, run_id, self()) do
      :unchanged ->
        {:ok, state}

      {:apply, pending} ->
        apply_revision(state, runner_pid, run_id, pending)

      {:error, reason} ->
        {:error, fail_state(state, reason)}
    end
  catch
    :exit, reason -> {:error, fail_state(state, {:runner_unavailable, reason})}
  end

  defp apply_revision(state, runner_pid, run_id, pending) do
    config = Config.reconfigure_model(state.config, pending.config_opts)
    switched = switch_config(state, config, pending)
    public = public_snapshot(switched, pending)

    case Runner.commit_model_switch(runner_pid, run_id, self(), pending.revision, public) do
      :ok ->
        {:ok, switched}

      {:error, :stale_revision} ->
        checkout_and_apply(state, runner_pid, run_id)

      {:error, reason} ->
        _ = Runner.fail_model_switch(runner_pid, run_id, self(), pending.revision, reason)
        {:error, fail_state(state, reason)}
    end
  rescue
    error ->
      reason = {:invalid_model_config, Exception.message(error)}
      _ = Runner.fail_model_switch(runner_pid, run_id, self(), pending.revision, reason)
      {:error, fail_state(state, reason)}
  end

  defp switch_config(state, config, pending) do
    history =
      state.run_metadata
      |> Map.get(:model_history, [])
      |> Kernel.++([public_snapshot(%{state | config: config}, pending)])

    %{
      state
      | config: config,
        provider_state: %{},
        provider_response_metadata: %{},
        response_metadata: %{},
        usage_anchor: nil,
        context_edited: true,
        context_generation: (state.context_generation || 0) + 1,
        config_revision: pending.revision,
        run_metadata: Map.put(state.run_metadata, :model_history, history)
    }
  end

  defp public_snapshot(state, pending) do
    provider_config = state.config.provider_config || %{}

    %{
      revision: pending.revision,
      model_ref: pending.model_ref,
      model: state.config.model,
      reasoning_level: state.config.reasoning_level,
      provider:
        provider_config[:provider] || provider_config["provider"] ||
          inspect(state.config.provider)
    }
  end

  defp fail_state(state, reason) do
    %{state | status: :error, error: "Model switch failed: #{format_reason(reason)}"}
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
