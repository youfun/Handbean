defmodule HandbeanProbe.HomeScreen.SettingsHub do
  @moduledoc """
  Settings home projection.

  Index rows only. Model / AI and workspace model policy open the matching
  Web panels. Current workspace is a switcher, not a second menu.
  """

  use Gettext, backend: HandbeanProbe.Gettext
  import HandbeanProbe.NativeUI

  alias HandbeanProbe.ModelSettings
  alias HandbeanProbe.ModelSettings.{Labels, Render}

  def render(a) do
    models = a.models || ModelSettings.empty()

    scroll(
      [
        settings_group(workspace_rows(a)),
        settings_group(ai_rows(a, models)),
        settings_group(more_rows(a))
      ],
      id: "settings-hub"
    )
  end

  defp workspace_rows(a) do
    current = (a.workspace && a.workspace["name"]) || gettext("Workspace")
    current_id = a.workspace && a.workspace["id"]
    items = (a.workspaces && a.workspaces.items) || []

    options =
      Enum.map(items, fn item ->
        select_option(item.name, {:workspace, item.id}, item.id == current_id)
      end)

    switcher =
      if options == [] do
        settings_value_row(gettext("Workspace"), current)
      else
        settings_control_row(
          gettext("Workspace"),
          Render.settings_select(current, options, "select-workspace", fill_width: false)
        )
      end

    [
      switcher,
      settings_nav_row(gettext("Add workspace"), "", {:page, :workspace})
    ]
  end

  defp ai_rows(a, models) do
    [
      settings_nav_row(gettext("Model / AI"), model_ai_value(models), {:page, :model_ai}),
      settings_nav_row(
        gettext("Workspace Models"),
        workspace_models_value(models),
        {:page, :workspace_models}
      ),
      settings_nav_row(
        gettext("Workspace Memory"),
        memory_value(a.workspace_memory),
        {:page, :memory}
      ),
      settings_nav_row(
        gettext("Available Models"),
        providers_value(models),
        {:page, :models}
      )
    ]
  end

  defp more_rows(a) do
    [
      settings_nav_row(gettext("MCP"), mcp_value(a.mcp), {:page, :mcp}),
      settings_nav_row(gettext("Git"), git_value(a.git), {:page, :git}),
      settings_nav_row(gettext("App"), app_value(a.app_settings), {:page, :app}),
      settings_nav_row(
        gettext("UI"),
        HandbeanProbe.HomeScreen.UiSettings.language_label(HandbeanProbe.Gettext.locale()),
        {:page, :appearance}
      )
    ]
  end

  defp model_ai_value(%{defaults: %{default_model: id}} = models)
       when is_binary(id) and id != "" do
    Labels.default_model(id, models)
  end

  defp model_ai_value(_), do: gettext("View")

  defp workspace_models_value(%{policy: %{mode: :restricted}}),
    do: gettext("Only checked models")

  defp workspace_models_value(%{policy: %{mode: :invalid}}), do: gettext("Invalid")
  defp workspace_models_value(_), do: gettext("Unrestricted")

  defp providers_value(%{providers: providers}) when is_list(providers) do
    gettext("%{count} providers", count: length(providers))
  end

  defp providers_value(_), do: gettext("View")

  defp memory_value(%{loading?: true}), do: gettext("Loading…")

  defp memory_value(%{builtin_memory_enabled: enabled?, summary: %{active: count}})
       when is_integer(count) do
    state = if enabled?, do: gettext("On"), else: gettext("Off")
    gettext("%{state} · %{count} active", state: state, count: count)
  end

  defp memory_value(_), do: gettext("View")

  defp mcp_value(%{loading?: true}), do: gettext("Loading…")

  defp mcp_value(%{items: items}) when is_list(items) do
    gettext("%{count} servers", count: length(items))
  end

  defp mcp_value(_), do: gettext("View")

  defp git_value(%{loading?: true}), do: gettext("Loading…")

  defp git_value(%{identity: identity}) when is_map(identity) do
    name = identity["name"] || identity[:name] || ""

    if String.trim(to_string(name)) == "" do
      gettext("Not set")
    else
      name
    end
  end

  defp git_value(_), do: gettext("View")

  defp app_value(%{calendar_read: true, calendar_write: true}), do: gettext("Calendar allowed")
  defp app_value(%{calendar_read: :unknown, calendar_write: :unknown}), do: gettext("Not checked")
  defp app_value(%{calendar_read: false, calendar_write: false}), do: gettext("Calendar off")
  defp app_value(_), do: gettext("View")
end
