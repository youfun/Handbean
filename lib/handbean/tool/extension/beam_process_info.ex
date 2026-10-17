defmodule Handbean.Tool.Extension.Beam.ProcessInfo do
  @moduledoc """
  Get detailed information about a specific BEAM process.

  Accepts a registered name (e.g. Handbean.Repo) or PID string (e.g. "0.500.0").
  Returns: state, message queue, memory, reductions, links, monitors,
  current function, and more.

  Security: :dictionary is filtered out (may contain sensitive data).
  GenServer state is truncated at 10KB.
  """

  @behaviour Handbean.Agent.Tool

  @max_state_size 10_000

  @impl true
  def name, do: "ext__beam__process_info"

  @impl true
  def description do
    "Get detailed information about a specific BEAM process. " <>
      "Accepts a registered name (e.g. Handbean.Repo) or PID string (e.g. \"0.500.0\")."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        process: %{
          type: "string",
          description: "Registered process name (e.g. Handbean.Repo) or PID (e.g. \"0.500.0\")"
        }
      },
      required: ["process"]
    }
  end

  @impl true
  def execute(%{"process" => process_str}, _context) do
    case resolve_pid(process_str) do
      {:ok, pid} ->
        info = collect_info(pid, process_str)
        output = format_output(info)
        {:ok, output}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def execute(_input, _context) do
    {:error, "process is required"}
  end

  # ── PID resolution ──

  defp resolve_pid(str) do
    cond do
      # Try as PID string like "0.500.0"
      String.match?(str, ~r/^<?\d+\.\d+\.\d+>?$/) ->
        clean = str |> String.trim("<") |> String.trim(">")
        pid = :erlang.list_to_pid(String.to_charlist(clean))
        {:ok, pid}

      # Try as registered atom name
      String.match?(str, ~r/^[A-Z][A-Za-z0-9]*(\.[A-Z][A-Za-z0-9]*)*$/) ->
        atom = Module.concat(["Elixir" | String.split(str, ".")])

        case Process.whereis(atom) do
          nil -> {:error, "No process registered as #{str}"}
          pid -> {:ok, pid}
        end

      true ->
        {:error,
         "Cannot parse process reference: #{str}. Use PID (0.500.0) or registered name (Handbean.Repo)."}
    end
  end

  # ── Info collection ──

  defp collect_info(pid, name) do
    alive? = Process.alive?(pid)

    base = %{
      name: name,
      pid: inspect(pid),
      alive: alive?,
      memory: 0,
      reductions: 0,
      message_queue_len: 0,
      links: [],
      monitors: [],
      current_function: nil,
      status: nil,
      registered_name: nil,
      group_leader: nil,
      trap_exit: false,
      error_handler: nil,
      gen_server_state: nil
    }

    if alive? do
      info = Process.info(pid) || []

      base
      |> put_info(info, :memory)
      |> put_info(info, :reductions)
      |> put_info(info, :message_queue_len)
      |> put_info(info, :status)
      |> put_info(info, :registered_name)
      |> put_info(info, :group_leader)
      |> put_info(info, :trap_exit)
      |> put_info(info, :error_handler)
      |> put_current_function(info)
      |> put_links_monitors(info)
      |> put_gen_server_state(pid)
    else
      Map.put(base, :gen_server_state, "(process not alive)")
    end
  end

  defp put_info(map, info, key) do
    case Keyword.get(info, key) do
      nil -> map
      val -> Map.put(map, key, val)
    end
  end

  defp put_current_function(map, info) do
    case Keyword.get(info, :current_function) do
      {m, f, a} -> Map.put(map, :current_function, "#{inspect(m)}.#{f}/#{a}")
      other -> Map.put(map, :current_function, inspect(other))
    end
  end

  defp put_links_monitors(map, info) do
    links = Keyword.get(info, :links, []) |> Enum.map(&inspect/1)
    monitors = Keyword.get(info, :monitors, []) |> Enum.map(&inspect/1)
    map |> Map.put(:links, links) |> Map.put(:monitors, monitors)
  end

  defp put_gen_server_state(map, pid) do
    try do
      state = :sys.get_state(pid)
      formatted = inspect(state, pretty: true, width: 100)

      truncated =
        if byte_size(formatted) > @max_state_size do
          head = binary_part(formatted, 0, @max_state_size)
          head <> "\n\n... [truncated at #{@max_state_size} bytes]"
        else
          formatted
        end

      Map.put(map, :gen_server_state, truncated)
    rescue
      _ -> Map.put(map, :gen_server_state, "(could not retrieve — not a gen_server?)")
    catch
      _, _ -> Map.put(map, :gen_server_state, "(could not retrieve)")
    end
  end

  # ── Output formatting ──

  defp format_output(info) do
    alive_str = if info.alive, do: "✅ alive", else: "❌ not alive"

    sections = [
      "#{info.name}  #{info.pid}  #{alive_str}",
      "",
      "## Basic Info",
      "  Status:        #{format_val(info.status)}",
      "  Memory:        #{format_bytes(info.memory)}",
      "  Reductions:    #{format_num(info.reductions)}",
      "  Message Queue: #{info.message_queue_len} messages",
      "  Current:       #{info.current_function}",
      "  Trap Exit:     #{info.trap_exit}",
      "",
      "## Links (#{length(info.links)})",
      format_list(info.links),
      "",
      "## Monitors (#{length(info.monitors)})",
      format_list(info.monitors),
      "",
      "## GenServer State",
      info.gen_server_state
    ]

    Enum.join(sections, "\n")
  end

  defp format_val(nil), do: "-"
  defp format_val(val) when is_atom(val), do: to_string(val)
  defp format_val(val) when is_pid(val), do: inspect(val)
  defp format_val(val), do: inspect(val)

  defp format_list([]), do: "  (none)"

  defp format_list(items) do
    items |> Enum.take(20) |> Enum.map_join("\n", &"  #{&1}")
  end

  defp format_bytes(bytes), do: "#{bytes} bytes"
  defp format_num(n), do: Integer.to_string(n)
end
