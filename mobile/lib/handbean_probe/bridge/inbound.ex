defmodule HandbeanProbe.Bridge.Inbound do
  @moduledoc """
  The single decode point for messages that enter the screen from the host
  (Kotlin / C / Mob) before any domain `handle/2` sees them.

  Three shapes arrive from outside the BEAM:

    * `{:engine_result, map}` — `c_src/handbean_browser.c` echoes a platform
      request (`request_id`, `generation`, optional `session_id`, `url`) with
      either an `error` string or a `result` JSON document written by Kotlin.
    * `{:notification, map}` — Mob decodes `mob_notification_json`
      (`AgentNotify.kt`) into `id` / `title` / `body` / `source` / `data`.
    * `{:files, :picked, items}` — Mob decodes the SAF picker receipt
      (`WorkspaceImport.kt`) into `path` / `name` / `size` / `request_id` /
      `error` items.

  Every key is mapped through a fixed whitelist: known atom keys pass, known
  string keys are mapped to their atom, anything else is dropped. There is no
  `String.to_atom/1` and no atom-or-string double lookup outside this module; the
  domains receive structs and read fields.

  The JSON *body* of an engine result is decoded to a typed `body/0`. Snapshot
  and outcome documents are lifted to `Snapshot` (atom keys). Attachment
  documents stay string-keyed maps because that is the `Handbean.Attachments`
  contract (`persistable/1`, `validate_batch/1`); they are one JSON
  representation, never a dual-key one.
  """

  require Logger

  defmodule EngineResult do
    @moduledoc "Decoded `{:engine_result, map}` envelope. `body` is `HandbeanProbe.Bridge.Inbound.body/0`."
    defstruct [:request_id, :generation, :session_id, :url, :body]

    @type t :: %__MODULE__{
            request_id: String.t(),
            generation: integer() | nil,
            session_id: String.t() | nil,
            url: String.t() | nil,
            body: HandbeanProbe.Bridge.Inbound.body()
          }
  end

  defmodule Notification do
    @moduledoc "Decoded `{:notification, map}`; `data` is flattened to the two ids Handbean uses."
    defstruct [:id, :title, :body, :source, :workspace_id, :conversation_id]

    @type t :: %__MODULE__{}
  end

  defmodule PickedFile do
    @moduledoc "One decoded item of `{:files, :picked, items}`."
    defstruct [:request_id, :path, :name, :size, :error]

    @type t :: %__MODULE__{}
  end

  defmodule Snapshot do
    @moduledoc """
    Export snapshot / system-UI outcome document as Kotlin writes it
    (`platform_export`, `platform_open_snapshot`, `platform_share_snapshot`,
    `platform_open_url`, `platform_share_text` results) and as
    `Handbean.ExportSnapshot.Binding` stores it.
    """
    defstruct [
      :snapshot_id,
      :owner_request_id,
      :display_name,
      :size_bytes,
      :relative_path,
      :workspace_path,
      :path,
      :mime,
      :state,
      :outcome,
      :url,
      :action,
      :event_id,
      :calendar_id,
      :hour,
      :minute,
      :calendars,
      :events,
      :calendar_read,
      :calendar_write
    ]

    @type t :: %__MODULE__{}
  end

  @type body ::
          {:ok, map()}
          | {:ok_batch, [map()], [term()]}
          | :cancelled
          | {:error, term()}

  @engine_keys %{
    "request_id" => :request_id,
    "generation" => :generation,
    "session_id" => :session_id,
    "result" => :result,
    "error" => :error,
    "url" => :url
  }

  @notification_keys %{
    "id" => :id,
    "title" => :title,
    "body" => :body,
    "source" => :source,
    "data" => :data
  }

  @notification_data_keys %{
    "workspace_id" => :workspace_id,
    "conversation_id" => :conversation_id
  }

  @picked_file_keys %{
    "request_id" => :request_id,
    "path" => :path,
    "name" => :name,
    "size" => :size,
    "error" => :error
  }

  @snapshot_keys %{
    "snapshot_id" => :snapshot_id,
    "owner_request_id" => :owner_request_id,
    "display_name" => :display_name,
    "size_bytes" => :size_bytes,
    "relative_path" => :relative_path,
    "workspace_path" => :workspace_path,
    "path" => :path,
    "mime" => :mime,
    "state" => :state,
    "outcome" => :outcome,
    "url" => :url,
    "action" => :action,
    "event_id" => :event_id,
    "calendar_id" => :calendar_id,
    "hour" => :hour,
    "minute" => :minute,
    "calendars" => :calendars,
    "events" => :events,
    "calendar_read" => :calendar_read,
    "calendar_write" => :calendar_write
  }

  @doc "Wire keys `engine_result/1` accepts, in the order C writes them."
  def engine_keys, do: Map.values(@engine_keys)
  def snapshot_keys, do: Map.values(@snapshot_keys)

  @doc """
  Decode one screen message. Host shapes become structs; every other message
  passes through unchanged. An unusable host message is
  `{:error, {:invalid, kind}}` and the caller drops it.
  """
  @spec decode(term()) :: {:ok, term()} | {:error, {:invalid, atom()}}
  def decode({:engine_result, map}) when is_map(map) do
    case engine_result(map) do
      {:ok, decoded} -> {:ok, {:engine_result, decoded}}
      {:error, _} -> {:error, {:invalid, :engine_result}}
    end
  end

  def decode({:engine_result, _}), do: {:error, {:invalid, :engine_result}}

  def decode({:notification, map}) when is_map(map),
    do: {:ok, {:notification, notification(map)}}

  def decode({:notification, _}), do: {:error, {:invalid, :notification}}

  def decode({:files, :picked, items}) when is_list(items),
    do: {:ok, {:files, :picked, Enum.map(items, &picked_file/1)}}

  def decode({:files, :picked, _}), do: {:error, {:invalid, :files_picked}}

  def decode(message), do: {:ok, message}

  @doc "Decode the C `engine_result` map. Requires a binary `request_id`."
  @spec engine_result(map()) :: {:ok, EngineResult.t()} | {:error, :invalid_engine_result}
  def engine_result(map) when is_map(map) do
    wire = take(map, @engine_keys)

    case wire[:request_id] do
      request_id when is_binary(request_id) and request_id != "" ->
        {:ok,
         %EngineResult{
           request_id: request_id,
           generation: integer_or_nil(wire[:generation]),
           session_id: wire[:session_id],
           url: wire[:url],
           body: body(wire[:error], wire[:result])
         }}

      _ ->
        {:error, :invalid_engine_result}
    end
  end

  def engine_result(_), do: {:error, :invalid_engine_result}

  @doc "Decode a Mob notification payload."
  @spec notification(map()) :: Notification.t()
  def notification(map) when is_map(map) do
    wire = take(map, @notification_keys)

    data =
      case wire[:data] do
        data when is_map(data) -> take(data, @notification_data_keys)
        _ -> %{}
      end

    %Notification{
      id: wire[:id],
      title: wire[:title],
      body: wire[:body],
      source: wire[:source],
      workspace_id: data[:workspace_id],
      conversation_id: data[:conversation_id]
    }
  end

  @doc "Decode one SAF picker item. Idempotent on an already decoded struct."
  @spec picked_file(map()) :: PickedFile.t()
  def picked_file(%PickedFile{} = item), do: item

  def picked_file(map) when is_map(map) do
    wire = take(map, @picked_file_keys)

    %PickedFile{
      request_id: wire[:request_id],
      path: wire[:path],
      name: wire[:name],
      size: wire[:size],
      error: wire[:error]
    }
  end

  def picked_file(_), do: %PickedFile{}

  @doc """
  Lift a snapshot / outcome document to `Snapshot`. Accepts the string-keyed
  JSON body, the atom-keyed meta `Handbean.ExportSnapshot.Binding` stores, or an
  existing struct.
  """
  @spec snapshot(map()) :: Snapshot.t()
  def snapshot(%Snapshot{} = snap), do: snap
  def snapshot(map) when is_map(map), do: struct(Snapshot, take(map, @snapshot_keys))
  def snapshot(_), do: %Snapshot{}

  @doc "Outcome string of a system-UI result body."
  @spec outcome(body()) :: String.t()
  def outcome({:ok, map}) when is_map(map) do
    case snapshot(map).outcome do
      outcome when is_binary(outcome) and outcome != "" -> outcome
      _ -> "outcome_unknown"
    end
  end

  def outcome({:error, reason}) when is_binary(reason), do: reason
  def outcome({:error, reason}) when is_atom(reason) and not is_nil(reason), do: to_string(reason)
  def outcome(:cancelled), do: "cancelled_before_launch"
  def outcome(_), do: "outcome_unknown"

  @doc "Log and drop an undecodable host message."
  def drop(message, reason) do
    Logger.warning("[bridge] dropped host message #{inspect(reason)}: #{inspect(message)}")
    :ok
  end

  # ── body ──

  defp body(error, _result) when is_binary(error) and error != "", do: {:error, error}
  defp body(_error, "cancelled"), do: :cancelled
  defp body(_error, result) when is_binary(result), do: decode_json(result)
  defp body(_error, _), do: {:error, :invalid_platform_result}

  defp decode_json(json) do
    case Handbean.JSON.decode(json) do
      {:ok, %{"cancelled" => true}} ->
        :cancelled

      {:ok, %{"outcome" => "cancelled"}} ->
        :cancelled

      {:ok, %{"error" => reason}} ->
        {:error, reason}

      {:ok, %{"attachments" => atts} = doc} when is_list(atts) ->
        {:ok_batch, atts, List.wrap(doc["errors"])}

      {:ok, doc} when is_map(doc) ->
        {:ok, doc}

      _ ->
        {:error, :invalid_platform_result}
    end
  end

  # ── whitelist ──

  # Atom keys in the schema pass; string keys are mapped; everything else is
  # dropped. Never `String.to_atom/1`.
  defp take(map, schema) do
    atoms = schema |> Map.values() |> MapSet.new()

    Enum.reduce(map, %{}, fn
      {key, value}, acc when is_atom(key) ->
        if MapSet.member?(atoms, key), do: Map.put(acc, key, value), else: acc

      {key, value}, acc when is_binary(key) ->
        case Map.fetch(schema, key) do
          {:ok, atom} -> Map.put_new(acc, atom, value)
          :error -> acc
        end

      _, acc ->
        acc
    end)
  end

  defp integer_or_nil(value) when is_integer(value), do: value
  defp integer_or_nil(_), do: nil
end
