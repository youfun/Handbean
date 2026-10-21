defmodule Handbean.Agent.StreamBatchTest do
  use ExUnit.Case, async: false

  alias Handbean.Agent.StreamBatch

  setup do
    previous = Application.get_env(:handbean, :stream_flush)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:handbean, :stream_flush, previous),
        else: Application.delete_env(:handbean, :stream_flush)
    end)

    :ok
  end

  test "defaults to 50ms and 16KiB batches" do
    batch = StreamBatch.new()
    assert batch.max_wait_ms == 50
    assert batch.max_bytes == 16_384
  end

  test "per-run opts override the built-in defaults" do
    batch = StreamBatch.new(stream_flush_ms: 500, stream_flush_bytes: 1024)
    assert batch.max_wait_ms == 500
    assert batch.max_bytes == 1024
  end

  test "deployment config overrides the built-in defaults" do
    Application.put_env(:handbean, :stream_flush, ms: 250, bytes: 4096)

    batch = StreamBatch.new()
    assert batch.max_wait_ms == 250
    assert batch.max_bytes == 4096
  end

  test "per-run opts win over deployment config" do
    Application.put_env(:handbean, :stream_flush, ms: 250, bytes: 4096)

    batch = StreamBatch.new(stream_flush_ms: 20)
    assert batch.max_wait_ms == 20
    assert batch.max_bytes == 4096
  end

  test "non-positive deployment config falls back to the built-in defaults" do
    Application.put_env(:handbean, :stream_flush, ms: 0, bytes: -1)

    batch = StreamBatch.new()
    assert batch.max_wait_ms == 50
    assert batch.max_bytes == 16_384
  end
end
