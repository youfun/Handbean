defmodule HandbeanProbe.AppSettings do
  @moduledoc """
  Client-only settings that do not belong in the shared model/workspace config.

  The page shows device permission state. Calendar status is read from the
  host; requesting access and opening system app settings go through
  `HandbeanProbe.Platform`, not an Agent tool.
  """

  use Gettext, backend: HandbeanProbe.Gettext

  alias HandbeanProbe.NativeUI
  alias HandbeanProbe.Platform

  defstruct calendar_read: :unknown,
            calendar_write: :unknown,
            busy: false,
            notice: nil

  @type grant :: boolean() | :unknown

  @type t :: %__MODULE__{
          calendar_read: grant(),
          calendar_write: grant(),
          busy: boolean(),
          notice: String.t() | nil
        }

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec status_request(pid(), String.t(), integer()) ::
          {:ok, Platform.Request.t()} | {:error, term()}
  def status_request(caller, request_id, generation),
    do: Platform.app_settings_request(caller, request_id, generation, "calendar_status")

  @spec request_calendar(pid(), String.t(), integer()) ::
          {:ok, Platform.Request.t()} | {:error, term()}
  def request_calendar(caller, request_id, generation),
    do: Platform.app_settings_request(caller, request_id, generation, "request_calendar")

  @spec open_system_settings(pid(), String.t(), integer()) ::
          {:ok, Platform.Request.t()} | {:error, term()}
  def open_system_settings(caller, request_id, generation),
    do: Platform.app_settings_request(caller, request_id, generation, "open_app_settings")

  @spec apply_result(t(), map()) :: t()
  def apply_result(%__MODULE__{} = state, result) when is_map(result) do
    %{
      state
      | calendar_read: grant(field(result, "calendar_read"), state.calendar_read),
        calendar_write: grant(field(result, "calendar_write"), state.calendar_write),
        busy: false,
        notice: notice(field(result, "outcome"))
    }
  end

  @spec render(t()) :: Mob.Node.t()
  def render(%__MODULE__{} = state) do
    NativeUI.scroll([
      NativeUI.card([
        NativeUI.text(gettext("Client"), text_size: 16),
        NativeUI.text(
          gettext("Settings that belong to this app, not a workspace or model."),
          text_size: 13,
          text_color: NativeUI.color(:muted),
          padding_top: 8
        )
      ]),
      NativeUI.card([
        NativeUI.text(gettext("Calendar"), text_size: 16),
        NativeUI.text(calendar_copy(state),
          text_size: 13,
          text_color: NativeUI.color(:muted),
          padding_top: 8
        ),
        NativeUI.text(calendar_grants(state), text_size: 14, padding_top: 12),
        NativeUI.actions_row([
          NativeUI.secondary_button(gettext("Allow calendar"), :request_calendar),
          NativeUI.quiet_button(gettext("System settings"), :open_app_settings)
        ]),
        notice_node(state.notice)
      ]),
      NativeUI.card([
        NativeUI.text(gettext("Alarm"), text_size: 16),
        NativeUI.text(
          gettext(
            "Clock alarms open the system clock with the time filled in. They do not need a permission, and many devices still ask you to save."
          ),
          text_size: 13,
          text_color: NativeUI.color(:muted),
          padding_top: 8
        )
      ])
    ])
  end

  defp calendar_copy(%__MODULE__{calendar_read: true, calendar_write: true}) do
    gettext(
      "Handbean can read and add events in the system calendar without opening the calendar app."
    )
  end

  defp calendar_copy(%__MODULE__{calendar_read: :unknown, calendar_write: :unknown}) do
    gettext("Calendar access has not been checked yet.")
  end

  defp calendar_copy(_) do
    gettext("Calendar access is off. Allow it here, or turn it on in system settings.")
  end

  defp calendar_grants(%__MODULE__{calendar_read: true, calendar_write: true}) do
    gettext("Read and write allowed")
  end

  defp calendar_grants(%__MODULE__{calendar_read: :unknown, calendar_write: :unknown}) do
    gettext("Not checked")
  end

  defp calendar_grants(%__MODULE__{calendar_read: false, calendar_write: false}) do
    gettext("Not allowed")
  end

  defp calendar_grants(%__MODULE__{calendar_read: true}) do
    gettext("Read allowed")
  end

  defp calendar_grants(%__MODULE__{calendar_write: true}) do
    gettext("Write allowed")
  end

  defp notice(nil), do: nil
  defp notice("granted"), do: gettext("Calendar access granted.")
  defp notice("permission_denied"), do: gettext("Calendar access was not granted.")
  defp notice("ui_presented"), do: gettext("Opened system settings.")
  defp notice("needs_foreground"), do: gettext("Bring Handbean to the front and try again.")
  defp notice("listed"), do: nil
  defp notice(_), do: gettext("Could not read calendar access.")

  defp notice_node(nil), do: nil

  defp notice_node(text) do
    NativeUI.text(text, text_size: 13, text_color: NativeUI.color(:muted), padding_top: 8)
  end

  defp grant(value, _current) when is_boolean(value), do: value
  defp grant(_, current), do: current

  defp field(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, atom_key(key))
  end

  defp field(_, _), do: nil

  defp atom_key(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
