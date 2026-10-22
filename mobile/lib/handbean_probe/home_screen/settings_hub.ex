defmodule HandbeanProbe.HomeScreen.SettingsHub do
  @moduledoc """
  Settings home projection.

  Index rows only. Model / AI and workspace model policy open the matching
  Web panels. Current workspace is a switcher, not a second menu.
  """

  use Gettext, backend: HandbeanProbe.Gettext
  import HandbeanProbe.NativeUI

  alias HandbeanProbe.ModelSettings
  alias HandbeanProbe.ModelSettings.Labels

  @row_pad [padding_top: 10, padding_bottom: 10]

  def render(a) do
    models = a.models || ModelSettings.empty()

    scroll(
      [
        hub_group(gettext("Workspace"), workspace_rows(a)),
        hub_group(gettext("Model"), ai_rows(a, models)),
        hub_group(gettext("Device"), more_rows(a))
      ],
      id: "settings-hub"
    )
  end

  defp hub_group(title, rows) do
    node(:column, [fill_width: true], [
      settings_section(title, padding_top: 0, padding_bottom: 6),
      settings_group(rows, padding_bottom: 16)
    ])
  end

  defp hub_nav(name, value, tag), do: settings_nav_row(name, value, tag, @row_pad)

  defp hub_check(name, checked?, tag),
    do: settings_check_row(name, checked?, tag, @row_pad)

  defp hub_value(name, value), do: settings_value_row(name, value, @row_pad)

  defp workspace_rows(a) do
    current = (a.workspace && a.workspace["name"]) || gettext("Workspace")
    current_id = a.workspace && a.workspace["id"]
    items = (a.workspaces && a.workspaces.items) || []

    switchers =
      if items == [] do
        [hub_value(gettext("Workspace"), current)]
      else
        Enum.map(items, fn item ->
          hub_check(item.name, item.id == current_id, {:workspace, item.id})
        end)
      end

    switchers ++ [hub_nav(gettext("Add workspace"), "", {:page, :workspace})]
  end

  defp ai_rows(a, models) do
    [
      hub_nav(gettext("Model / AI"), model_ai_value(models), {:page, :model_ai}),
      hub_nav(
        gettext("Workspace Models"),
        workspace_models_value(models),
        {:page, :workspace_models}
      ),
      hub_nav(
        gettext("Workspace Memory"),
        memory_value(a.workspace_memory),
        {:page, :memory}
      ),
      hub_nav(
        gettext("Available Models"),
        providers_value(models),
        {:page, :models}
      )
    ]
  end

  defp more_rows(a) do
    [
      hub_nav(gettext("MCP"), mcp_value(a.mcp), {:page, :mcp}),
      hub_nav(gettext("Git"), git_value(a.git), {:page, :git}),
      hub_nav(gettext("App"), app_value(a.app_settings), {:page, :app}),
      hub_nav(
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
