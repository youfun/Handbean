defmodule Handbean.Agent.Turn.ProviderInvocation do
  @moduledoc false

  alias Handbean.Agent.{ProviderGateway, Reasoning, State}
  alias Handbean.Agent.Provider.Retry
  alias Handbean.Agent.Turn.{Events, StreamTracker}

  require Logger

  def build_config(%State{config: config, provider_state: provider_state} = state) do
    config.provider_config
    |> Map.put(:model, config.model)
    |> Map.put(:system_prompt, config.system_prompt)
    |> Map.put(:provider_state, provider_state)
    |> Map.put(:context_generation, state.context_generation || 0)
    |> Map.put(:working_directory, config.working_directory)
    |> maybe_put_context(config)
    |> apply_reasoning_level(config)
  end

  def prepare_config(provider_config, opts, streaming?, on_chunk) do
    provider_config
    |> Map.put(:stream, streaming?)
    |> Map.put(:retry_owner, :turn)
    |> maybe_put_provider_event_callback(opts)
    |> maybe_put_on_chunk(on_chunk)
  end

  def invoke(completion) do
    try do
      result =
        call_provider_with_retry(
          completion.provider,
          completion.state,
          completion.outbound_messages,
          completion.tool_defs,
          completion.provider_config,
          completion.streaming?,
          completion.on_chunk,
          completion.stream_tracker,
          0,
          completion.opts
        )

      {result, StreamTracker.snapshot(completion.stream_tracker)}
    after
      StreamTracker.stop(completion.stream_tracker)
    end
  end

  def format_provider_error(provider_config, reason) do
    message = format_error(reason)

    if auth_failure?(message) do
      prefix = auth_failure_prefix(provider_config)
      if prefix == "", do: message, else: "#{prefix}: #{message}"
    else
      message
    end
  end

  def prompt_too_long?(reason) when is_binary(reason) do
    normalized = String.downcase(reason)

    String.contains?(normalized, "context_length_exceeded") or
      String.contains?(normalized, "maximum context length") or
      String.contains?(normalized, "prompt is too long") or
      String.contains?(normalized, "prompt too long") or
      (String.contains?(normalized, "exceeded request buffer limit") and
         (String.contains?(normalized, "507") or String.contains?(normalized, "context") or
            String.contains?(normalized, "prompt")))
  end

  def prompt_too_long?(_), do: false

  defp call_provider_with_retry(
         provider,
         %State{} = state,
         outbound_messages,
         tool_defs,
         provider_config,
         streaming?,
         on_chunk,
         chunk_tracker,
         attempt,
         loop_opts
       ) do
    result =
      call_provider(provider, outbound_messages, tool_defs, provider_config, streaming?, on_chunk)

    case result do
      {:error, reason} ->
        if prompt_too_long?(format_error(reason)) do
          result
        else
          retry_config = retry_config(state, provider_config)

          case {Retry.should_retry_error?(reason, attempt, retry_config),
                StreamTracker.emitted?(chunk_tracker)} do
            {{:retry, _delay_ms}, false} ->
              if uncertain_cursor_error?(reason) do
                result
              else
                remaining = remaining_budget_ms(loop_opts)

                case Retry.delay_ms(attempt, retry_config,
                       retry_after_ms: retry_after_ms(reason),
                       remaining_ms: remaining
                     ) do
                  :budget_exceeded ->
                    {:error, {:run_budget_exceeded, reason}}

                  delay_ms ->
                    retry_provider_call(
                      provider,
                      state,
                      outbound_messages,
                      tool_defs,
                      provider_config,
                      streaming?,
                      on_chunk,
                      chunk_tracker,
                      attempt,
                      delay_ms,
                      reason,
                      loop_opts
                    )
                end
              end

            {_retry_result, _chunks_emitted?} ->
              result
          end
        end

      _ ->
        result
    end
  end

  defp retry_provider_call(
         provider,
         %State{} = state,
         outbound_messages,
         tool_defs,
         provider_config,
         streaming?,
         on_chunk,
         chunk_tracker,
         attempt,
         delay_ms,
         reason,
         loop_opts
       ) do
    Events.notify_progress(loop_opts, :provider_retry)

    Logger.warning(fn ->
      "[Turn] provider transient error, retrying attempt=#{attempt + 1} " <>
        "delay_ms=#{delay_ms} error=#{format_error(reason)}"
    end)

    parent = self()

    receive do
      :run_cancelled ->
        {:error, {:run_cancelled, reason}}
    after
      0 ->
        if not interruptible_sleep(delay_ms, loop_opts, parent) do
          {:error, {:run_budget_exceeded, reason}}
        else
          call_provider_with_retry(
            provider,
            state,
            outbound_messages,
            tool_defs,
            provider_config,
            streaming?,
            on_chunk,
            chunk_tracker,
            attempt + 1,
            loop_opts
          )
        end
    end
  end

  defp remaining_budget_ms(opts) do
    case Keyword.get(opts, :run_deadline) do
      deadline when is_integer(deadline) ->
        max(deadline - System.monotonic_time(:millisecond), 0)

      _ ->
        nil
    end
  end

  defp retry_after_ms(%{retry_after_ms: ms}) when is_integer(ms) and ms >= 0, do: ms

  defp retry_after_ms(%{headers: headers}) when is_list(headers) or is_map(headers) do
    header =
      Enum.find_value(headers, fn
        {key, value} -> if String.downcase(to_string(key)) == "retry-after", do: value
        _ -> nil
      end)

    if header, do: Retry.parse_retry_after(to_string(header)), else: 0
  end

  defp retry_after_ms(_reason), do: 0

  defp interruptible_sleep(delay_ms, opts, parent) do
    deadline = Keyword.get(opts, :run_deadline)

    wait =
      if is_integer(deadline),
        do: min(delay_ms, max(deadline - System.monotonic_time(:millisecond), 0)),
        else: delay_ms

    if wait <= 0 do
      false
    else
      ref = Process.monitor(parent)

      result =
        receive do
          :run_deadline_interrupt -> false
          :run_cancelled -> false
          {:DOWN, ^ref, :process, ^parent, _reason} -> false
        after
          wait -> is_nil(deadline) or System.monotonic_time(:millisecond) < deadline
        end

      Process.demonitor(ref, [:flush])
      result
    end
  end

  defp call_provider(provider, messages, tool_defs, provider_config, true, on_chunk)
       when is_list(messages) and is_function(on_chunk, 1) do
    ProviderGateway.stream(provider, messages, tool_defs, provider_config, on_chunk)
  end

  defp call_provider(provider, messages, tool_defs, provider_config, _streaming?, _on_chunk)
       when is_list(messages) do
    ProviderGateway.complete(provider, messages, tool_defs, provider_config)
  end

  defp retry_config(%State{config: config}, provider_config) do
    provider_config
    |> Map.put_new(:max_retries, Map.get(config.provider_config, :max_retries, 3))
    |> Map.put_new(
      :retry_delay_base_ms,
      Map.get(config.provider_config, :retry_delay_base_ms, 500)
    )
  end

  defp maybe_put_provider_event_callback(provider_config, opts) do
    case Keyword.get(opts, :on_event) do
      fun when is_function(fun, 1) -> Map.put(provider_config, :on_event, fun)
      _ -> provider_config
    end
  end

  defp maybe_put_on_chunk(provider_config, on_chunk) do
    if is_function(on_chunk, 1),
      do: Map.put(provider_config, :on_chunk, on_chunk),
      else: provider_config
  end

  defp apply_reasoning_level(provider_config, config) do
    model_entry =
      case Map.get(provider_config, :model_meta) do
        meta when is_map(meta) and map_size(meta) > 0 ->
          meta
          |> Map.put_new("id", config.model)
          |> Map.put_new(:provider, Map.get(provider_config, :provider))
          |> Map.put_new(:provider_id, Map.get(provider_config, :provider_key))
          |> Map.put_new(:api, Map.get(provider_config, :api))

        _ ->
          %{
            id: config.model,
            provider: Map.get(provider_config, :provider),
            provider_id: Map.get(provider_config, :provider_key),
            api: Map.get(provider_config, :api)
          }
      end

    Reasoning.apply_provider_options(provider_config, model_entry, config.reasoning_level)
  end

  defp maybe_put_context(provider_config, config) do
    context = config.context || %{}

    provider_config
    |> maybe_put(:conversation_id, context[:conversation_id])
    |> maybe_put(:run_id, context[:run_id])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp uncertain_cursor_error?(reason) when is_binary(reason) do
    String.contains?(reason, "not retrying because execution may have started")
  end

  defp uncertain_cursor_error?(_), do: false

  defp format_error({%Handbean.Agent.ErrorReporter.AgentRunError{} = exception, stacktrace})
       when is_list(stacktrace),
       do: Exception.message(exception)

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(reason) when is_exception(reason), do: Exception.message(reason)
  defp format_error(reason), do: inspect(reason)

  defp auth_failure?(message) when is_binary(message) do
    downcased = String.downcase(message)

    String.contains?(downcased, "oauth") or
      String.contains?(downcased, "access token") or
      String.contains?(downcased, "authorization") or
      String.contains?(downcased, "unauthor") or
      String.contains?(downcased, "sign in") or
      String.contains?(message, "订阅") or
      String.contains?(message, "授权") or
      String.contains?(message, "重新登录") or
      String.contains?(message, "重新连接")
  end

  defp auth_failure?(_), do: false

  defp auth_failure_prefix(provider_config) when is_map(provider_config) do
    provider_id = provider_config[:provider_key] || provider_config[:provider]
    model = provider_config[:model]

    [subscription_label(provider_id), model_label(provider_id, model)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp auth_failure_prefix(_), do: ""

  defp subscription_label(provider_id) when is_binary(provider_id) do
    case Handbean.Agent.Auth.Subscriptions.get(provider_id) do
      {:ok, %{login_label: label}} when is_binary(label) and label != "" -> label
      _ -> provider_id
    end
  end

  defp subscription_label(provider_id) when is_atom(provider_id) and not is_nil(provider_id) do
    subscription_label(Atom.to_string(provider_id))
  end

  defp subscription_label(_), do: nil

  defp model_label(_provider_id, model) when is_binary(model) and model != "", do: model
  defp model_label(_provider_id, _), do: nil
end
