defmodule HandbeanProbe.Platform do
  @moduledoc """
  Typed import/export lifecycle. JNI sees only request_id, generation, and a small JSON payload.
  """

  alias Handbean.ExportSnapshot
  alias Handbean.Security.PathValidator
  alias HandbeanProbe.Platform.{Nif, Request}

  @spec start(Request.t(), keyword()) :: {:ok, :async} | {:ok, map()} | {:error, term()}
  def start(%Request{} = req, opts \\ []) do
    case Application.get_env(:handbean_probe, :platform_fake) do
      fun when is_function(fun, 2) -> fun.(req, opts)
      _ -> Nif.command(req, opts)
    end
  end

  @spec request(Request.t() | term(), keyword()) ::
          {:ok, :async} | {:ok, map()} | {:error, term()}
  def request(req, opts \\ [])
  def request(%Request{} = req, opts), do: start(req, opts)
  def request(_, _), do: {:error, :invalid_platform_request}

  @spec import_file(pid(), String.t(), integer(), String.t(), map()) ::
          {:ok, :async} | {:error, term()}
  def import_file(caller, request_id, generation, path, extra \\ %{})
      when is_pid(caller) and is_binary(request_id) and is_binary(path) do
    payload =
      extra
      |> stringify_keys()
      |> Map.take(["display_name", "mime", "workspace_id", "conversation_id"])
      |> Map.merge(%{"op" => "platform_import", "path" => path})

    start(Request.new("platform_import", request_id, generation, caller, payload))
  end

  @spec export_request(pid(), String.t(), integer(), String.t(), String.t()) ::
          {:ok, Request.t()} | {:error, term()}
  def export_request(caller, request_id, generation, workspace_path, relative_path)
      when is_pid(caller) and is_binary(workspace_path) and is_binary(relative_path) do
    case ExportSnapshot.authorize(workspace_path, relative_path) do
      {:ok, authorized} ->
        {:ok,
         Request.new("platform_export", request_id, generation, caller, %{
           "op" => "platform_export",
           "workspace_path" => workspace_path,
           "path" => authorized.path,
           "relative_path" => authorized.relative_path,
           "owner_request_id" => request_id
         })}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec export_file(pid(), String.t(), integer(), String.t(), String.t()) ::
          {:ok, :async} | {:error, term()}
  def export_file(caller, request_id, generation, workspace_path, relative_path) do
    case export_request(caller, request_id, generation, workspace_path, relative_path) do
      {:ok, req} -> start(req)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "The `platform_open_url` request. Both the UI tap and the Agent tool build it here."
  @spec open_url_request(pid(), String.t(), integer(), String.t()) :: Request.t()
  def open_url_request(caller, request_id, generation, url)
      when is_pid(caller) and is_binary(url) do
    Request.new("platform_open_url", request_id, generation, caller, %{
      "op" => "platform_open_url",
      "url" => url,
      "deadline_ms" => deadline_ms()
    })
  end

  @spec open_url(pid(), String.t(), integer(), String.t()) :: {:ok, :async} | {:error, term()}
  def open_url(caller, request_id, generation, url),
    do: start(open_url_request(caller, request_id, generation, url))

  @doc """
  Read or write the system calendar. Android inserts through CalendarContract
  after READ/WRITE_CALENDAR. iOS replies unsupported. The Agent tool builds
  the request here.
  """
  @spec device_calendar_request(pid(), String.t(), integer(), map()) ::
          {:ok, Request.t()} | {:error, term()}
  def device_calendar_request(caller, request_id, generation, cmd)
      when is_pid(caller) and is_binary(request_id) and is_map(cmd) do
    action = calendar_action(cmd[:calendar_action])

    if action do
      {:ok,
       Request.new("platform_device_calendar", request_id, generation, caller, %{
         "op" => "platform_device_calendar",
         "action" => action,
         "calendar_id" => text_field(cmd, :calendar_id),
         "query" => text_field(cmd, :query),
         "start_ms" => int_field(cmd, :start_ms),
         "end_ms" => int_field(cmd, :end_ms),
         "limit" => int_field(cmd, :limit) || 20,
         "title" => text_field(cmd, :title),
         "description" => text_field(cmd, :description),
         "location" => text_field(cmd, :location),
         "all_day" => cmd[:all_day] == true,
         "deadline_ms" => deadline_ms()
       })}
    else
      {:error, :invalid_action}
    end
  end

  @doc """
  Client-only settings status. `calendar_status` reads the current grant.
  `request_calendar` shows the system dialog. `open_app_settings` opens the
  app's system settings page. None of these are Agent tools.
  """
  @spec app_settings_request(pid(), String.t(), integer(), String.t()) ::
          {:ok, Request.t()} | {:error, term()}
  def app_settings_request(caller, request_id, generation, action)
      when is_pid(caller) and is_binary(request_id) and
             action in ["calendar_status", "request_calendar", "open_app_settings"] do
    {:ok,
     Request.new("platform_app_settings", request_id, generation, caller, %{
       "op" => "platform_app_settings",
       "settings_action" => action,
       "deadline_ms" => deadline_ms()
     })}
  end

  def app_settings_request(_, _, _, _), do: {:error, :invalid_action}

  @doc """
  Prefill the system clock. This is `AlarmClock.ACTION_SET_ALARM`, not a silent
  alarm write.
  """
  @spec device_alarm_request(pid(), String.t(), integer(), map()) ::
          {:ok, Request.t()} | {:error, term()}
  def device_alarm_request(caller, request_id, generation, cmd)
      when is_pid(caller) and is_binary(request_id) and is_map(cmd) do
    hour = int_field(cmd, :hour)
    minute = int_field(cmd, :minute)

    if is_integer(hour) and hour in 0..23 and is_integer(minute) and minute in 0..59 do
      {:ok,
       Request.new("platform_device_alarm", request_id, generation, caller, %{
         "op" => "platform_device_alarm",
         "hour" => hour,
         "minute" => minute,
         "message" => text_field(cmd, :message),
         "skip_ui" => cmd[:skip_ui] == true,
         "vibrate" => bool_field(cmd, :vibrate),
         "days" => day_field(cmd),
         "deadline_ms" => deadline_ms()
       })}
    else
      {:error, :invalid_time}
    end
  end

  @doc "User-tapped text share. Wraps host `MobBridge.shareText`; not an Agent tool."
  @spec share_text_request(pid(), String.t(), integer(), String.t()) ::
          {:ok, Request.t()} | {:error, term()}
  def share_text_request(caller, request_id, generation, text)
      when is_pid(caller) and is_binary(request_id) do
    case HandbeanProbe.WritingPhotoReviews.shareable_text(text) do
      {:ok, body} ->
        {:ok,
         Request.new("platform_share_text", request_id, generation, caller, %{
           "op" => "platform_share_text",
           "text" => body,
           "deadline_ms" => deadline_ms()
         })}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec share_text(pid(), String.t(), integer(), String.t()) :: {:ok, :async} | {:error, term()}
  def share_text(caller, request_id, generation, text) do
    case share_text_request(caller, request_id, generation, text) do
      {:ok, req} -> start(req)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The present step of the artifact sequence (`export` → snapshot → present):
  `platform_open_snapshot` or `platform_share_snapshot` for a pinned snapshot.
  Both the UI tap and the Agent tool build it here.
  """
  @spec present_request(
          :open_file | :share_file,
          pid(),
          String.t(),
          integer(),
          String.t(),
          String.t()
        ) :: {:ok, Request.t()} | {:error, :file_unavailable}
  def present_request(action, caller, request_id, generation, snapshot_id, owner_request_id)
      when action in [:open_file, :share_file] and is_pid(caller) do
    if is_binary(snapshot_id) and snapshot_id != "" and is_binary(owner_request_id) and
         owner_request_id != "" do
      op = if action == :share_file, do: "platform_share_snapshot", else: "platform_open_snapshot"

      {:ok,
       Request.new(op, request_id, generation, caller, %{
         "op" => op,
         "snapshot_id" => snapshot_id,
         "owner_request_id" => owner_request_id,
         "deadline_ms" => deadline_ms()
       })}
    else
      {:error, :file_unavailable}
    end
  end

  @spec share_snapshot(pid(), String.t(), integer(), String.t(), String.t()) ::
          {:ok, :async} | {:error, term()}
  def share_snapshot(caller, request_id, generation, snapshot_id, owner_request_id),
    do: present(:share_file, caller, request_id, generation, snapshot_id, owner_request_id)

  @spec open_snapshot(pid(), String.t(), integer(), String.t(), String.t()) ::
          {:ok, :async} | {:error, term()}
  def open_snapshot(caller, request_id, generation, snapshot_id, owner_request_id),
    do: present(:open_file, caller, request_id, generation, snapshot_id, owner_request_id)

  @doc "Start the present step of the artifact sequence."
  @spec present(:open_file | :share_file, pid(), String.t(), integer(), String.t(), String.t()) ::
          {:ok, :async} | {:error, term()}
  def present(action, caller, request_id, generation, snapshot_id, owner_request_id) do
    case present_request(action, caller, request_id, generation, snapshot_id, owner_request_id) do
      {:ok, req} -> start(req)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec cleanup_snapshot(pid(), String.t(), integer(), String.t(), String.t()) ::
          {:ok, :async} | {:error, term()}
  def cleanup_snapshot(caller, request_id, generation, snapshot_id, owner_request_id)
      when is_pid(caller) and is_binary(snapshot_id) and is_binary(owner_request_id) do
    start(
      Request.new("platform_cleanup", request_id, generation, caller, %{
        "op" => "platform_cleanup",
        "snapshot_id" => snapshot_id,
        "owner_request_id" => owner_request_id
      })
    )
  end

  @spec cancel(pid(), String.t(), integer()) :: {:ok, :async} | {:error, term()}
  def cancel(caller, target_request_id, generation)
      when is_pid(caller) and is_binary(target_request_id) do
    command_id = Ecto.UUID.generate()

    start(
      Request.new("platform_cancel", command_id, generation, caller, %{
        "op" => "platform_cancel",
        "target_request_id" => target_request_id
      })
    )
  end

  @spec import_roots() :: [String.t()]
  def import_roots do
    :handbean_probe
    |> Application.get_env(:staging_roots, [])
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
  end

  @spec safe_rm_controlled(term()) :: :ok | {:error, term()}
  def safe_rm_controlled(path) when is_binary(path) do
    abs = Path.expand(path)

    if import_owned?(abs) and File.regular?(abs) do
      File.rm(abs)
    else
      {:error, :outside_import_root}
    end
  end

  def safe_rm_controlled(_), do: {:error, :outside_import_root}

  @spec import_owned?(String.t()) :: boolean()
  def import_owned?(path) when is_binary(path) do
    abs = Path.expand(path)

    Enum.any?(import_roots(), fn root ->
      PathValidator.validate_within_workspace(abs, Path.expand(root)) == :ok
    end)
  end

  def import_owned?(_), do: false

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      pair -> pair
    end)
  end

  defp deadline_ms do
    System.system_time(:millisecond) +
      Application.get_env(:handbean_probe, :android_intent_await_ms, 20_000)
  end

  defp calendar_action(action) when action in ["list_calendars", "list_events", "insert_event"],
    do: action

  defp calendar_action(action) when action in [:list_calendars, :list_events, :insert_event],
    do: Atom.to_string(action)

  defp calendar_action(_), do: nil

  defp text_field(cmd, key) do
    case cmd[key] do
      text when is_binary(text) and text != "" -> text
      _ -> nil
    end
  end

  defp int_field(cmd, key) do
    case cmd[key] do
      value when is_integer(value) -> value
      _ -> nil
    end
  end

  defp bool_field(cmd, key) do
    case cmd[key] do
      value when is_boolean(value) -> value
      _ -> nil
    end
  end

  defp day_field(cmd) do
    case cmd[:days] do
      days when is_list(days) -> Enum.filter(days, &(&1 in 1..7))
      _ -> nil
    end
  end
end
