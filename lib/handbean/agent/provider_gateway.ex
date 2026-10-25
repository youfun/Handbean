defmodule Handbean.Agent.ProviderGateway do
  @moduledoc """
  The Handbean-owned boundary for provider calls.

  When local secret masking is enabled, semantic request fields are masked
  before the provider runs and restored in both streamed and final responses.
  """

  alias Handbean.Agent.SecretMasking.Store
  alias Handbean.Agent.SecretMasking.StreamRestorer
  alias Handbean.Agent.SecretMasking.Transformer
  alias Handbean.Settings.Security

  @spec complete(module(), [Handbean.Agent.Message.t()], [map()], map()) ::
          {:ok, Handbean.Agent.Provider.completion_response()} | {:error, term()}
  def complete(provider, messages, tools, config) do
    invoke(provider, :complete, messages, tools, config, nil)
  end

  @spec stream(module(), [Handbean.Agent.Message.t()], [map()], map(), (term() -> term())) ::
          {:ok, Handbean.Agent.Provider.completion_response()} | {:error, term()}
  def stream(provider, messages, tools, config, on_chunk) when is_function(on_chunk, 1) do
    invoke(provider, :stream, messages, tools, config, on_chunk)
  end

  defp invoke(provider, mode, messages, tools, config, on_chunk) do
    case Security.secret_masking_enabled?() do
      {:ok, false} -> call_provider(provider, mode, messages, tools, config, on_chunk)
      {:ok, true} -> invoke_masked(provider, mode, messages, tools, config, on_chunk)
      {:error, reason} -> masking_error(reason)
    end
  end

  defp invoke_masked(provider, mode, messages, tools, config, on_chunk) do
    with {:ok, prepared} <- Store.prepare(messages, tools, config, masking_store()) do
      run_masked_provider(provider, mode, prepared, on_chunk)
    else
      {:error, reason} -> masking_error(reason)
    end
  end

  defp run_masked_provider(provider, mode, prepared, explicit_on_chunk) do
    chunk_callback = explicit_on_chunk || Map.get(prepared.config, :on_chunk)
    event_callback = Map.get(prepared.config, :on_event)
    {:ok, stream_agent} = Agent.start_link(fn -> StreamRestorer.new(prepared.restore) end)

    wrapped_chunk = wrap_callback(stream_agent, :chunk, chunk_callback, event_callback)
    wrapped_event = wrap_callback(stream_agent, :event, chunk_callback, event_callback)

    config =
      prepared.config
      |> maybe_put_callback(:on_chunk, wrapped_chunk)
      |> maybe_put_callback(:on_event, wrapped_event)

    try do
      result =
        call_provider(
          provider,
          mode,
          prepared.messages,
          prepared.tools,
          config,
          wrapped_chunk
        )

      finish_masked_result(result, stream_agent, chunk_callback, event_callback, prepared.restore)
    after
      stop_agent(stream_agent)
    end
  end

  defp finish_masked_result(
         {:ok, response},
         stream_agent,
         chunk_callback,
         event_callback,
         restore
       ) do
    with {:ok, outputs} <- finish_stream(stream_agent),
         :ok <- dispatch(outputs, chunk_callback, event_callback),
         {:ok, response} <- Transformer.restore_response(response, restore) do
      {:ok, response}
    else
      {:error, reason} -> masking_error(reason)
    end
  end

  defp finish_masked_result({:error, _reason} = error, _agent, _chunk, _event, _restore),
    do: error

  defp finish_masked_result(_other, _agent, _chunk, _event, _restore),
    do: masking_error(:invalid_provider_response)

  defp finish_stream(agent) do
    Agent.get_and_update(agent, fn state ->
      case StreamRestorer.finish(state) do
        {:ok, state, outputs} -> {{:ok, outputs}, state}
        {:error, reason} -> {{:error, reason}, state}
      end
    end)
  catch
    :exit, reason -> {:error, {:secret_masking_stream_unavailable, reason}}
  end

  defp wrap_callback(agent, source, chunk_callback, event_callback) do
    callback = if source == :chunk, do: chunk_callback, else: event_callback

    if is_function(callback, 1) do
      fn event ->
        outputs =
          Agent.get_and_update(agent, fn state ->
            {state, outputs} = StreamRestorer.push(state, source, event)
            {outputs, state}
          end)

        dispatch(outputs, chunk_callback, event_callback)
      end
    else
      nil
    end
  end

  defp dispatch(outputs, chunk_callback, event_callback) do
    Enum.each(outputs, fn
      {:chunk, event} when is_function(chunk_callback, 1) -> chunk_callback.(event)
      {:event, event} when is_function(event_callback, 1) -> event_callback.(event)
      _output -> :ok
    end)

    :ok
  end

  defp call_provider(provider, :stream, messages, tools, config, on_chunk)
       when is_function(on_chunk, 1) do
    if Code.ensure_loaded?(provider) and function_exported?(provider, :stream, 4),
      do: provider.stream(messages, tools, config, on_chunk),
      else: provider.complete(messages, tools, config)
  end

  defp call_provider(provider, _mode, messages, tools, config, _on_chunk) do
    provider.complete(messages, tools, config)
  end

  defp maybe_put_callback(config, _key, nil), do: config
  defp maybe_put_callback(config, key, callback), do: Map.put(config, key, callback)

  defp stop_agent(agent) do
    Agent.stop(agent)
  catch
    :exit, _reason -> :ok
  end

  defp masking_store do
    Application.get_env(:handbean, :secret_masking_store, Store)
  end

  defp masking_error(reason), do: {:error, {:secret_masking_failed, reason}}
end
