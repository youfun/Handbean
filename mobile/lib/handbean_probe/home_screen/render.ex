defmodule HandbeanProbe.HomeScreen.Render do
  @moduledoc """
  Pure projection of `HandbeanProbe.HomeScreen.State` into Mob nodes. No IO: sent
  image paths are precomputed on the chat entries, and every collaborator
  render function is a pure function of the assigns it receives.
  """

  use Gettext, backend: HandbeanProbe.Gettext
  import HandbeanProbe.NativeUI

  alias HandbeanProbe.HomeScreen.{Nav, Notice, SettingsHub, Share}

  alias HandbeanProbe.{
    ModelSettings,
    MCPSettings,
    GitSettings,
    NativeApproval,
    NativeComposer,
    NativeSchedules,
    NativeTimeline,
    NativeWorkspaceOpen,
    NativeWorkspaces,
    WorkspaceMemory
  }

  @settings_detail_pages [
    :models,
    :model_ai,
    :workspace_models,
    :memory,
    :workspace,
    :mcp,
    :git,
    :app,
    :appearance
  ]

  def render(a) do
    if NativeWorkspaceOpen.overlay?(a) do
      NativeWorkspaceOpen.render_overlay(a)
    else
      shell(a)
    end
  end

  defp shell(%{page: page_name} = a) when page_name in [:chat, :history] do
    node(
      :box,
      [
        fill_width: true,
        fill_height: true,
        background: color(:surface),
        history_shell: true,
        drawer_open: page_name == :history,
        back_target: if(page_name == :history, do: inspect({:page, :chat}))
      ],
      [
        render_page(%{a | page: :chat, approval_open: a.approval_open and page_name == :chat}),
        if(page_name == :history, do: render_page(a))
      ]
    )
  end

  defp shell(a), do: render_page(a)

  defp render_page(a) do
    back_target =
      cond do
        a.page == :settings -> inspect({:page, :chat})
        a.page in @settings_detail_pages -> inspect({:page, :settings})
        a.page != :chat -> inspect({:page, :chat})
        (a.conversation_stack || []) != [] -> inspect(:close_subagent_conversation)
        true -> nil
      end

    notice = Map.get(a, :notice)

    page(
      [
        header(a),
        notice(if(a.stopping, do: gettext("Stopping…"), else: notice)),
        content(a),
        if(a.page != :history, do: HandbeanProbe.NativeModelInputs.render(a.input_warning)),
        if(a.page == :chat && a.chat && a.chat.pending_approval && a.approval_open,
          do:
            NativeApproval.render(
              a.chat,
              Notice.error_text(notice),
              Map.get(a, :approval_snapshots, %{})
            )
        )
      ],
      back_target: back_target
    )
  end

  defp header(%{page: :chat, conversation_stack: [_ | _]} = a) do
    row([
      icon("back", :close_subagent_conversation),
      text(chat_title(a), text_size: 13, font_weight: "bold", weight: 1),
      text(gettext("Child conversation"), text_size: 10, text_color: color(:hint))
    ])
  end

  defp header(%{page: :chat} = a) do
    row([
      icon("menu", {:page, :history}),
      text(gettext("Handbean"), text_size: 13, font_weight: "bold", padding_right: 8),
      text(chat_title(a), text_size: 11, weight: 1)
    ])
  end

  defp header(%{page: :files} = a) do
    row(
      [
        icon("back", {:page, :chat}),
        HandbeanProbe.NativeChanges.render_tabs(a)
      ],
      weights: [0, 1]
    )
  end

  defp header(%{page: page}) when page in @settings_detail_pages do
    row([
      icon("back", {:page, :settings}),
      text(page_title(page), text_size: 14, weight: 1)
    ])
  end

  defp header(a) do
    row([
      icon("back", {:page, :chat}),
      text(page_title(a.page), text_size: 14, weight: 1)
    ])
  end

  defp content(%{page: :chat} = a) do
    entries = if a.chat, do: a.chat.entries, else: []
    stream = if a.chat, do: a.chat.stream, else: ""
    running = a.chat != nil and a.chat.running

    node(:column, [weight: 1, fill_width: true], [
      Share.render_review(Map.get(a, :share_intakes, []), a),
      NativeTimeline.render_sent_card(a.chat, Map.get(a, :timeline_open)),
      if(a.chat && a.chat.pending_approval,
        do:
          button(gettext("Waiting for tool approval · Review"), :review_approval,
            fill_width: true
          )
      ),
      if(entries == [] and stream == "" and not running,
        do: empty_chat(),
        else:
          NativeTimeline.render(
            a.chat
            |> Map.put(:expanded_handoffs, a.expanded_handoffs || MapSet.new())
            |> Map.put(:current_conversation_id, Map.get(a.chat.conversation, "id")),
            a.work_groups,
            a.work_segments,
            a.tool_outputs,
            Map.get(a, :file_diffs, %{})
          )
          |> scroll(
            [
              id: "chat-timeline-#{a.chat.conversation["id"]}",
              chat_navigation: true,
              stick_to_bottom: true,
              history_before: Map.get(a.chat, :history_before)
            ] ++
              if(Map.get(a.chat, :history_has_more?, false),
                do: [on_top_reached: {self(), :load_older_history}],
                else: []
              )
          )
      ),
      composer_controls(a),
      NativeComposer.render_field(a, running)
    ])
  end

  defp content(%{page: :history} = a) do
    selected_id =
      case a.chat do
        %{conversation: %{"id" => id}} -> id
        _ -> nil
      end

    history_list =
      scroll(
        HandbeanProbe.NativeHistory.render(a.history, %{
          selected_id: selected_id,
          collapsed: Map.get(a, :collapsed_history_groups, MapSet.new()),
          activities: Map.get(a, :conversation_activity, %{}),
          bean_frame: Map.get(a, :bean_frame, 0),
          menu_id: Map.get(a, :conversation_menu_id),
          rename: Map.get(a, :rename_conversation)
        })
      )

    # The drawer footer is pinned below the scroll area, so the app entries
    # stay reachable no matter how long the conversation list grows.
    node(:column, [weight: 1, fill_width: true], [history_list] ++ history_drawer_footer(a))
  end

  defp content(%{page: :files} = a),
    do: HandbeanProbe.NativeChanges.render_content(a)

  defp content(%{page: :schedules} = a),
    do: NativeSchedules.render(a.schedules || NativeSchedules.new())

  defp content(%{page: :permissions} = a),
    do: scroll(NativeApproval.render_modes(a.permission_mode))

  defp content(%{page: :settings} = a) do
    node(:column, [weight: 1, fill_width: true], [
      SettingsHub.render(a)
    ])
  end

  defp content(%{page: page} = a)
       when page in [
              :models,
              :model_ai,
              :workspace_models,
              :memory,
              :workspace,
              :mcp,
              :git,
              :appearance,
              :app
            ] do
    node(:column, [weight: 1, fill_width: true], [
      settings_body(a),
      if(page == :models,
        do: ModelSettings.subscription_sheet(a.models, Map.get(a, :notice))
      ),
      if(page == :models, do: ModelSettings.confirm_sheet(a.models))
    ])
  end

  defp content(_a),
    do:
      scroll([
        text(gettext("Not implemented yet"), text_size: 16, padding_top: 32),
        text(gettext("This native experiment only opens chat, workspaces, and model settings."),
          padding_top: 12
        ),
        button(gettext("Back to chat"), {:page, :chat})
      ])

  # Drawer footer: app entries live here, not in the chat header.
  defp history_drawer_footer(a) do
    [
      node(:box, fill_width: true, height: 1, background: color(:separator), margin_top: 8),
      if(not Nav.free_chat?(a),
        do: drawer_footer_row("folder", gettext("Files"), {:page, :files}, "history-files")
      ),
      drawer_footer_row(
        "history",
        gettext("Scheduled tasks"),
        {:page, :schedules},
        "history-tasks"
      ),
      drawer_footer_row("settings", gettext("Settings"), {:page, :settings}, "history-settings"),
      drawer_footer_row("info", gettext("About"), {:page, :about}, "history-about")
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp drawer_footer_row(icon_name, label, tag, id) do
    row(
      [
        node(:icon,
          name: icon_name,
          text: "",
          text_size: 18,
          padding: 6,
          text_color: color(:muted)
        ),
        text(label, text_size: 13, text_color: color(:ink))
      ],
      id: id,
      on_tap: {self(), tag},
      padding_top: 8,
      padding_bottom: 12,
      padding_left: 4,
      background: color(:surface)
    )
  end

  defp empty_chat do
    node(:box, [weight: 1, align: "center"], [
      node(:column, [fill_width: true], [
        text(gettext("Start a new conversation"),
          text_size: 16,
          fill_width: true,
          text_align: "center"
        ),
        text(gettext("Send a message and work with AI"),
          text_size: 13,
          text_color: color(:hint),
          padding_top: 8,
          fill_width: true,
          text_align: "center"
        )
      ])
    ])
  end

  defp settings_body(%{page: :models} = a),
    do:
      scroll(ModelSettings.render_available_models(a.models),
        id: "models-#{inspect(a.models.editing)}"
      )

  defp settings_body(%{page: :model_ai} = a),
    do:
      scroll(ModelSettings.render_model_ai(a.models || ModelSettings.empty()),
        id: "settings-model-ai"
      )

  defp settings_body(%{page: :workspace_models} = a),
    do:
      scroll(ModelSettings.render_workspace_models(a.models || ModelSettings.empty()),
        id: "settings-workspace-models"
      )

  defp settings_body(%{page: :workspace} = a),
    do: NativeWorkspaces.render(a.workspaces, a.workspace)

  defp settings_body(%{page: :memory} = a),
    do: WorkspaceMemory.render(a.workspace_memory, a.workspace)

  defp settings_body(%{page: :mcp} = a),
    do: MCPSettings.render(a.mcp, a.workspaces.items)

  defp settings_body(%{page: :git} = a),
    do: GitSettings.render(a.git)

  defp settings_body(%{page: :app} = a) do
    HandbeanProbe.AppSettings.render(a.app_settings || HandbeanProbe.AppSettings.new())
  end

  defp settings_body(%{page: :appearance}),
    do: HandbeanProbe.HomeScreen.UiSettings.render()

  defp chat_title(a) do
    if Nav.free_chat?(a),
      do: gettext("自由对话"),
      else: (a.workspace && a.workspace["name"]) || gettext("Workspace")
  end

  defp page_title(:history), do: gettext("Conversations")
  defp page_title(:schedules), do: gettext("Scheduled tasks")
  defp page_title(:about), do: gettext("About")
  defp page_title(:models), do: gettext("Available Models")
  defp page_title(:model_ai), do: gettext("Model / AI")
  defp page_title(:workspace_models), do: gettext("Workspace Models")
  defp page_title(:memory), do: gettext("Workspace Memory")
  defp page_title(:workspace), do: gettext("Workspaces")
  defp page_title(:mcp), do: gettext("MCP")
  defp page_title(:git), do: gettext("Git")
  defp page_title(:app), do: gettext("App")
  defp page_title(:appearance), do: gettext("UI")
  defp page_title(_), do: gettext("Settings")

  defp composer_controls(a) do
    model_opts =
      Enum.map(a.models.allowed_models, fn model ->
        select_option(
          model.name,
          {:composer_setting, :default_model, model.id},
          model.id == a.models.default,
          composer_option_chrome()
        )
      end)

    reasoning_opts =
      Enum.map(Handbean.Agent.Reasoning.levels(), fn level ->
        select_option(
          level,
          {:composer_setting, :reasoning, level},
          level == a.models.reasoning,
          composer_option_chrome()
        )
      end)

    permission_opts =
      Enum.map([:prompt, :auto_review, :yolo], fn mode ->
        select_option(
          NativeApproval.mode_label(mode),
          {:permission_mode, mode},
          mode == a.permission_mode,
          composer_option_chrome()
        )
      end)

    chips = [
      composer_select(a, :model, model_name(a.models), model_opts, "composer-model"),
      composer_select(a, :reasoning, a.models.reasoning, reasoning_opts, "composer-reasoning"),
      composer_select(
        a,
        :permission,
        NativeApproval.mode_label(a.permission_mode),
        permission_opts,
        "composer-permission"
      )
    ]

    if HandbeanProbe.NativePlatform.ios?() do
      node(:column, [fill_width: true], [
        composer_open_menu(a, model_opts, reasoning_opts, permission_opts),
        row(spaced(chips), align: "center", padding_bottom: 6)
      ])
    else
      [model, reasoning, permission] = chips

      row(
        [model, gap(6), reasoning, node(:box, weight: 1), permission],
        padding_bottom: 4
      )
    end
  end

  # Compact menuitem chrome for the composer overlay. Settings keep the
  # NativeUI defaults. Padding 10 × six reasoning levels stacked inside a
  # chip column is what shoved the menu into the input field.
  defp composer_option_chrome do
    if HandbeanProbe.NativePlatform.ios?() do
      [padding: 6, text_size: 12]
    else
      []
    end
  end

  defp composer_open_menu(a, model_opts, reasoning_opts, permission_opts) do
    options =
      case a.composer_select do
        :model -> model_opts
        :reasoning -> reasoning_opts
        :permission -> permission_opts
        _ -> nil
      end

    if options do
      node(
        :column,
        [
          fill_width: true,
          background: color(:card),
          border_color: color(:ink),
          border_width: 1,
          corner_radius: 8,
          padding: 4
        ],
        options
      )
    end
  end

  defp composer_select(a, which, value, options, id) do
    select(value, options,
      id: id,
      compact: true,
      fill_width: false,
      text_size: 11,
      icon_content_description: gettext("Open menu"),
      # iOS chips stay collapsed; the open menu is a sibling above the row.
      open: not HandbeanProbe.NativePlatform.ios?() and a.composer_select == which,
      on_toggle: {:composer_select, which}
    )
  end

  defp model_name(models) do
    if is_binary(models.chat_blocked) do
      models.chat_blocked
    else
      case Enum.find(models.allowed_models, &(&1.id == models.default)) ||
             Enum.find(models.models, &(&1.id == models.default)) do
        nil -> gettext("Select a model")
        model -> model.name
      end
    end
  end
end
