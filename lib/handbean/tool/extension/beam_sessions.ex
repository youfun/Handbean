defmodule Handbean.Tool.Extension.Beam.Sessions do
  @moduledoc """
  List all active Handbean agent sessions with metadata.

  Analogous to `tmux list-sessions`. Shows session_id, workspace, model,
  running status, turn count, and attached agent PID.

  Sessions are discovered via the SessionSupervisor and SessionRegistry.
  Use `ext__beam__session_snapshot` to capture a specific session's transcript.
  """

  @behaviour Handbean.Agent.Tool

  @impl true
  def name, do: "ext__beam__sessions"

  @impl true
  def description do
    "List all active Handbean agent sessions with metadata (session_id, workspace, model, status). " <>
      "Analogous to `tmux list-sessions`. Use ext__beam__session_snapshot to capture a specific session's transcript."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        filter: %{
          type: "string",
          description: "Optional filter: 'running' (only active runs), 'all' (default)"
        }
      },
      required: []
    }
  end

  @impl true
  def execute(input, _context) do
    filter = Map.get(input, "filter", "all")

    sessions =
      Handbean.SessionSupervisor.which_sessions()
      |> Enum.map(&child_to_info/1)
      |> Enum.reject(&is_nil/1)
      |> maybe_filter(filter)
      |> Enum.sort_by(& &1[:session_id])

    output = format_sessions(sessions)
    {:ok, output}
  end

  # ── Info collection ──

  defp child_to_info({:undefined, pid, :worker, [Handbean.PubSub.Session]}) do
    get_session_info(pid)
  end

  defp child_to_info(_other), do: nil

  defp get_session_info(pid) do
    try do
      snapshot = GenServer.call(pid, :snapshot, 2000)

      meta = Map.get(snapshot, :meta, %{})
      events = Map.get(snapshot, :events, [])

      %{
        session_id: Map.get(meta, :session_id) || extract_session_id(pid),
        pid: inspect(pid),
        alive: Process.alive?(pid),
        workspace: Map.get(meta, :workspace_path, "unknown"),
        model: Map.get(meta, :model, "unknown"),
        status: if(Map.get(meta, :running?, false), do: "🔵 running", else: "⏸️  idle"),
        event_count: length(events),
        last_seq: Map.get(snapshot, :last_seq, 0),
        agent_pid: maybe_inspect(Map.get(meta, :agent_pid)),
        queue_pid: maybe_inspect(Map.get(meta, :queue_pid)),
        run_id: Map.get(meta, :run_id)
      }
    catch
      :exit, {:timeout, _} ->
        %{
          session_id: extract_session_id(pid),
          pid: inspect(pid),
          alive: Process.alive?(pid),
          workspace: "unknown",
          model: "unknown",
          status: "⚠️  timeout",
          event_count: 0,
          last_seq: 0,
          agent_pid: nil,
          queue_pid: nil,
          run_id: nil
        }

      _, _ ->
        nil
    end
  end

  defp extract_session_id(pid) do
    # Try to get session_id from Registry
    case Registry.keys(Handbean.SessionRegistry, pid) do
      [session_id] -> session_id
      _ -> "unknown:#{inspect(pid)}"
    end
  end

  defp maybe_inspect(nil), do: nil
  defp maybe_inspect(pid) when is_pid(pid), do: inspect(pid)

  defp maybe_filter(sessions, "running") do
    Enum.filter(sessions, &(&1[:status] == "🔵 running"))
  end

  defp maybe_filter(sessions, _), do: sessions

  # ── Output formatting ──

  defp format_sessions([]) do
    "No active Handbean sessions found."
  end

  defp format_sessions(sessions) do
    total = length(sessions)
    running = Enum.count(sessions, &(&1[:status] == "🔵 running"))

    header = [
      "# Handbean Sessions (#{total} total, #{running} running)",
      ""
    ]

    table =
      Enum.map(sessions, fn s ->
        [
          "#{s.status}  #{s.session_id}",
          "  PID:       #{s.pid}",
          "  Workspace: #{s.workspace}",
          "  Model:     #{s.model}",
          if(s.run_id, do: "  Run:       #{s.run_id}"),
          "  Events:    #{s.event_count} (seq: #{s.last_seq})",
          ""
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")
      end)

    (header ++ table) |> Enum.join("\n")
  end
end
