defmodule Handbean.Runtime.MacNotify do
  @moduledoc """
  macOS shell adapter for run-lifecycle notifications.

  Installed only when the GUI app spawned this BEAM and passed a loopback
  bridge. A finished reply becomes a system banner unless the user is
  looking at that conversation. Browser flashes and the Android adapter
  are unchanged. The shell owns UserNotifications.
  """

  @behaviour Handbean.Runtime.NotifyAdapter

  alias Handbean.Settings.UI
  alias __MODULE__.Bridge

  require Logger

  @impl true
  def app_visible? do
    case :ets.lookup(Bridge.table(), :visible) do
      [{:visible, false}] -> false
      _ -> true
    end
  catch
    :error, :badarg -> true
  end

  @impl true
  def apply({:update_running, snapshot}) do
    Bridge.notify(running_payload(snapshot))
    :ok
  end

  def apply({:system_ended, task, reason}) do
    Bridge.notify(ended_payload(task, reason, locale()))
    :ok
  end

  def apply({:in_app_ended, task, reason}) do
    apply({:system_ended, task, reason})
  end

  @doc false
  def prefers_system_notification?, do: true

  @doc false
  def children do
    if configured?(), do: [Bridge], else: []
  end

  @doc false
  def configured? do
    is_integer(Application.get_env(:handbean, :macos_notify_port)) and
      is_binary(Application.get_env(:handbean, :macos_notify_token)) and
      Application.get_env(:handbean, :macos_notify_token) != ""
  end

  @doc false
  def ended_payload(task, reason, locale) when reason in [:completed, :failed, :cancelled] do
    Gettext.with_locale(Handbean.Gettext, locale, fn ->
      %{
        "op" => "show_ended",
        "reason" => Atom.to_string(reason),
        "title" => "Handbean",
        "body" => clip(ended_body(task, reason), 240),
        "conversation_id" => task.conversation_id,
        "workspace_id" => task[:workspace_id],
        "run_id" => task.run_id
      }
    end)
  end

  defp running_payload(%{running_count: running, waiting_count: waiting}) do
    %{"op" => "update_running", "running_count" => running, "waiting_count" => waiting}
  end

  defp ended_body(task, reason) do
    title = display_title(task)

    case reason do
      :cancelled ->
        Gettext.gettext(Handbean.Gettext, "Agent stopped in %{title}.", title: title)

      :failed ->
        Gettext.gettext(Handbean.Gettext, "This run ended in %{title}.", title: title)

      _ ->
        Gettext.gettext(Handbean.Gettext, "Agent replied in %{title}.", title: title)
    end
  end

  defp display_title(task) do
    title =
      case task[:title] do
        title when is_binary(title) and title != "" -> title
        _ -> Gettext.gettext(Handbean.Gettext, "conversation")
      end

    clip(title, 80)
  end

  defp clip(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max - 1) <> "…", else: text
  end

  defp locale do
    UI.locale() || default_locale()
  rescue
    exception in [DBConnection.OwnershipError, DBConnection.ConnectionError] ->
      Logger.warning("mac notify locale lookup failed: #{inspect(exception.__struct__)}")
      default_locale()
  end

  defp default_locale do
    :handbean
    |> Application.get_env(Handbean.Gettext, [])
    |> Keyword.get(:default_locale)
    |> UI.valid_locale() || "zh_CN"
  end

  defmodule Bridge do
    @moduledoc false
    use GenServer

    require Logger

    @table :handbean_mac_notify
    @max_queue 16

    def table, do: @table

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end

    def notify(payload) when is_map(payload) do
      case Process.whereis(__MODULE__) do
        pid when is_pid(pid) ->
          GenServer.cast(pid, {:line, Handbean.JSON.encode!(payload) <> "\n"})

        _ ->
          :ok
      end

      :ok
    end

    @impl true
    def init(opts) do
      ensure_table()
      port = Keyword.get(opts, :port, Application.get_env(:handbean, :macos_notify_port))
      token = Keyword.get(opts, :token, Application.get_env(:handbean, :macos_notify_token))

      state = %{
        port: port,
        token: token,
        socket: nil,
        queue: :queue.new(),
        delay: 200,
        failures: 0,
        connecting?: false
      }

      if is_integer(port) and is_binary(token) and token != "" do
        {:ok, state, {:continue, :connect}}
      else
        {:ok, state}
      end
    end

    @impl true
    def handle_continue(:connect, state), do: {:noreply, connect(state)}

    @impl true
    def handle_cast({:line, _line}, %{port: nil} = state), do: {:noreply, state}

    def handle_cast({:line, line}, state) do
      {:noreply, state |> enqueue(line) |> flush()}
    end

    @impl true
    def handle_info(:reconnect, %{socket: socket} = state) when is_port(socket),
      do: {:noreply, state}

    def handle_info(:reconnect, state), do: {:noreply, connect(state)}

    def handle_info({:tcp, socket, line}, %{socket: socket} = state) do
      :inet.setopts(socket, active: :once)
      {:noreply, apply_shell(state, line)}
    end

    def handle_info({:tcp_closed, socket}, %{socket: socket} = state), do: {:noreply, drop(state)}

    def handle_info({:tcp_error, socket, _reason}, %{socket: socket} = state),
      do: {:noreply, drop(state)}

    def handle_info(_message, state), do: {:noreply, state}

    @impl true
    def terminate(_reason, state) do
      close_socket(state.socket)

      if :ets.whereis(@table) != :undefined do
        :ets.insert(@table, {:visible, true})
      end

      :ok
    end

    defp connect(%{port: port, token: token} = state)
         when is_integer(port) and is_binary(token) do
      opts = [:binary, active: false, packet: :line, packet_size: 4_096, nodelay: true]

      case :gen_tcp.connect({127, 0, 0, 1}, port, opts, 1_000) do
        {:ok, socket} ->
          hello = Handbean.JSON.encode!(%{"op" => "hello", "token" => token}) <> "\n"

          case :gen_tcp.send(socket, hello) do
            :ok ->
              :inet.setopts(socket, active: :once)
              flush(%{state | socket: socket, delay: 200, failures: 0, connecting?: false})

            _ ->
              close_socket(socket)
              schedule(%{state | socket: nil, connecting?: false})
          end

        _ ->
          schedule(%{state | socket: nil, connecting?: false})
      end
    end

    defp connect(state), do: state

    defp apply_shell(state, line) do
      line = line |> to_string() |> String.trim_trailing("\r")

      case Handbean.JSON.decode(line) do
        {:ok, %{"op" => "visible", "value" => visible}} when is_boolean(visible) ->
          :ets.insert(@table, {:visible, visible})

        _ ->
          :ok
      end

      state
    end

    defp enqueue(state, line) do
      queue = :queue.in(line, state.queue)

      queue =
        if :queue.len(queue) > @max_queue do
          {_, queue} = :queue.out(queue)
          queue
        else
          queue
        end

      %{state | queue: queue}
    end

    defp flush(%{socket: nil} = state), do: state

    defp flush(%{socket: socket, queue: queue} = state) do
      case :queue.out(queue) do
        {{:value, line}, rest} ->
          case :gen_tcp.send(socket, line) do
            :ok ->
              flush(%{state | queue: rest})

            _ ->
              close_socket(socket)
              schedule(%{state | socket: nil})
          end

        {:empty, _} ->
          state
      end
    end

    defp drop(state) do
      close_socket(state.socket)
      schedule(%{state | socket: nil})
    end

    defp schedule(%{connecting?: true} = state), do: state

    defp schedule(state) do
      failures = state.failures + 1

      if failures == 1 do
        Logger.warning("[MacNotify] system notification bridge unavailable")
      end

      Process.send_after(self(), :reconnect, state.delay)
      %{state | connecting?: true, failures: failures, delay: min(state.delay * 2, 2_000)}
    end

    defp close_socket(socket) when is_port(socket), do: :gen_tcp.close(socket)
    defp close_socket(_socket), do: :ok

    defp ensure_table do
      case :ets.whereis(@table) do
        :undefined ->
          :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])

        _tid ->
          :ok
      end

      :ets.insert(@table, {:visible, true})
    end
  end
end
