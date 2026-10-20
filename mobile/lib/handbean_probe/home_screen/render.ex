defmodule HandbeanProbe.HomeScreen.Render do
  @moduledoc """
  Pure projection of `HandbeanProbe.HomeScreen.State` into Mob nodes. No IO: sent
  image paths are precomputed on the chat entries, and every collaborator
  render function is a pure function of the assigns it receives.
  """

  use Gettext, backend: HandbeanProbe.Gettext
  import HandbeanProbe.NativeUI

  alias HandbeanProbe.HomeScreen.{Nav, Notice, Share}

  alias HandbeanProbe.{
    ModelSettings,
    MCPSettings,
    GitSettings,
    NativeApproval,
    NativeComposer,
    NativeTimeline,
    NativeWorkspaceOpen,
    NativeWorkspaces,
    WorkspaceMemory
  }

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
      button(
        chat_title(a),
        {:page, :workspace},
        text_size: 11,
        weight: 1,
        background: color(:surface)
      ),
      if(not Nav.free_chat?(a),
        do: button(gettext("Files"), {:page, :files}, text_size: 11, background: color(:surface))
      ),
      icon("info", {:page, :about}),
      icon("settings", {:page, :settings})
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

  defp content(%{page: :attachments} = a),
    do:
      scroll(
        NativeComposer.render_entries(a) ++ [button(gettext("Back to chat"), {:page, :chat})]
      )

  defp content(%{page: :history} = a) do
    selected_id =
      case a.chat do
        %{conversation: %{"id" => id}} -> id
        _ -> nil
      end

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
  end

  defp content(%{page: :files} = a),
    do: HandbeanProbe.NativeChanges.render_content(a)

  defp content(%{page: :permissions} = a),
    do: scroll(NativeApproval.render_modes(a.permission_mode))

  defp content(%{page: :settings} = a), do: content(%{a | page: :models})

  defp content(%{page: page} = a)
       when page in [:models, :memory, :workspace, :mcp, :git, :appearance, :app] do
    node(:column, [weight: 1, fill_width: true], [
      settings_tabs(page),
      settings_body(a),
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

  defp settings_tabs(page) do
    node(:column, [fill_width: true, padding_bottom: 8], [
      segment_row([
        tab_button(gettext("Model / AI"), {:page, :models}, page == :models),
        tab_button(gettext("Memory"), {:page, :memory}, page == :memory),
        tab_button(gettext("Workspaces"), {:page, :workspace}, page == :workspace),
        tab_button(gettext("MCP"), {:page, :mcp}, page == :mcp)
      ]),
      segment_row(
        [
          tab_button(gettext("Git"), {:page, :git}, page == :git),
          tab_button(gettext("App"), {:page, :app}, page == :app),
          appearance_tab(page)
        ],
        padding_top: 8
      )
    ])
  end

  # Appearance is not built yet. Keep it the same size as the other tabs,
  # and only quiet the label, so it does not stretch into a section bar.
  defp appearance_tab(page) do
    selected? = page == :appearance

    tab_button(gettext("UI"), {:page, :appearance}, selected?,
      text_color: if(selected?, do: color(:card), else: color(:hint))
    )
  end

  defp settings_body(%{page: :models} = a),
    do: scroll(ModelSettings.render(a.models), id: "models-#{inspect(a.models.editing)}")

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

  defp settings_body(%{page: :appearance}) do
    scroll([
      card([
        text(gettext("Appearance is not available yet"), text_size: 16),
        text(
          gettext(
            "Theme and display options are not part of this native experiment. Chat, workspaces, and model settings are available."
          ),
          text_size: 13,
          text_color: color(:muted),
          padding_top: 8
        )
      ])
    ])
  end

  defp chat_title(a) do
    if Nav.free_chat?(a),
      do: gettext("Chats"),
      else: (a.workspace && a.workspace["name"]) || gettext("Workspace")
  end

  defp page_title(:history), do: gettext("Conversations")
  defp page_title(:attachments), do: gettext("Attachments")
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
