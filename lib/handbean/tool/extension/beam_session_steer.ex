defmodule Handbean.Tool.Extension.Beam.SessionSteer do
  @moduledoc """
  Send a message to another Handbean session — the OTP equivalent of `tmux send-keys`.

  Enqueues a candidate message into the target session's agent run.
  The message will be delivered as a `:steer` (mid-run) or `:next_turn`
  (between runs) depending on the target session's state.

  Use cases:
  - Cross-session collaboration: one agent asks another to check something
  - Debugging: inject a hint/question into a stuck agent session
  - Coordination: a "manager" agent directing "worker" agent sessions

  Use `ext__beam__sessions` to discover target session IDs first.
  """

  @behaviour Handbean.Agent.Tool

  @impl true
  def name, do: "ext__beam__session_steer"

  @impl true
  def description do
    "Send a message to another Handbean agent session. " <>
      "Analogous to `tmux send-keys -t <session>`. " <>
      "The message is delivered as a steer (mid-run) or queued for the next turn. " <>
      "Use ext__beam__sessions to discover target session IDs."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        session_id: %{
          type: "string",
          description: "Target session ID (discover via ext__beam__sessions)"
        },
        message: %{
          type: "string",
          description: "Message content to send to the target session's agent"
        },
        role: %{
          type: "string",
          description: "Message role: 'user' (default) or 'assistant'"
        },
        deliver_as: %{
          type: "string",
          description:
            "Delivery mode: 'steer' (mid-run, default), 'follow_up' (mid-run), or 'next_turn' (queued for next turn)"
        },
        ephemeral: %{
          type: "boolean",
          description:
            "If true, the message is NOT persisted to conversation history (default: false)"
        }
      },
      required: ["session_id", "message"]
    }
  end

  @impl true
  def execute(%{"session_id" => session_id, "message" => message} = input, _context) do
    deliver_as = parse_deliver_as(Map.get(input, "deliver_as", "steer"))
    role = parse_role(Map.get(input, "role", "user"))
    ephemeral? = Map.get(input, "ephemeral", false)

    # Build the message
    msg =
      case role do
        :user -> Handbean.Agent.Message.user(message)
        :assistant -> Handbean.Agent.Message.assistant(message)
      end

    # Resolve session PID
    case Handbean.PubSub.Session.whereis(session_id) do
      nil ->
        {:error,
         "Session '#{session_id}' not found. Use ext__beam__sessions to list active sessions."}

      pid ->
        # Get current session state to check if it's running
        snapshot = GenServer.call(pid, :snapshot, 2000)
        meta = Map.get(snapshot, :meta, %{})
        running? = Map.get(meta, :running?, false)

        result =
          Handbean.PubSub.Session.enqueue_candidate(session_id, msg,
            deliver_as: deliver_as,
            ephemeral: ephemeral?
          )

        case result do
          :ok ->
            target_state = if running?, do: "running", else: "idle"
            delivery = if running?, do: deliver_as, else: "next_turn (session is idle)"

            {:ok,
             """
             Message sent to session '#{session_id}' ✅
               Target status: #{target_state}
               Delivery mode: #{delivery}
               Role:          #{role}
               Ephemeral:     #{ephemeral?}
               Content:       #{String.slice(message, 0, 200)}
             """}

          {:error, reason} ->
            {:error, "Failed to send message: #{inspect(reason)}"}
        end
    end
  end

  def execute(_input, _context) do
    {:error, "session_id and message are required"}
  end

  # ── Parsing ──

  defp parse_deliver_as("follow_up"), do: :follow_up
  defp parse_deliver_as("next_turn"), do: :next_turn
  defp parse_deliver_as(_), do: :steer

  defp parse_role("assistant"), do: :assistant
  defp parse_role("system"), do: :system
  defp parse_role(_), do: :user
end
