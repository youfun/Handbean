defmodule Handbean.Platform.ProcessRunner.Invocation do
  @moduledoc """
  Supervised owner of one OS invocation.

  The business owner is monitored before `Port.open`. This process holds the
  port and cleans up the recorded invocation on cancel, owner death, or its
  own terminate. A supervisor must start it as temporary so a crash does not
  re-run the command. Callers cancel with a message; they must not kill this
  process to clean up.
  """

  use GenServer

  alias Handbean.Platform.ProcessRunner

  # The invocation keeps only a tail. Callers that want the body must consume
  # `:invocation_data` promptly; unread data is dropped rather than queued.
  @tail_bytes 50_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def run(opts) do
    Handbean.Platform.ProcessRunner.InvocationSupervisor.start_invocation(opts)
  end

  @impl true
  def init(opts) do
    business = Keyword.fetch!(opts, :business_owner)
    Process.monitor(business)
    if is_pid(opts[:reply_to]), do: Process.monitor(opts[:reply_to])

    {:ok,
     %{
       opts: opts,
       business: business,
       port: nil,
       os_pid: nil,
       invocation: nil,
       tail: [],
       tail_bytes: 0,
       total_bytes: 0,
       dropped_bytes: 0,
       cancelled: false
     }, {:continue, :open}}
  end

  @impl true
  def handle_continue(:open, state) do
    state =
      state
      |> drain_owner_down()
      |> then(fn current ->
        if current.opts[:hold_before_open], do: hold_before_open(current), else: current
      end)
      |> drain_owner_down()

    if state.cancelled do
      reply(state, {:error, :cancelled})
      {:stop, :normal, state}
    else
      open_and_track(state)
    end
  end

  defp drain_owner_down(state) do
    caller = state.opts[:reply_to]

    receive do
      {:DOWN, _ref, :process, pid, _reason} when pid == state.business or pid == caller ->
        drain_owner_down(%{state | cancelled: true})
    after
      0 ->
        if dead?(state.business) or dead?(caller) do
          %{state | cancelled: true}
        else
          state
        end
    end
  end

  defp dead?(pid) when is_pid(pid), do: not Process.alive?(pid)

  defp dead?(_pid), do: false

  defp hold_before_open(state) do
    send(state.opts[:hold_before_open], {:held_before_open, self()})
    await_release(state)
  end

  defp await_release(state) do
    caller = state.opts[:reply_to]

    receive do
      :release_open ->
        drain_release(state)

      {:DOWN, _ref, :process, pid, _reason} when pid == state.business or pid == caller ->
        await_release(%{state | cancelled: true})
    end
  end

  defp drain_release(state) do
    caller = state.opts[:reply_to]

    receive do
      :release_open ->
        drain_release(state)

      {:DOWN, _ref, :process, pid, _reason} when pid == state.business or pid == caller ->
        drain_release(%{state | cancelled: true})
    after
      50 -> state
    end
  end

  defp open_and_track(state) do
    case open_port(state.opts) do
      {:ok, port, os_pid, invocation} ->
        caller = state.opts[:reply_to]

        if is_pid(caller) do
          send(caller, {:invocation_opened, self(), os_pid})
        end

        {:noreply, %{state | port: port, os_pid: os_pid, invocation: invocation}}

      {:error, reason} ->
        reply(state, {:error, reason})
        {:stop, {:open_failed, reason}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    caller = state.opts[:reply_to]

    if pid == state.business or pid == caller do
      # The port owner stays alive until it finishes cleanup. A business-owner
      # or caller DOWN closes the port and kills the recorded OS pid. A DOWN
      # that arrives while Port.open is blocked is handled after open returns.
      # This does not cover :kill of this process or a VM crash.
      cleanup(state)
      reply(state, {:error, :cancelled})
      {:stop, :normal, %{state | port: nil}}
    else
      {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    output = tail_output(state)

    result =
      if code == 0 do
        {:ok, output, %{exit_code: 0, timed_out: false}}
      else
        content = if output == "", do: "", else: output <> "\n\n"
        {:ok, "#{content}Command exited with code #{code}", %{exit_code: code, timed_out: false}}
      end

    reply(state, result)
    {:stop, :normal, %{state | port: nil}}
  end

  def handle_info({port, {:data, data}}, %{port: port} = state) do
    maybe_forward(state, data)
    {:noreply, remember_tail(state, data)}
  end

  @impl true
  def handle_cast(:cancel, state) do
    cleanup(state)
    reply(state, {:error, "cancelled"})
    {:stop, :normal, %{state | port: nil}}
  end

  @impl true
  def terminate(_reason, state) do
    cleanup(state)
    :ok
  end

  defp open_port(opts) do
    ProcessRunner.open_tracked(opts)
  end

  defp cleanup(%{os_pid: pid, invocation: invocation}) when is_integer(pid) do
    ProcessRunner.cleanup_owned(pid, invocation || %{})
  end

  defp cleanup(_state), do: :ok

  defp maybe_forward(state, data) do
    caller = state.opts[:reply_to]

    if is_pid(caller) and Process.alive?(caller) do
      queued =
        case Process.info(caller, :message_queue_len) do
          {:message_queue_len, length} -> length
          _ -> 0
        end

      if queued < 64 do
        send(caller, {:invocation_data, self(), data})
      end
    end
  end

  defp remember_tail(state, data) do
    size = byte_size(data)
    tail = [data | state.tail]
    bytes = state.tail_bytes + size
    {tail, bytes, dropped} = trim_tail(tail, bytes, state.dropped_bytes)

    %{
      state
      | tail: tail,
        tail_bytes: bytes,
        total_bytes: state.total_bytes + size,
        dropped_bytes: dropped
    }
  end

  defp trim_tail(tail, bytes, dropped) when bytes <= @tail_bytes, do: {tail, bytes, dropped}

  defp trim_tail(tail, bytes, dropped) do
    [oldest | rest] = Enum.reverse(tail)
    size = byte_size(oldest)
    trim_tail(Enum.reverse(rest), bytes - size, dropped + size)
  end

  defp tail_output(state) do
    body = state.tail |> Enum.reverse() |> IO.iodata_to_binary()

    if state.dropped_bytes > 0 do
      "[#{state.dropped_bytes} earlier bytes omitted]\n" <> body
    else
      body
    end
  end

  defp reply(state, result) do
    if is_pid(state.opts[:reply_to]),
      do: send(state.opts[:reply_to], {:invocation_result, self(), result})
  end
end
