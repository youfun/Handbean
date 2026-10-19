defmodule Handbean.Terminal.Session do
  @moduledoc """
  Per-terminal owner process.

  Owns a {Ghostty.Terminal, Ghostty.PTY} pair and handles message forwarding,
  state tracking, snapshot, input, resize, and cleanup.

  Registered in `Handbean.Terminal.Registry` under
  `{workspace_id, checkout_key, name}`.
  """

  use GenServer

  # Mobile and Windows builds intentionally omit the optional Ghostty dependency.
  @compile {:no_warn_undefined, Ghostty.PTY}
  @compile {:no_warn_undefined, Ghostty.Terminal}

  alias Handbean.Platform.ProcessRunner
  alias Handbean.Terminal.Registry

  @pubsub Handbean.PubSub

  @default_cols 120
  @default_rows 40
  @max_scrollback 10_000
  @pty_reader_timeout 2_000
  @max_snapshot_bytes 50_000
  @max_snapshot_lines 500

  defstruct workspace_id: nil,
            workspace_path: nil,
            checkout_key: nil,
            name: nil,
            cmd: nil,
            args: [],
            cwd: nil,
            term: nil,
            pty: nil,
            status: :starting,
            exit_status: nil,
            cols: @default_cols,
            rows: @default_rows,
            created_at: nil,
            updated_at: nil

  @type t :: %__MODULE__{}

  # ── Client API ──

  @doc """
  Starts a new terminal session.

  ## Options
    * `:workspace_id` — required, workspace identifier
    * `:workspace_path` — required, workspace filesystem path
    * `:name` — required, unique name within workspace
    * `:cmd` — command to run (default: `$SHELL` or `/bin/sh`)
    * `:args` — argument list (default: `[]`)
    * `:cwd` — working directory (default: workspace_path)
    * `:cols` — terminal columns (default: 120)
    * `:rows` — terminal rows (default: 40)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    workspace_id = Keyword.fetch!(opts, :workspace_id)
    checkout_key = Keyword.fetch!(opts, :checkout_key)
    name = Keyword.fetch!(opts, :name)

    case Registry.lookup(workspace_id, checkout_key, name) do
      {:ok, _pid} ->
        {:error, :already_exists}

      {:error, :not_found} ->
        GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc "Sends input to the PTY (child's stdin)."
  @spec send_input(pid(), binary()) :: :ok | {:error, term()}
  def send_input(session, input) when is_binary(input) do
    GenServer.call(session, {:send_input, input})
  end

  @doc """
  Returns terminal content as plain text.

  ## Options
    * `:tail` — return only the last N lines (default: all)
    * `:grep` — case-insensitive regex filter
    * `:format` — snapshot format (default: `:plain`)
  """
  @spec snapshot(pid(), keyword()) :: {:ok, binary()} | {:error, term()}
  def snapshot(session, opts \\ []) do
    GenServer.call(session, {:snapshot, opts})
  end

  @doc "Resizes the terminal and PTY."
  @spec resize(pid(), pos_integer(), pos_integer()) :: :ok | {:error, term()}
  def resize(session, cols, rows) do
    GenServer.call(session, {:resize, cols, rows})
  end

  @doc "Closes the terminal session (PTY + Terminal + process)."
  @spec close(pid()) :: :ok
  def close(session) do
    GenServer.call(session, :close)
  end

  @doc "Returns session metadata."
  @spec info(pid()) :: map()
  def info(session) do
    GenServer.call(session, :info)
  end

  @doc "Interactive login shell used by the workspace terminal panel."
  @spec interactive_shell() :: {String.t(), [String.t()]}
  def interactive_shell do
    cmd = default_shell()
    {cmd, default_shell_args(cmd)}
  end

  # ── Server Callbacks ──

  @impl true
  def init(opts) do
    workspace_id = Keyword.fetch!(opts, :workspace_id)
    workspace_path = Keyword.fetch!(opts, :checkout_path)
    checkout_key = Keyword.fetch!(opts, :checkout_key)
    name = Keyword.fetch!(opts, :name)
    cmd = Keyword.get(opts, :cmd) || default_shell()
    args = Keyword.get(opts, :args, default_shell_args(cmd))
    cwd = Keyword.get(opts, :cwd, workspace_path)
    cols = Keyword.get(opts, :cols, @default_cols)
    rows = Keyword.get(opts, :rows, @default_rows)

    # Build wrapped command with cwd
    {pty_cmd, pty_args} = build_pty_command(cmd, args, cwd)

    # Start Terminal first
    {:ok, term} =
      Ghostty.Terminal.start_link(
        cols: cols,
        rows: rows,
        max_scrollback: @max_scrollback,
        foreground: {205, 214, 244},
        background: {30, 30, 46},
        cursor_color: {137, 180, 250}
      )

    # Start PTY (Session is the owner, receives {:data, _}, {:exit, _})
    {:ok, pty} =
      Ghostty.PTY.start_link(
        cmd: pty_cmd,
        args: pty_args,
        cols: cols,
        rows: rows,
        reader_start_timeout: @pty_reader_timeout
      )

    now = DateTime.utc_now()

    state = %__MODULE__{
      workspace_id: workspace_id,
      workspace_path: workspace_path,
      checkout_key: checkout_key,
      name: name,
      cmd: cmd,
      args: args,
      cwd: cwd,
      term: term,
      pty: pty,
      status: :running,
      cols: cols,
      rows: rows,
      created_at: now,
      updated_at: now
    }

    # Register in the global registry
    case Registry.register(workspace_id, checkout_key, name, self()) do
      :ok -> {:ok, state}
      {:error, :already_exists} -> {:stop, :name_conflict}
    end
  end

  @impl true
  def handle_call({:send_input, input}, _from, state) do
    if state.status in [:running, :starting] do
      Ghostty.PTY.write(state.pty, input)
      {:reply, :ok, touch(state)}
    else
      {:reply, {:error, :not_running}, state}
    end
  end

  @impl true
  def handle_call({:snapshot, opts}, _from, state) do
    tail = Keyword.get(opts, :tail)
    grep = Keyword.get(opts, :grep)
    format = Keyword.get(opts, :format, :plain)

    result =
      with {:ok, text} <- Ghostty.Terminal.snapshot(state.term, format),
           text <- apply_grep(text, grep),
           text <- apply_tail(text, tail) do
        %{content: content} =
          Handbean.Utils.Truncate.truncate(text, :tail, max_bytes: @max_snapshot_bytes)

        {:ok, content}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:resize, cols, rows}, _from, state) do
    Ghostty.Terminal.resize(state.term, cols, rows)
    Ghostty.PTY.resize(state.pty, cols, rows)
    {:reply, :ok, %{state | cols: cols, rows: rows}}
  end

  @impl true
  def handle_call(:close, _from, state) do
    do_cleanup(state)
    # :shutdown ensures linked processes (PTY) receive exit signal
    # :normal would leave them running
    {:stop, :shutdown, :ok, %{state | status: :closing}}
  end

  @impl true
  def handle_call(:info, _from, state) do
    info = %{
      workspace_id: state.workspace_id,
      checkout_key: state.checkout_key,
      name: state.name,
      cmd: state.cmd,
      args: state.args,
      cwd: state.cwd,
      status: state.status,
      exit_status: state.exit_status,
      cols: state.cols,
      rows: state.rows,
      term: state.term,
      pty: state.pty,
      created_at: state.created_at,
      updated_at: state.updated_at
    }

    {:reply, info, state}
  end

  # ── handle_info: Message forwarding ──

  @impl true
  def handle_info({:data, data}, state) do
    Ghostty.Terminal.write(state.term, data)
    persist_output(state, data)
    broadcast_refresh(state)
    {:noreply, touch(state)}
  end

  @impl true
  def handle_info({:pty_write, data}, state) do
    if state.pty do
      Ghostty.PTY.write(state.pty, data)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:exit, status}, state) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      terminal_topic(state.workspace_id, state.checkout_key),
      {:terminal_exited, state.workspace_id, state.checkout_key, state.name, status}
    )

    {:noreply, %{state | status: :exited, exit_status: status}}
  end

  @impl true
  def handle_info(:bell, state), do: {:noreply, state}
  @impl true
  def handle_info(:title_changed, state), do: {:noreply, state}

  # ── Cleanup ──

  @impl true
  def terminate(_reason, state) do
    Registry.unregister(state.workspace_id, state.checkout_key, state.name)
    do_cleanup(state)
    :ok
  end

  defp do_cleanup(state) do
    # Ghostty.PTY.close/1 hangs on macOS (NIF reader thread issue).
    # Skip explicit PTY cleanup; the linked process tree handles it.
    # Terminal cleanup works fine.
    if state.term && Process.alive?(state.term) do
      Process.exit(state.term, :normal)
    end
  end

  # ── Helpers ──

  defp default_shell do
    System.get_env("SHELL", "/bin/sh")
  end

  defp default_shell_args(cmd) do
    case cmd |> Path.basename() |> String.downcase() do
      "fish" -> ["-i", "-l"]
      "nu" -> []
      base when base in ["sh", "dash"] -> []
      base when base in ["zsh", "bash", "ksh"] -> ["-il"]
      _ -> []
    end
  end

  defp build_pty_command(cmd, args, cwd) do
    exec = Enum.map_join([cmd | args], " ", &shell_escape/1)

    cd =
      if is_binary(cwd) and cwd != "" and cwd != File.cwd!() do
        "cd #{shell_escape(cwd)} && "
      else
        ""
      end

    # PTY children inherit the desktop release environment. Clear it before exec
    # so mix/iex use the machine OTP instead of release/bin/start.boot.
    {"/bin/sh", ["-c", "#{ProcessRunner.shell_prelude()}; #{cd}exec #{exec}"]}
  end

  defp shell_escape(str) do
    # Simple shell escaping for paths and arguments
    "'" <> String.replace(str, "'", "'\\''") <> "'"
  end

  defp apply_grep(text, nil), do: text
  defp apply_grep(text, ""), do: text

  defp apply_grep(text, pattern) do
    case Regex.compile(pattern, "iu") do
      {:ok, regex} ->
        text
        |> String.split("\n")
        |> Enum.filter(&Regex.match?(regex, &1))
        |> Enum.join("\n")

      {:error, _} ->
        text
    end
  end

  defp apply_tail(text, nil), do: text

  defp apply_tail(text, n) when is_integer(n) and n > 0 do
    capped = min(n, @max_snapshot_lines)
    lines = String.split(text, "\n")

    if length(lines) > capped do
      lines |> Enum.take(-capped) |> Enum.join("\n")
    else
      text
    end
  end

  defp touch(state) do
    %{state | updated_at: DateTime.utc_now()}
  end

  defp broadcast_refresh(state) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      terminal_topic(state.workspace_id, state.checkout_key),
      {:terminal_refresh, state.workspace_id, state.checkout_key, state.name}
    )
  end

  defp terminal_topic(workspace_id, checkout_key) do
    Handbean.CheckoutScope.terminal_topic(workspace_id, checkout_key)
  end

  # ── Output persistence ──

  defp persist_output(state, data) do
    dir = Path.join([state.workspace_path, ".handbean", "terminals"])
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{state.name}.log")
    File.write!(path, data, [:append])
  rescue
    _ -> :ok
  end
end
