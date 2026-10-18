defmodule HandbeanProbe.MCPSettings do
  @moduledoc "Native state and rendering for HTTP MCP server settings."

  use Gettext, backend: HandbeanProbe.Gettext
  import HandbeanProbe.NativeUI

  def empty do
    %{
      items: [],
      form: nil,
      original: nil,
      loading?: false,
      busy?: false,
      testing?: false,
      error: nil,
      test_result: nil,
      confirm: nil
    }
  end

  def loaded(state, {:ok, items}), do: %{state | items: items, loading?: false, error: nil}
  def loaded(state, {:error, reason}), do: %{state | loading?: false, error: to_string(reason)}

  def open_new(state, workspace_id) do
    form = Handbean.MCP.Settings.new_form(workspace_id)
    %{state | form: form, original: form, error: nil, test_result: nil, confirm: nil}
  end

  def open_edit(state, {:ok, form}),
    do: %{state | form: form, original: form, error: nil, test_result: nil, confirm: nil}

  def open_edit(state, {:error, reason}), do: %{state | error: to_string(reason)}

  def change(%{form: form} = state, field, value) when is_map(form) do
    %{state | form: Map.put(form, Atom.to_string(field), value), error: nil, test_result: nil}
  end

  def toggle_workspace(%{form: form} = state, id) do
    ids = Map.get(form, "workspace_ids", [])
    ids = if id in ids, do: List.delete(ids, id), else: ids ++ [id]
    %{state | form: Map.put(form, "workspace_ids", ids), error: nil}
  end

  def toggle_disabled(%{form: form} = state),
    do: %{state | form: Map.update(form, "disabled", true, &(not &1))}

  def dirty?(%{form: nil}), do: false
  def dirty?(state), do: state.form != state.original

  def saved(state, {:ok, _id}),
    do: %{state | form: nil, original: nil, error: nil, test_result: nil}

  def saved(state, {:error, reason}), do: %{state | error: to_string(reason)}

  def tested(state, {:ok, %{tool_count: count}}),
    do: %{
      state
      | testing?: false,
        test_result: gettext("Connected · %{count} tools", count: count),
        error: nil
    }

  def tested(state, {:error, reason}),
    do: %{state | testing?: false, test_result: nil, error: to_string(reason)}

  def render(state, workspaces) do
    children =
      cond do
        state.loading? -> [text(gettext("Loading MCP servers…"), padding_top: 24)]
        state.form -> [editor(state, workspaces)]
        true -> list(state)
      end

    scroll(children ++ [confirm_sheet(state)], id: "mcp-settings")
  end

  defp list(state) do
    heading =
      row([
        text(gettext("MCP servers"), text_size: 16, font_weight: "bold", weight: 1),
        primary_button(gettext("Add"), :mcp_add)
      ])

    items =
      if state.items == [] do
        [
          card([
            text(gettext("No MCP servers configured")),
            text(gettext("Add an HTTP server to make its tools available."),
              text_color: color(:muted),
              padding_top: 6
            )
          ])
        ]
      else
        Enum.map(state.items, &server_card/1)
      end

    [heading, error_text(state.error) | items]
  end

  defp server_card(entry) do
    subtitle =
      case entry.transport do
        :stdio ->
          gettext("stdio · Read-only on mobile")

        :http ->
          gettext("HTTP · %{status} · %{count} tools",
            status: status_label(entry.status),
            count: entry.tool_count
          )
      end

    card([
      row([
        text(entry.name, weight: 1, font_weight: "bold"),
        text(if(entry.disabled, do: gettext("Disabled"), else: ""), text_color: color(:muted))
      ]),
      text(subtitle, text_size: 12, text_color: color(:muted), padding_top: 4),
      text(access_label(entry.workspace_access),
        text_size: 12,
        text_color: color(:muted),
        padding_top: 4
      ),
      if(entry.transport == :http,
        do: actions_row([secondary_button(gettext("Edit"), {:mcp_edit, entry.id})])
      )
    ])
  end

  defp editor(state, workspaces) do
    form = state.form
    editing? = is_binary(form["id"])
    auth = form["auth"]

    [
      actions_row([
        primary_button(gettext("Save"), :mcp_save),
        secondary_button(gettext("Cancel"), :mcp_cancel)
      ]),
      text(if(editing?, do: gettext("Edit MCP server"), else: gettext("Add MCP server")),
        text_size: 16,
        font_weight: "bold"
      ),
      error_text(state.error),
      field(gettext("Name"), form["name"], {:mcp_field, :name}),
      field(gettext("URL"), form["url"], {:mcp_field, :url},
        placeholder: "https://example.com/mcp"
      ),
      text(gettext("Authentication"),
        text_size: 13,
        text_color: color(:muted),
        padding_bottom: 6
      ),
      segment_row(
        Enum.map(
          [
            {"none", gettext("None")},
            {"bearer", gettext("Bearer")},
            {"headers", gettext("Custom headers")}
          ],
          fn {value, label} -> segment_button(label, {:mcp_auth, value}, auth == value) end
        )
      ),
      credential_fields(form, auth),
      text(gettext("Workspace access"),
        text_size: 13,
        text_color: color(:muted),
        padding_top: 8,
        padding_bottom: 6
      ),
      segment_row([
        segment_button(
          gettext("Selected"),
          {:mcp_access, "selected"},
          form["access_mode"] == "selected"
        ),
        segment_button(
          gettext("All (including future)"),
          {:mcp_access, "all"},
          form["access_mode"] == "all"
        )
      ]),
      if(form["access_mode"] == "selected", do: workspace_checks(form, workspaces)),
      option_button(gettext("Disabled"), :mcp_toggle_disabled, form["disabled"] == true),
      if(state.test_result,
        do: text(state.test_result, text_color: color(:added), padding_top: 8)
      ),
      actions_row([
        secondary_button(
          if(state.testing?, do: gettext("Testing…"), else: gettext("Test connection")),
          :mcp_test
        ),
        primary_button(gettext("Save"), :mcp_save),
        quiet_button(gettext("Cancel"), :mcp_cancel)
      ]),
      if(editing?, do: actions_row([danger_button(gettext("Delete"), :mcp_ask_delete)]))
    ]
    |> List.flatten()
    |> card()
  end

  defp credential_fields(form, "bearer") do
    [
      field(gettext("Bearer token"), form["token"], {:mcp_field, :token},
        secure: true,
        placeholder: credential_hint(form)
      )
    ]
  end

  defp credential_fields(form, "headers") do
    [
      field(gettext("Custom headers (JSON)"), form["headers_json"], {:mcp_field, :headers_json},
        secure: true,
        placeholder: credential_hint(form)
      )
    ]
  end

  defp credential_fields(_form, _), do: []

  defp credential_hint(%{"has_credentials" => true}),
    do: gettext("Leave blank to keep existing credentials")

  defp credential_hint(_), do: ""

  defp workspace_checks(form, workspaces) do
    Enum.map(workspaces, fn workspace ->
      option_button(
        workspace.name,
        {:mcp_workspace, workspace.id},
        workspace.id in form["workspace_ids"],
        padding_top: 8
      )
    end)
  end

  defp confirm_sheet(%{confirm: nil}), do: nil

  defp confirm_sheet(%{confirm: :delete}) do
    sheet(
      [
        text(gettext("Delete this MCP server?"), text_size: 16),
        actions_row([
          danger_button(gettext("Delete"), :mcp_delete),
          quiet_button(gettext("Keep"), :mcp_dismiss_confirm)
        ])
      ],
      dismiss: :mcp_dismiss_confirm,
      id: "mcp-delete-confirm"
    )
  end

  defp confirm_sheet(%{confirm: :discard}) do
    sheet(
      [
        text(gettext("Discard unsaved changes?"), text_size: 16),
        actions_row([
          danger_button(gettext("Discard"), :mcp_discard),
          quiet_button(gettext("Keep editing"), :mcp_dismiss_confirm)
        ])
      ],
      dismiss: :mcp_dismiss_confirm,
      id: "mcp-discard-confirm"
    )
  end

  defp error_text(nil), do: nil

  defp error_text(error),
    do: text(error, text_color: color(:danger), padding_top: 8, padding_bottom: 8)

  defp status_label(:connected), do: gettext("connected")
  defp status_label(_), do: gettext("not connected")

  defp access_label(%{"mode" => "all"}),
    do: gettext("All workspaces, including future workspaces")

  defp access_label(%{"workspace_ids" => ids}),
    do: gettext("Allowed in %{count} workspaces", count: length(ids))
end
