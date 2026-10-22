defmodule HandbeanProbe.HomeScreen.State do
  @moduledoc """
  The complete assigns shape of `HandbeanProbe.HomeScreen`.

  The struct *is* `socket.assigns`: `mount/3` installs `new/1` and every
  handler reads and writes these fields through `Mob.Socket.assign/3`
  (`Map.put` on a struct keeps the struct). Fields are grouped by domain;
  each group is owned by one `HandbeanProbe.HomeScreen.*` module.

  `Access` is implemented so collaborators that historically used
  `socket.assigns[:key]` on a plain map (`NativeArtifactDelivery`,
  `NativeWorkspaceOpen`, `NativeWorkspaceTree`) work unchanged, and their
  unit tests can keep building bare-map sockets.

  There is exactly one user-facing message channel, `notice`
  (`HandbeanProbe.HomeScreen.Notice`), replacing the former `error` /
  `share_notice` / `delivery_notice` trio.

  There is exactly one request-correlation table, `pending_requests`
  (`HandbeanProbe.PendingRequests`). It also holds every generation counter
  (`:composer`, `:workspace_open`, `:share`, `:models`, `:folder`), replacing
  the former per-domain `*_generation` assigns.
  """

  @behaviour Access

  alias HandbeanProbe.{
    ModelSettings,
    NativeFileViewer,
    NativeSchedules,
    NativeWorkspaces,
    NativeWorkspaceTree,
    PendingRequests
  }

  defstruct [
    # ── nav ──
    page: :chat,
    workspace: nil,
    workspaces: nil,
    conversations: [],
    history: %{pinned: [], free: [], workspaces: []},
    inactive_history_open: false,
    collapsed_history_groups: MapSet.new(),
    conversation_menu_id: nil,
    rename_conversation: nil,
    conversation_activity: %{},
    bean_frame: 0,
    bean_timer: nil,
    free_draft: false,
    notice: nil,

    # ── chat ──
    chat: nil,
    draft: "",
    drafts: %{},
    workspace_command_intent: nil,
    stopping: false,
    permission_mode: :prompt,
    deliver_mode: :steer,
    composer_mode: :chat,
    review_place: "",
    review_feeling: "",
    steer_hint_shown: false,
    work_groups: %{},
    work_segments: %{},
    tool_outputs: %{},
    file_diffs: %{},
    approval_open: true,
    approval_snapshots: %{},
    approval_export_inflight: nil,
    timeline_open: nil,

    # ── settings ──
    models: nil,
    workspace_memory: nil,
    mcp: nil,
    git: nil,
    app_settings: nil,

    # ── scheduled tasks ──
    schedules: nil,

    # ── platform (composer attachments / system UI requests) ──
    pending_attachments: [],
    input_warning: nil,
    composer_open_id: nil,
    composer_select: nil,
    pending_requests: nil,
    last_platform_request: nil,

    # ── share intake ──
    share_intakes: [],
    share_confirming: %{},
    merged_intake_ids: nil,
    share_send: nil,
    last_send_ack: nil,

    # ── file navigation ──
    workspace_tree: nil,
    workspace_panel_tab: :files,
    changes_ui: nil,
    file_viewer: nil,

    # ── subagent navigation ──
    expanded_handoffs: nil,
    conversation_stack: []
  ]

  @type t :: %__MODULE__{}

  @doc "Fresh assigns. `overrides` win over defaults."
  @spec new(keyword() | map()) :: t()
  def new(overrides \\ []) do
    struct!(
      %__MODULE__{
        workspaces: NativeWorkspaces.empty_state(),
        models: ModelSettings.empty(),
        workspace_memory: HandbeanProbe.WorkspaceMemory.new(),
        mcp: HandbeanProbe.MCPSettings.empty(),
        git: HandbeanProbe.GitSettings.empty(),
        schedules: NativeSchedules.new(),
        approval_export_inflight: MapSet.new(),
        pending_requests: PendingRequests.new(),
        merged_intake_ids: MapSet.new(),
        workspace_tree: NativeWorkspaceTree.idle(),
        changes_ui: %{
          expanded: MapSet.new(),
          confirming: nil,
          status_overrides: %{},
          feedback: nil
        },
        expanded_handoffs: MapSet.new(),
        file_viewer: NativeFileViewer.new()
      },
      overrides
    )
  end

  @doc """
  Fields that reset when the chat context changes (new chat, conversation or
  workspace switch). Composer and share state are reset separately by
  `HandbeanProbe.HomeScreen.Nav.reset_composer/1`.
  """
  @spec chat_reset() :: keyword()
  def chat_reset do
    [
      notice: nil,
      workspace_command_intent: nil,
      stopping: false,
      page: :chat,
      work_groups: %{},
      work_segments: %{},
      tool_outputs: %{},
      file_diffs: %{},
      approval_open: true,
      workspace_panel_tab: :files,
      changes_ui: %{
        expanded: MapSet.new(),
        confirming: nil,
        status_overrides: %{},
        feedback: nil
      },
      expanded_handoffs: MapSet.new(),
      conversation_stack: []
    ]
  end

  @impl Access
  def fetch(state, key), do: Map.fetch(state, key)

  @impl Access
  def get_and_update(state, key, fun), do: Map.get_and_update(state, key, fun)

  @impl Access
  def pop(state, key), do: Map.pop(state, key)
end
