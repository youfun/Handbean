defmodule HandbeanProbe.NativeApproval do
  @moduledoc """
  Native tool review and decisions using the existing Runner permission contract.

  `decide/5` never reloads the transcript: `HomeScreen` already binds the tap to
  the conversation id and `approval_seq`, and the Runner status check is the
  runtime source of truth. Rules are remembered only after `Coordinator.resume/2`
  succeeds.

  `chat.pending_approval` always has string keys (`"action_requests"`,
  `"tool_call_id"`, …): `HandbeanProbe.NativeChat.event_payload/1` normalises the
  live (atom-keyed) and the file-restored (string-keyed) Session payload once.
  `snapshots` values are the atom-keyed meta `NativeArtifactDelivery` binds.
  """
  use Gettext, backend: HandbeanProbe.Gettext
  import HandbeanProbe.NativeUI
  alias Handbean.Agent.Coordinator
  alias HandbeanProbe.Bridge.Payload

  def mode(nil), do: :prompt

  def mode(workspace),
    do: Handbean.WorkspaceSettings.permission_mode(workspace["path"])

  def mode_label(:auto_review), do: gettext("Smart approval")
  def mode_label(:prompt), do: gettext("Safe mode")
  def mode_label(:yolo), do: gettext("yolo")
  def mode_label(:deny), do: gettext("Read-only mode")

  def render_modes(mode) do
    [
      text(gettext("Tool permissions"), text_size: 18, padding_bottom: 12),
      text(
        gettext(
          "Saves to the current workspace and does not auto-approve a pending operation. More specific tool rules still take precedence."
        ),
        text_size: 12,
        padding_bottom: 12
      )
    ] ++
      Enum.flat_map(
        [
          {:prompt,
           gettext("Asks for approval by default, so you decide whether to run each tool.")},
          {:auto_review,
           gettext("Runs ordinary tools automatically. AI reviews operations that need approval.")},
          {:yolo,
           gettext(
             "Runs tools without asking. Built-in env and credential-path intercepts still apply."
           )}
        ],
        fn {value, description} ->
          [
            button(
              if(value == mode, do: "✓ ", else: "") <> mode_label(value),
              {:permission_mode, value},
              fill_width: true
            ),
            text(description, text_size: 12, padding: 10)
          ]
        end
      )
  end

  @doc """
  Submit a decision for the whole pending batch.

  Validation is the Runner status only; the caller (`HomeScreen`) has already
  matched conversation id and `approval_seq` against the tapped button. Returns
  `:ok`, `{:ok, :rule_not_saved}` when the Runner resumed but the workspace rule
  could not be written, or `{:error, reason}`.
  """
  def decide(chat, workspace, action, scope, snapshots \\ %{})
      when action in [:approve, :deny] and scope in [:once, :session, :always] do
    requests = requests(chat.pending_approval)
    conversation_id = chat.conversation["id"]

    with true <- requests != [],
         {:ok, %{status: :awaiting_approval}} <- Coordinator.status(conversation_id),
         :ok <- snapshot_ready(requests, action, snapshots),
         :ok <- Coordinator.resume(conversation_id, decisions_for(requests, action, scope)) do
      case remember(
             remember_requests(requests, action),
             workspace && workspace["path"],
             action,
             scope
           ) do
        :ok -> :ok
        {:error, _} -> {:ok, :rule_not_saved}
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :not_awaiting_approval}
    end
  end

  def validate_decide(pending, action, snapshots \\ %{}) do
    requests = requests(pending)

    with true <- requests != [],
         :ok <- snapshot_ready(requests, action, snapshots) do
      {:ok, decisions_for(requests, action, :once)}
    else
      false -> {:error, :not_awaiting_approval}
      {:error, reason} -> {:error, reason}
    end
  end

  def validate_decide_one(pending, selected_id, snapshots \\ %{}) do
    requests = requests(pending)
    selected = Enum.find(requests, &(&1["tool_call_id"] == selected_id))

    cond do
      is_nil(selected) ->
        {:error, :not_found}

      true ->
        with :ok <- exclusive_android_batch(requests, selected),
             :ok <- snapshot_ready([selected], :approve, snapshots) do
          :ok
        end
    end
  end

  def snapshots_ready?(pending, snapshots) do
    file_snapshots_ready?(requests(pending), snapshots)
  end

  def skipped_android_requests(pending, selected_id) do
    pending
    |> requests()
    |> Enum.filter(&(android_action?(&1) and &1["tool_call_id"] != selected_id))
  end

  defp snapshot_ready(_requests, :deny, _snapshots), do: :ok

  defp snapshot_ready(requests, :approve, snapshots) do
    if file_snapshots_ready?(requests, snapshots),
      do: :ok,
      else: {:error, :snapshot_not_ready}
  end

  defp decisions_for(requests, :deny, scope) do
    Enum.map(requests, &decision(&1, "deny", scope))
  end

  defp decisions_for(requests, :approve, scope) do
    chosen = requests |> Enum.filter(&android_action?/1) |> List.first()
    chosen_id = chosen && chosen["tool_call_id"]

    Enum.map(requests, fn req ->
      cond do
        not android_action?(req) ->
          decision(req, "approve", scope)

        req["tool_call_id"] == chosen_id ->
          decision(req, "approve", scope)

        true ->
          decision(req, "skip", :once)
      end
    end)
  end

  defp remember_requests(requests, :deny), do: requests

  defp remember_requests(requests, :approve) do
    chosen_id =
      requests
      |> Enum.filter(&android_action?/1)
      |> List.first()
      |> case do
        nil -> nil
        req -> req["tool_call_id"]
      end

    Enum.filter(requests, fn req ->
      not android_action?(req) or req["tool_call_id"] == chosen_id
    end)
  end

  defp decision(req, action, scope) do
    %{
      "tool_call_id" => req["tool_call_id"],
      "tool_name" => req["tool_name"],
      "action" => action,
      "remember" => scope == :session and action != "skip"
    }
  end

  defp exclusive_android_batch(requests, selected) do
    others = Enum.reject(requests, &(&1["tool_call_id"] == selected["tool_call_id"]))

    cond do
      Enum.any?(requests, &(not android_action?(&1))) and Enum.any?(requests, &android_action?/1) ->
        {:error, :mixed_approval_batch}

      Enum.any?(others, &(not android_action?(&1))) ->
        {:error, :mixed_approval_batch}

      true ->
        :ok
    end
  end

  defp android_action?(req) do
    Handbean.ArtifactDelivery.tool?(req["tool_name"] || "")
  end

  def render(chat, error, snapshots \\ %{}) do
    reqs = requests(chat.pending_approval)
    android_only? = reqs != [] and Enum.all?(reqs, &android_action?/1)
    file_ready? = file_snapshots_ready?(reqs, snapshots)

    node(:box, [approval_dialog: true], [
      node(
        :column,
        [fill_width: true, fill_height: true, padding: 16, background: color(:surface)],
        [
          row([
            text(gettext("Tool action needs approval"),
              text_size: 18,
              font_weight: "bold",
              weight: 1
            ),
            button(gettext("Later"), :dismiss_approval)
          ]),
          text(
            gettext(
              "Review the following actions. They run only after you allow them; later leaves them waiting."
            ),
            text_size: 12,
            padding: 8
          ),
          if(android_only?,
            do:
              text(
                gettext(
                  "The system browser opens an external app, not the Agent WebView in this conversation. Sharing or opening a file only means the system UI appeared, not that the other side has read or finished receiving it."
                ),
                text_size: 11,
                padding: 8
              )
          ),
          if(length(reqs) > 1,
            do:
              text(
                gettext(
                  "If you approve only one system open or share action, the other open or share actions are skipped this round and the Agent has to request them again; this is not recorded as a deny by you."
                ),
                text_size: 11,
                padding: 8
              )
          ),
          scroll(
            Enum.map(reqs, fn req ->
              snap = snapshots[req["tool_call_id"]]

              node(:column, [fill_width: true, padding: 10], [
                text(req["tool_name"], font_weight: "bold"),
                text(req["tool_call_id"], text_size: 11, selectable: true),
                text(Handbean.JSON.encode!(req["arguments"] || %{}, pretty: true),
                  text_size: 12,
                  selectable: true,
                  padding_top: 8
                ),
                snapshot_line(req, snap),
                text(
                  gettext("Remember rule: %{pattern}",
                    pattern: rule_pattern(req)
                  ),
                  text_size: 11,
                  padding_top: 8
                )
              ])
            end),
            id: "approval-details"
          ),
          notice(error),
          if(not file_ready?,
            do:
              text(
                gettext(
                  "Pinning the export copy; approval will not read a source file that is rewritten afterwards."
                ),
                text_size: 11,
                padding_bottom: 8
              )
          ),
          text(
            gettext(
              "Always allow/deny is saved to the current workspace; this session applies only to the current run."
            ),
            text_size: 11,
            padding_bottom: 8
          ),
          row(
            [
              action(chat, gettext("Deny"), :deny, :once),
              node(:box, width: 8),
              action(chat, gettext("Always deny"), :deny, :always)
            ],
            padding_bottom: 8
          ),
          if(file_ready?,
            do:
              row(
                [
                  action(chat, gettext("Allow once"), :approve, :once),
                  node(:box, width: 8),
                  action(chat, gettext("Allow this session"), :approve, :session)
                ],
                padding_bottom: 8
              )
          ),
          if(file_ready?, do: row([action(chat, gettext("Always allow"), :approve, :always)]))
        ]
      )
    ])
  end

  defp snapshot_line(req, snap) do
    cond do
      not Handbean.ArtifactDelivery.file_tool?(req["tool_name"] || "") ->
        nil

      is_map(snap) ->
        text(
          gettext("Pinned copy %{snapshot_id} · %{display_name} · %{size_bytes} bytes",
            snapshot_id: snap[:snapshot_id],
            display_name: snap[:display_name],
            size_bytes: snap[:size_bytes]
          ),
          text_size: 11,
          padding_top: 8
        )

      true ->
        text(gettext("Copying the export copy…"), text_size: 11, padding_top: 8)
    end
  end

  defp file_snapshots_ready?(reqs, snapshots) do
    reqs
    |> Enum.filter(&Handbean.ArtifactDelivery.file_tool?(&1["tool_name"] || ""))
    |> Enum.all?(fn req -> Map.has_key?(snapshots, req["tool_call_id"]) end)
  end

  defp action(chat, label, action, scope),
    do:
      button(label, {:approval, chat.conversation["id"], chat.approval_seq, action, scope},
        padding: 12,
        weight: 1,
        fill_width: true,
        text_align: "center"
      )

  # The remembered rule pattern defaults to the tool name.
  defp rule_pattern(req), do: Payload.first(req, ["suggested_pattern", "tool_name"])

  # `pending_approval` is normalised to string keys by
  # `HandbeanProbe.NativeChat.event_payload/1` when the event enters chat state.
  defp requests(nil), do: []
  defp requests(pending), do: pending["action_requests"] || []

  defp remember(_requests, nil, _action, :always), do: {:error, :no_workspace}

  defp remember(requests, path, action, :always) do
    list = if action == :approve, do: :allow, else: :deny

    Enum.reduce_while(requests, :ok, fn req, :ok ->
      pattern = rule_pattern(req)

      case Handbean.WorkspaceSettings.append_tool_rule(path, list, pattern) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp remember(_, _, _, _), do: :ok
end
