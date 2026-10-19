defmodule HandbeanWeb.Live.TerminalPanel do
  @moduledoc """
  Terminal panel LiveView component.

  Opens an interactive shell for the current workspace. Click the screen to
  type freely (including Ctrl-C, Tab, and arrows). The line below sends a
  command on Enter. Preset buttons start or focus a dedicated session.
  """

  use HandbeanWeb, :live_component

  # Mobile and Windows builds intentionally omit the optional Ghostty dependency.
  @compile {:no_warn_undefined, Ghostty.LiveTerminal.Component}

  alias Handbean.Terminal.{Session, Supervisor}

  @session_call_timeout 2_000

  @preset_commands [
    %{label: "mix phx.server", name: "dev-server", cmd: "mix", args: ["phx.server"]},
    %{label: "mix test", name: "tests", cmd: "mix", args: ["test"]},
    %{label: "mix compile", name: "compile", cmd: "mix", args: ["compile"]},
    %{label: "iex -S mix", name: "iex", cmd: "iex", args: ["-S", "mix"]},
    %{label: "npm run dev", name: "npm-dev", cmd: "npm", args: ["run", "dev"]},
    %{label: "git log", name: "git-log", cmd: "git", args: ["log", "--oneline"]}
  ]

  @impl true
  def mount(socket) do
    {:ok, socket}
  end

  @impl true
  def update(assigns, socket) do
    {action, clean_assigns} = Map.pop(assigns, :action)
    # send_update from the parent only includes the new keys. A refresh must
    # not require workspace_id to be passed again.
    workspace_id = clean_assigns[:workspace_id] || socket.assigns[:workspace_id]
    checkout_path = clean_assigns[:workspace_path] || socket.assigns[:workspace_path]

    socket =
      socket
      |> reset_if_scope_changed(workspace_id, checkout_path)
      |> assign(clean_assigns)
      |> assign_new(:create_error, fn -> nil end)
      |> assign_new(:confirm_close, fn -> nil end)
      |> assign_new(:restart_target, fn -> nil end)
      |> assign_new(:active_terminal_name, fn -> nil end)
      |> assign_new(:active_term_pid, fn -> nil end)
      |> assign_new(:active_pty_pid, fn -> nil end)
      |> assign_new(:activity, fn -> %{} end)
      |> assign_new(:bootstrapped, fn -> false end)
      |> assign_new(:command_nonce, fn -> 0 end)
      |> assign(:preset_commands, @preset_commands)
      |> then(fn sock ->
        if workspace_id && checkout_path,
          do: assign_terminals(sock, workspace_id),
          else: assign(sock, :terminals, [])
      end)
      |> maybe_bootstrap_shell()

    {:ok, handle_action(action, socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="terminal-panel flex flex-col h-full min-h-0 bg-main">
      <style>
        #terminal-panel { display: flex; flex-direction: column; height: 100%; min-height: 0; }
        #terminal-panel .terminal-presets { display: flex; flex-wrap: wrap; gap: 4px; padding: 6px 8px; border-bottom: 1px solid var(--color-border, #333); }
        #terminal-panel .terminal-preset { border: 1px solid var(--color-border, #333); border-radius: 4px; background: transparent; color: var(--color-text-tertiary, #888); font-family: ui-monospace, monospace; font-size: 10px; padding: 2px 8px; cursor: pointer; }
        #terminal-panel .terminal-viewport { flex: 1 1 auto; min-height: 0; display: flex; flex-direction: column; overflow: hidden; background: #1e1e2e; }
        #terminal-panel .terminal-screen { flex: 1 1 auto; min-height: 0; width: 100%; height: 100%; overflow: auto; background: #1e1e2e; }
        #terminal-panel .terminal-screen pre { margin: 0 !important; padding: 8px !important; line-height: 1.2 !important; font-size: 13px !important; font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace !important; background: #1e1e2e !important; color: #cdd6f4 !important; border-radius: 0 !important; overflow: hidden !important; white-space: pre !important; box-sizing: border-box !important; }
        #terminal-panel .terminal-command-bar { display: flex; align-items: center; gap: 6px; min-height: 34px; padding: 4px 8px; border-top: 1px solid var(--color-border, #333); background: var(--color-surface, #111); }
        #terminal-panel .terminal-command-input { flex: 1 1 auto; min-width: 0; border: 0; background: transparent; color: var(--color-text-primary, #eee); font-family: ui-monospace, monospace; font-size: 12px; outline: none; }
        #terminal-panel .terminal-command-input:disabled { opacity: 0.5; }
        #terminal-panel .terminal-interrupt { border: 0; background: transparent; color: var(--color-text-tertiary, #888); font-family: ui-monospace, monospace; font-size: 11px; cursor: pointer; padding: 2px 6px; }
      </style>
      <div class="flex items-center border-b bg-surface px-2 h-9 gap-1">
        <div class="flex items-center overflow-x-auto flex-1 gap-0.5">
          <button
            :for={t <- @terminals}
            phx-click="select_terminal"
            phx-value-name={t.name}
            phx-target={@myself}
            class={[
              "terminal-tab",
              if(@active_terminal_name == t.name, do: "active", else: "")
            ]}
          >
            <span class={["status-dot", t.status]}></span>
            <span
              :if={show_activity?(@activity, t.name, @active_terminal_name)}
              class="activity-dot"
            ></span>
            <span class="truncate max-w-[120px]">{t.name}</span>
          </button>
          <div :if={@terminals == []} class="px-3 py-1 text-xs text-tertiary italic">
            starting shell…
          </div>
        </div>

        <div class="flex items-center gap-1 flex-shrink-0">
          <button
            :if={@active_terminal_name && terminal_exited?(@terminals, @active_terminal_name)}
            phx-click="restart_terminal"
            phx-target={@myself}
            class="terminal-action-btn text-yellow-500"
            title="Restart terminal"
          >
            ↻
          </button>
          <button
            phx-click="new_shell"
            phx-target={@myself}
            class="terminal-action-btn"
            title="New shell"
          >
            +
          </button>
          <button
            :if={@active_terminal_name}
            phx-click="confirm_close_terminal"
            phx-target={@myself}
            class="terminal-action-btn text-error"
            title="Close terminal"
          >
            ×
          </button>
        </div>
      </div>

      <div class="terminal-presets">
        <button
          :for={preset <- @preset_commands}
          phx-click="run_preset"
          phx-value-name={preset.name}
          phx-target={@myself}
          class="terminal-preset"
          title={"Open #{preset.label}"}
        >
          {preset.label}
        </button>
      </div>

      <div :if={@confirm_close} class="border-b bg-surface p-3">
        <p class="text-xs text-primary mb-2">
          Close terminal "<span class="font-semibold">{@confirm_close}</span>"?
          Any running process will be terminated.
        </p>
        <div class="flex gap-2">
          <button
            phx-click="close_terminal"
            phx-target={@myself}
            class="bg-error text-white text-xs px-3 py-1 rounded"
          >
            Close
          </button>
          <button
            phx-click="cancel_close"
            phx-target={@myself}
            class="text-xs text-tertiary hover:text-primary px-2 py-1"
          >
            Cancel
          </button>
        </div>
      </div>

      <div :if={@restart_target} class="border-b bg-surface p-3">
        <p class="text-xs text-primary mb-2">
          Restart terminal "<span class="font-semibold">{@restart_target}</span>"?
        </p>
        <div class="flex gap-2">
          <button
            phx-click="do_restart_terminal"
            phx-target={@myself}
            class="bg-accent text-white text-xs px-3 py-1 rounded"
          >
            Restart
          </button>
          <button
            phx-click="cancel_restart"
            phx-target={@myself}
            class="text-xs text-tertiary hover:text-primary px-2 py-1"
          >
            Cancel
          </button>
        </div>
      </div>

      <div :if={@create_error} class="border-b bg-surface px-3 py-2 flex items-center gap-2">
        <span class="text-xs text-error flex-1">{@create_error}</span>
        <button
          phx-click="retry_shell"
          phx-target={@myself}
          class="text-xs text-accent hover:underline"
        >
          Retry
        </button>
      </div>

      <div class="terminal-viewport">
        <%= if @active_terminal_name && @active_term_pid && @active_pty_pid do %>
          <.live_component
            module={Ghostty.LiveTerminal.Component}
            id={"term-#{@active_terminal_name}"}
            term={@active_term_pid}
            pty={@active_pty_pid}
            fit={true}
            autofocus={true}
            class="terminal-screen"
          />
        <% else %>
          <div class="flex items-center justify-center h-full text-tertiary text-xs">
            <div class="text-center space-y-2">
              <div class="text-2xl opacity-30">▸_</div>
              <p>Opening a shell…</p>
            </div>
          </div>
        <% end %>
      </div>

      <form
        id="terminal-command-form"
        phx-submit="send_line"
        phx-target={@myself}
        class="terminal-command-bar"
      >
        <span class="terminal-prompt" aria-hidden="true">❯</span>
        <input
          id={"terminal-command-input-#{@command_nonce}"}
          name="line"
          type="text"
          placeholder={
            if @active_pty_pid, do: "Type a command and press Enter", else: "Starting shell…"
          }
          autocomplete="off"
          autocapitalize="off"
          autocorrect="off"
          spellcheck="false"
          enterkeyhint="send"
          class="terminal-command-input"
          disabled={!@active_pty_pid}
        />
        <button
          type="button"
          phx-click="interrupt"
          phx-target={@myself}
          class="terminal-interrupt"
          title="Send Ctrl-C"
          disabled={!@active_pty_pid}
        >
          ^C
        </button>
      </form>
    </div>
    """
  end

  @impl true
  def handle_event("select_terminal", %{"name" => name}, socket) do
    {:noreply,
     socket
     |> activate_terminal(name)
     |> clear_activity(name)}
  end

  def handle_event("new_shell", _params, socket) do
    {:noreply, start_shell(socket)}
  end

  def handle_event("retry_shell", _params, socket) do
    {:noreply, start_shell(socket)}
  end

  def handle_event("run_preset", %{"name" => name}, socket) do
    preset = Enum.find(@preset_commands, &(&1.name == name))

    socket =
      cond do
        is_nil(preset) ->
          socket

        terminal_running?(socket.assigns.terminals, name) ->
          activate_terminal(socket, name)

        terminal_known?(socket.assigns.terminals, name) ->
          restart_named(socket, name, preset.cmd, preset.args)

        true ->
          start_named(socket, name, preset.cmd, preset.args)
      end

    {:noreply, clear_activity(socket, name)}
  end

  def handle_event("send_line", params, socket) do
    line = params["line"] || ""
    {:noreply, deliver_input(socket, to_string(line) <> "\n")}
  end

  def handle_event("interrupt", _params, socket) do
    {:noreply, deliver_input(socket, <<3>>)}
  end

  def handle_event("confirm_close_terminal", _params, socket) do
    {:noreply, assign(socket, :confirm_close, socket.assigns.active_terminal_name)}
  end

  def handle_event("cancel_close", _params, socket) do
    {:noreply, assign(socket, :confirm_close, nil)}
  end

  def handle_event("close_terminal", _params, socket) do
    name = socket.assigns.confirm_close
    workspace_id = socket.assigns.workspace_id

    Supervisor.stop_terminal(workspace_id, socket.assigns.workspace_path, name)

    socket =
      socket
      |> assign(:confirm_close, nil)
      |> assign_terminals(workspace_id)

    socket =
      if socket.assigns.active_terminal_name == name do
        next = List.first(socket.assigns.terminals)

        socket
        |> assign(:active_terminal_name, nil)
        |> assign(:active_term_pid, nil)
        |> assign(:active_pty_pid, nil)
        |> then(fn sock ->
          if next, do: activate_terminal(sock, next.name), else: start_shell(sock)
        end)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("restart_terminal", _params, socket) do
    {:noreply, assign(socket, :restart_target, socket.assigns.active_terminal_name)}
  end

  def handle_event("cancel_restart", _params, socket) do
    {:noreply, assign(socket, :restart_target, nil)}
  end

  def handle_event("do_restart_terminal", _params, socket) do
    name = socket.assigns.restart_target
    old = Enum.find(socket.assigns.terminals, &(&1.name == name))

    socket =
      socket
      |> assign(:restart_target, nil)
      |> then(fn sock ->
        if old do
          restart_named(sock, name, old.cmd, old.args || [])
        else
          start_shell(sock)
        end
      end)

    {:noreply, socket}
  end

  defp handle_action({:terminal_refresh, term_name}, socket) do
    socket =
      socket
      |> assign_terminals(socket.assigns.workspace_id)
      |> mark_activity(term_name)

    if socket.assigns.active_terminal_name == term_name do
      send_update(Ghostty.LiveTerminal.Component,
        id: "term-#{term_name}",
        refresh: true
      )
    end

    socket
  end

  defp handle_action({:terminal_exited, _term_name, _status}, socket) do
    assign_terminals(socket, socket.assigns.workspace_id)
  end

  defp handle_action({:terminal_ready, "term-" <> name, cols, rows}, socket) do
    with cols when is_integer(cols) <- normalize_dim(cols),
         rows when is_integer(rows) <- normalize_dim(rows),
         {:ok, pid} <-
           Supervisor.lookup(socket.assigns.workspace_id, socket.assigns.workspace_path, name) do
      Session.resize(pid, cols, rows)
    end

    socket
  end

  defp handle_action(_action, socket), do: socket

  defp reset_if_scope_changed(socket, workspace_id, checkout_path) do
    previous = {socket.assigns[:workspace_id], socket.assigns[:workspace_path]}
    current = {workspace_id, checkout_path}

    if elem(previous, 0) && previous != current do
      socket
      |> assign(:bootstrapped, false)
      |> assign(:active_terminal_name, nil)
      |> assign(:active_term_pid, nil)
      |> assign(:active_pty_pid, nil)
      |> assign(:activity, %{})
      |> assign(:create_error, nil)
      |> assign(:confirm_close, nil)
      |> assign(:restart_target, nil)
      |> assign(:command_nonce, 0)
    else
      socket
    end
  end

  defp maybe_bootstrap_shell(socket) do
    cond do
      not connected?(socket) ->
        socket

      socket.assigns.bootstrapped ->
        ensure_active(socket)

      not is_binary(socket.assigns[:workspace_path]) or socket.assigns.workspace_path == "" ->
        assign(socket, :bootstrapped, true)

      Enum.any?(socket.assigns.terminals, &shell_session?/1) ->
        socket
        |> assign(:bootstrapped, true)
        |> ensure_active()

      true ->
        socket
        |> assign(:bootstrapped, true)
        |> start_shell()
    end
  end

  defp ensure_active(socket) do
    name = socket.assigns.active_terminal_name
    terminals = socket.assigns.terminals

    cond do
      name && terminal_known?(terminals, name) && socket.assigns.active_pty_pid ->
        socket

      name && terminal_known?(terminals, name) ->
        activate_terminal(socket, name)

      terminals != [] ->
        preferred =
          Enum.find(terminals, &shell_session?/1) ||
            Enum.find(terminals, &(&1.status == :running)) ||
            List.first(terminals)

        activate_terminal(socket, preferred.name)

      true ->
        socket
    end
  end

  defp start_shell(socket) do
    {cmd, args} = Session.interactive_shell()
    start_named(socket, next_shell_name(socket.assigns.terminals), cmd, args)
  end

  defp start_named(socket, name, cmd, args) do
    workspace_id = socket.assigns.workspace_id

    case Supervisor.start_terminal(workspace_id, socket.assigns.workspace_path, name,
           cmd: cmd,
           args: args
         ) do
      {:ok, _pid} ->
        socket
        |> assign(:create_error, nil)
        |> assign_terminals(workspace_id)
        |> activate_terminal(name)
        |> clear_activity(name)

      {:error, :already_exists} ->
        socket
        |> assign_terminals(workspace_id)
        |> activate_terminal(name)

      {:error, reason} ->
        assign(socket, :create_error, "Failed to start #{name}: #{inspect(reason)}")
    end
  end

  defp restart_named(socket, name, cmd, args) do
    Supervisor.stop_terminal(socket.assigns.workspace_id, socket.assigns.workspace_path, name)
    start_named(socket, name, cmd, args)
  end

  defp deliver_input(socket, input) do
    name = socket.assigns.active_terminal_name

    socket =
      with true <- is_binary(name),
           {:ok, pid} <-
             Supervisor.lookup(socket.assigns.workspace_id, socket.assigns.workspace_path, name),
           :ok <- Session.send_input(pid, input) do
        assign(socket, :create_error, nil)
      else
        false -> assign(socket, :create_error, "No terminal is open")
        {:error, :not_running} -> assign(socket, :create_error, "Terminal is not running")
        {:error, :not_found} -> assign(socket, :create_error, "Terminal is gone")
        {:error, reason} -> assign(socket, :create_error, "Send failed: #{inspect(reason)}")
      end

    # New input id so the line field remounts empty after Enter or Ctrl-C.
    update(socket, :command_nonce, &((&1 || 0) + 1))
  end

  defp assign_terminals(socket, workspace_id) do
    assign(
      socket,
      :terminals,
      Supervisor.list_terminals(workspace_id, socket.assigns[:workspace_path])
    )
  end

  defp activate_terminal(socket, nil) do
    socket
    |> assign(:active_terminal_name, nil)
    |> assign(:active_term_pid, nil)
    |> assign(:active_pty_pid, nil)
  end

  defp activate_terminal(socket, name) do
    case Supervisor.lookup(socket.assigns.workspace_id, socket.assigns.workspace_path, name) do
      {:ok, session_pid} ->
        case safe_session_info(session_pid) do
          {:ok, info} ->
            socket
            |> assign(:active_terminal_name, name)
            |> assign(:active_term_pid, info.term)
            |> assign(:active_pty_pid, info.pty)

          {:error, _reason} ->
            socket
            |> assign(:active_terminal_name, name)
            |> assign(:active_term_pid, nil)
            |> assign(:active_pty_pid, nil)
        end

      {:error, :not_found} ->
        socket
        |> assign(:active_terminal_name, nil)
        |> assign(:active_term_pid, nil)
        |> assign(:active_pty_pid, nil)
    end
  end

  defp safe_session_info(pid) do
    try do
      {:ok, GenServer.call(pid, :info, @session_call_timeout)}
    catch
      :exit, {:timeout, _} -> {:error, :timeout}
      :exit, _ -> {:error, :dead}
    end
  end

  defp next_shell_name(terminals) do
    names = MapSet.new(Enum.map(terminals, & &1.name))

    Stream.iterate(1, &(&1 + 1))
    |> Enum.find_value(fn
      1 -> if MapSet.member?(names, "shell"), do: nil, else: "shell"
      n -> if MapSet.member?(names, "shell-#{n}"), do: nil, else: "shell-#{n}"
    end)
  end

  defp shell_session?(%{cmd: cmd, status: :running}), do: shell_cmd?(cmd)
  defp shell_session?(_), do: false

  defp shell_cmd?(cmd) when is_binary(cmd) do
    cmd |> Path.basename() |> String.downcase() |> Kernel.in(~w(zsh bash sh fish dash ksh nu))
  end

  defp shell_cmd?(_), do: false

  defp terminal_known?(terminals, name), do: Enum.any?(terminals, &(&1.name == name))

  defp terminal_running?(terminals, name) do
    Enum.any?(terminals, &(&1.name == name && &1.status == :running))
  end

  defp terminal_exited?(terminals, name) do
    Enum.any?(terminals, &(&1.name == name && &1.status == :exited))
  end

  defp mark_activity(socket, term_name) do
    assign(socket, :activity, Map.put(socket.assigns.activity, term_name, true))
  end

  defp clear_activity(socket, term_name) do
    assign(socket, :activity, Map.put(socket.assigns.activity, term_name, false))
  end

  defp show_activity?(activity, term_name, active_name) do
    term_name != active_name && Map.get(activity, term_name, false)
  end

  defp normalize_dim(n) when is_integer(n) and n > 0, do: n

  defp normalize_dim(n) when is_binary(n) do
    case Integer.parse(n) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp normalize_dim(_), do: nil
end
