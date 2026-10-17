defmodule Handbean.Tool.Extension.Beam.SessionSnapshot do
  @moduledoc """
  Capture a Handbean session's transcript — the OTP equivalent of `tmux capture-pane`.

  Given a session_id, returns the session's recent event timeline, including:
  - Agent messages (user prompts, assistant responses, tool calls, tool results)
  - Stream deltas stitched into full assistant responses
  - Run metadata

  Use `ext__beam__sessions` to discover active session IDs first.

  This enables cross-session context sharing: one agent session can read
  another's transcript to understand what the other is working on, debug
  errors, or collaborate.
  """

  @behaviour Handbean.Agent.Tool

  @default_event_limit 50
  @max_event_limit 200

  @impl true
  def name, do: "ext__beam__session_snapshot"

  @impl true
  def description do
    "Capture a Handbean session's transcript. " <>
      "Returns the recent event timeline including messages and tool results. " <>
      "Analogous to `tmux capture-pane -t <session>`. " <>
      "Use ext__beam__sessions first to discover active session IDs."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        session_id: %{
          type: "string",
          description: "The session ID to capture (discover via ext__beam__sessions)"
        },
        limit: %{
          type: "integer",
          description:
            "Max events to return (default: #{@default_event_limit}, max: #{@max_event_limit})"
        },
        kind_filter: %{
          type: "string",
          description:
            "Optional event kind filter. Use 'messages' for conversation-only, 'tools' for tool events, or leave empty for all."
        }
      },
      required: ["session_id"]
    }
  end

  @impl true
  def execute(%{"session_id" => session_id} = input, _context) do
    limit = clamp_limit(Map.get(input, "limit", @default_event_limit))
    kind_filter = Map.get(input, "kind_filter")

    case Handbean.PubSub.Session.whereis(session_id) do
      nil ->
        {:error,
         "Session '#{session_id}' not found. Use ext__beam__sessions to list active sessions."}

      pid ->
        snapshot = GenServer.call(pid, :snapshot, 2000)

        events =
          snapshot
          |> Map.get(:events, [])
          |> maybe_filter_events(kind_filter)
          |> Enum.take(limit)
          |> Enum.reverse()
          |> Enum.map(&format_event/1)

        output = build_output(session_id, snapshot, events)
        {:ok, output}
    end
  end

  def execute(_input, _context) do
    {:error, "session_id is required"}
  end

  # ── Event formatting ──

  defp format_event(event) do
    kind = get_kind(event)
    payload = get_payload(event)
    _seq = get_seq(event)

    format_event(kind, payload)
  end

  defp format_event(:run_start, payload) do
    " [run_start] model=#{safe_get_in(payload, [:model])} workspace=#{safe_get_in(payload, [:workspace_path])}"
  end

  defp format_event(:user_message, payload) do
    content = safe_get_in(payload, [:content]) || ""
    " [user] #{trunc_str(content, 500)}"
  end

  defp format_event(:assistant_message, payload) do
    content = safe_get_in(payload, [:content]) || ""
    " [assistant] #{trunc_str(content, 500)}"
  end

  defp format_event(:tool_start, payload) do
    name = safe_get_in(payload, [:name]) || "unknown"
    inp = safe_get_in(payload, [:input]) || %{}
    " [tool_start] #{name}(#{trunc_str(inspect(inp), 200)})"
  end

  defp format_event(:tool_end, payload) do
    name = safe_get_in(payload, [:name]) || "unknown"
    is_err = safe_get_in(payload, [:is_error]) || false
    result = safe_get_in(payload, [:result]) || ""
    status = if is_err, do: "ERROR", else: "OK"
    " [tool_end] #{name} → #{status} #{trunc_str(result, 200)}"
  end

  # Skip individual deltas — they're noise in cross-session context
  defp format_event(:message_delta, _payload), do: nil

  defp format_event(:run_end, payload) do
    " [run_end] usage=#{inspect(safe_get_in(payload, [:usage]) || %{})}"
  end

  defp format_event(:interrupted, payload) do
    reason = safe_get_in(payload, [:reason]) || "unknown"
    " [interrupted] reason=#{reason}"
  end

  defp format_event(kind, payload) do
    " [#{kind}] #{trunc_str(inspect(payload), 300)}"
  end

  defp maybe_filter_events(events, "messages") do
    Enum.filter(events, fn e ->
      kind = get_kind(e)
      kind in [:user_message, :assistant_message, :run_start, :run_end]
    end)
  end

  defp maybe_filter_events(events, "tools") do
    Enum.filter(events, fn e ->
      kind = get_kind(e)
      kind in [:tool_start, :tool_end]
    end)
  end

  defp maybe_filter_events(events, _), do: events

  # ── Output ──

  defp build_output(session_id, snapshot, formatted_events) do
    meta = Map.get(snapshot, :meta, %{})
    last_seq = Map.get(snapshot, :last_seq, 0)

    filtered =
      formatted_events
      |> Enum.reject(&is_nil/1)

    [
      "# Session: #{session_id}",
      "  Status:   #{if Map.get(meta, :running?, false), do: "running", else: "idle"}",
      "  Model:    #{Map.get(meta, :model, "unknown")}",
      "  Workspace: #{Map.get(meta, :workspace_path, "unknown")}",
      "  Events:   #{length(filtered)} shown (seq: #{last_seq})",
      "",
      "── Transcript ──",
      "",
      Enum.join(filtered, "\n"),
      ""
    ]
    |> Enum.join("\n")
  end

  # ── Struct-agnostic field access (events may be maps or structs) ──

  defp get_kind(%{kind: kind}), do: kind
  defp get_kind(%{"kind" => kind}) when is_binary(kind), do: known_kind(kind)
  defp get_kind(%{"kind" => kind}) when is_atom(kind), do: kind
  defp get_kind(_), do: :unknown

  defp known_kind("run_start"), do: :run_start
  defp known_kind("user_message"), do: :user_message
  defp known_kind("assistant_message"), do: :assistant_message
  defp known_kind("tool_start"), do: :tool_start
  defp known_kind("tool_end"), do: :tool_end
  defp known_kind("message_delta"), do: :message_delta
  defp known_kind("run_end"), do: :run_end
  defp known_kind("interrupted"), do: :interrupted
  defp known_kind(other), do: other

  defp get_payload(%{payload: p}), do: p
  defp get_payload(%{"payload" => p}), do: p
  defp get_payload(_), do: %{}

  defp get_seq(%{seq: s}), do: s
  defp get_seq(%{"seq" => s}), do: s
  defp get_seq(_), do: 0

  defp safe_get_in(map, keys) when is_map(map) do
    Enum.reduce(keys, map, fn
      k, m when is_map(m) -> Map.get(m, k) || Map.get(m, to_string(k))
      _k, _m -> nil
    end)
  end

  defp safe_get_in(_, _), do: nil

  # ── Helpers ──

  defp clamp_limit(n) when is_integer(n) and n > @max_event_limit, do: @max_event_limit
  defp clamp_limit(n) when is_integer(n) and n < 1, do: @default_event_limit
  defp clamp_limit(n) when is_integer(n), do: n
  defp clamp_limit(_), do: @default_event_limit

  defp trunc_str(s, max_value) when byte_size(s) <= max_value, do: s
  defp trunc_str(s, max_value), do: String.slice(s, 0, max_value - 3) <> "..."
end
