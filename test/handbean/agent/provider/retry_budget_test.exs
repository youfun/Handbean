defmodule Handbean.Agent.Provider.RetryBudgetTest do
  use ExUnit.Case, async: true

  alias Handbean.Agent.Provider.Retry

  test "Retry-After seconds are not shortened by the cap and do not exceed remaining budget" do
    config = %{retry_delay_base_ms: 500, retry_delay_cap_ms: 30_000, jitter_ms: 0}

    assert Retry.delay_ms(0, config, retry_after_ms: 45_000, remaining_ms: 60_000) == 45_000

    assert Retry.delay_ms(0, config, retry_after_ms: 45_000, remaining_ms: 10_000) ==
             :budget_exceeded
  end

  test "OpenAI-compatible adapter keeps Retry-After seconds and Turn does not send a second request" do
    assert_retry_after_header_stops_second_request([{"retry-after", "45"}])
  end

  test "OpenAI-compatible adapter keeps an HTTP-date Retry-After and Turn does not send a second request" do
    later =
      DateTime.utc_now()
      |> DateTime.add(45, :second)
      |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")

    assert_retry_after_header_stops_second_request([{"Retry-After", later}])
  end

  test "Turn does not issue the next provider call when Retry-After exceeds remaining budget" do
    parent = self()

    provider =
      Module.concat(__MODULE__, "RetryAfter#{System.unique_integer([:positive])}")

    defmodule provider do
      @behaviour Handbean.Agent.Provider

      def complete(_messages, _tool_defs, config) do
        send(config.notify, :provider_called)
        {:error, %{retry_after_ms: 45_000, reason: "HTTP 429: slow down"}}
      end

      def stream(messages, tool_defs, config, _on_chunk),
        do: complete(messages, tool_defs, config)
    end

    config = %Handbean.Agent.Config{
      provider: provider,
      provider_config: %{notify: parent, max_retries: 3},
      model: "fake",
      working_directory: File.cwd!(),
      context: %{}
    }

    state = Handbean.Agent.State.init(config, "retry")

    task =
      Task.async(fn ->
        Handbean.Agent.Turn.run_loop(state,
          run_deadline: System.monotonic_time(:millisecond) + 100
        )
      end)

    assert_receive :provider_called, 1_000
    refute_receive :provider_called, 150
    _ = Task.shutdown(task, :brutal_kill)
  end

  defp assert_retry_after_header_stops_second_request(headers) do
    parent = self()
    calls = :counters.new(1, [])

    defmodule RetryAfterReq do
      def post(_url, _opts) do
        {calls, parent, headers} = :persistent_term.get(:retry_after_stub)
        :counters.add(calls, 1, 1)
        send(parent, {:http, :counters.get(calls, 1)})
        {:ok, %{status: 429, body: %{"error" => %{"message" => "slow"}}, headers: headers}}
      end
    end

    :persistent_term.put(:retry_after_stub, {calls, parent, headers})

    config = %Handbean.Agent.Config{
      provider: Handbean.Agent.Provider.OpenAICompat,
      provider_config: %{
        api_key: "test",
        base_url: "http://retry-after.test/v1",
        req_module: RetryAfterReq,
        max_retries: 3,
        retry_delay_base_ms: 1
      },
      model: "fake",
      working_directory: File.cwd!(),
      context: %{}
    }

    state = Handbean.Agent.State.init(config, "retry header")

    task =
      Task.async(fn ->
        Handbean.Agent.Turn.run_loop(state,
          run_deadline: System.monotonic_time(:millisecond) + 80,
          streaming: false
        )
      end)

    assert_receive {:http, 1}, 1_000
    result = Task.await(task, 2_000)
    assert :counters.get(calls, 1) == 1
    assert result.status == :error
    assert result.error =~ "429" or result.error =~ "budget"
    refute_receive {:http, 2}, 50
  end

  test "cancel during backoff does not issue the next provider request" do
    parent = self()
    calls = :counters.new(1, [])

    provider =
      Module.concat(__MODULE__, "CancelBackoff#{System.unique_integer([:positive])}")

    defmodule provider do
      @behaviour Handbean.Agent.Provider

      def complete(_messages, _tool_defs, config) do
        :counters.add(config.calls, 1, 1)
        send(config.notify, {:provider_called, self()})
        {:error, "HTTP 429: slow down"}
      end

      def stream(messages, tool_defs, config, _on_chunk),
        do: complete(messages, tool_defs, config)
    end

    config = %Handbean.Agent.Config{
      provider: provider,
      provider_config: %{notify: parent, calls: calls, max_retries: 3, retry_delay_base_ms: 5_000},
      model: "fake",
      working_directory: File.cwd!(),
      context: %{}
    }

    state = Handbean.Agent.State.init(config, "cancel backoff")

    task =
      Task.async(fn ->
        Handbean.Agent.Turn.run_loop(state, streaming: false)
      end)

    assert_receive {:provider_called, turn_pid}, 2_000
    send(turn_pid, :run_cancelled)
    result = Task.await(task, 1_000)
    assert :counters.get(calls, 1) == 1
    assert result.status == :error
    refute_receive {:provider_called, _}, 80
  end

  test "an HTTP-date Retry-After is later than the 30s cap" do
    later =
      DateTime.utc_now()
      |> DateTime.add(40, :second)
      |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")

    ms = Retry.parse_retry_after(later)
    assert ms > 30_000
    assert ms < 50_000
  end
end
