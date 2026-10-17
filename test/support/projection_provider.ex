defmodule Handbean.TestSupport.ProjectionProvider do
  @moduledoc false
  @behaviour Handbean.Agent.Provider

  def complete(messages, tools, config) do
    Handbean.TestSupport.FakeProvider.complete(messages, tools, config)
  end

  def stream(messages, tools, config, on_chunk) do
    result =
      Handbean.TestSupport.FakeProvider.stream(
        messages,
        tools,
        Map.put(config, :scenario, :streaming_chunks),
        on_chunk
      )

    send(config.notify, {:projected_stream, self()})

    receive do
      :finish -> result
    end
  end
end
