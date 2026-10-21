defmodule Handbean.ConversationStore.Codec do
  @moduledoc false

  def base_metadata(row) do
    %{
      "id" => row.id,
      "scope" => row.scope,
      "workspace_id" => row.workspace_id,
      "checkout_path" => row.checkout_path,
      "visibility" => row.visibility,
      "parent_conversation_id" => row.parent_conversation_id,
      "parent_run_id" => row.parent_run_id,
      "parent_tool_call_id" => row.parent_tool_call_id,
      "title" => row.title,
      "title_source" => row.title_source,
      "selected_model" => row.selected_model,
      "selected_reasoning_level" => row.selected_reasoning_level,
      "permission_mode" => row.permission_mode,
      "permission_revision" => row.permission_revision,
      "collaboration" => row.collaboration,
      "last_run_result" => row.last_run_result,
      "status" => row.status,
      "loaded_tools" => decode_list(row.loaded_tools),
      "archived_at" => iso8601(row.archived_at),
      "pinned_at" => iso8601(row.pinned_at),
      "created_at" => iso8601(row.created_at),
      "updated_at" => iso8601(row.updated_at)
    }
  end

  def summary(row) do
    %{
      "id" => row.id,
      "visibility" => row.visibility,
      "parent_conversation_id" => row.parent_conversation_id,
      "parent_run_id" => row.parent_run_id,
      "parent_tool_call_id" => row.parent_tool_call_id,
      "scope" => row.scope,
      "workspace_id" => row.workspace_id,
      "checkout_path" => row.checkout_path,
      "title" => row.title,
      "title_source" => row.title_source,
      "archived_at" => iso8601(row.archived_at),
      "pinned_at" => iso8601(row.pinned_at),
      "created_at" => iso8601(row.created_at),
      "updated_at" => iso8601(row.updated_at)
    }
  end

  def editor(state) do
    %{
      "editor_files" => decode_list(state.editor_files),
      "active_file" => state.active_file,
      "file_preview_error" => decode_nullable(state.file_preview_error)
    }
  end

  def empty_files,
    do: %{"editor_files" => [], "active_file" => nil, "file_preview_error" => nil}

  def map_value(map, key), do: Handbean.Utils.SafeMap.get(map, key)

  def string_value(map, key) do
    case map_value(map, key) do
      nil -> nil
      value when is_binary(value) -> value
      value -> to_string(value)
    end
  end

  def list_value(map, key) do
    case map_value(map, key) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  def title_text(title) when is_binary(title) do
    case String.trim(title) do
      "" -> ""
      trimmed -> trimmed
    end
  end

  def title_text(_title), do: ""

  def encode_json!(value), do: value |> Handbean.JsonSafe.normalize() |> Handbean.JSON.encode!()

  def decode_list(nil), do: []

  def decode_list(value) when is_binary(value) do
    case Handbean.JSON.decode(value) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  def encode_nullable(nil), do: nil
  def encode_nullable(value), do: encode_json!(value)

  defp decode_nullable(nil), do: nil

  defp decode_nullable(value) do
    case Handbean.JSON.decode(value) do
      {:ok, decoded} -> decoded
      _ -> value
    end
  end

  def parse_time(nil), do: nil
  def parse_time(%DateTime{} = value), do: microsecond_precision(value)

  def parse_time(%NaiveDateTime{} = value),
    do: value |> DateTime.from_naive!("Etc/UTC") |> microsecond_precision()

  def parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _offset} -> microsecond_precision(timestamp)
      _ -> nil
    end
  end

  defp iso8601(nil), do: nil

  defp iso8601(%DateTime{microsecond: {0, _precision}} = value),
    do: value |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp iso8601(%NaiveDateTime{} = value),
    do: value |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()

  defp microsecond_precision(%DateTime{microsecond: {microsecond, _precision}} = value),
    do: %{value | microsecond: {microsecond, 6}}
end
