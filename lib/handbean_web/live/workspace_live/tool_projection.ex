defmodule HandbeanWeb.WorkspaceLive.ToolProjection do
  @moduledoc false

  alias Handbean.ChangeSnapshot
  alias HandbeanWeb.ChangeHelper

  def start(payload, summarize_input) do
    tool_name = value(payload, :tool) || value(payload, :name) || "unknown"
    tool_use_id = value(payload, :tool_use_id) || tool_name
    input = value(payload, :input) || %{}
    summary = summarize_input.(input, tool_name)

    %{
      tool_name: tool_name,
      entry: %{
        "id" => entry_id(payload, tool_use_id, tool_name),
        "content_type" => "tool",
        "tool_use_id" => tool_use_id,
        "tool_name" => tool_name,
        "tool_status" => "running",
        "input" => input,
        "tool_input_summary" => summary,
        "tool_duration_ms" => nil,
        "tool_error" => nil,
        "file_path" => nil,
        "diff_lines" => nil,
        "started_at" => System.os_time(:millisecond)
      }
    }
  end

  def finish(payload, base_entry) do
    tool_name = value(payload, :tool) || value(payload, :name) || "unknown"
    duration_ms = value(payload, :duration_ms)
    error = value(payload, :error)

    details =
      payload
      |> value(:details)
      |> Handbean.Agent.Tool.ResultContract.project_details()
      |> Kernel.||(%{})

    file_path = value(payload, :file_path) || value(details, :file_path)
    diff_lines = ChangeHelper.normalize_diff_lines(value(details, :diff_lines))
    change_details = load_change_snapshot(details)
    change = ChangeHelper.change_from_details(change_details, file_path, diff_lines, tool_name)
    status = if error, do: :error, else: :done

    entry =
      Map.merge(base_entry, %{
        "tool_name" => tool_name,
        "tool_status" => Atom.to_string(status),
        "tool_duration_ms" => duration_ms,
        "tool_error" => error,
        "output" => value(payload, :output),
        "details" => details,
        "file_path" => file_path,
        "diff_lines" => diff_lines,
        "change" => change,
        "change_id" => Map.get(change, "change_id"),
        "change_type" => Map.get(change, "change_type"),
        "reversible" => Map.get(change, "reversible"),
        "revert_status" => Map.get(change, "revert_status"),
        "revert_reason" => Map.get(change, "revert_reason")
      })

    %{
      entry: entry,
      tool_name: tool_name,
      status: status,
      file_path: file_path,
      diff_lines: diff_lines
    }
  end

  def identity(payload) do
    tool_name = value(payload, :tool) || value(payload, :name) || "unknown"
    tool_use_id = value(payload, :tool_use_id) || tool_name
    id = entry_id(payload, tool_use_id, tool_name)
    {id, tool_name, tool_use_id}
  end

  defp entry_id(payload, tool_use_id, tool_name) do
    if Map.has_key?(payload, :tool_use_id) or Map.has_key?(payload, "tool_use_id"),
      do: "tool-#{tool_use_id}",
      else: "tool-event-#{tool_name}"
  end

  defp load_change_snapshot(details) do
    with ref when is_binary(ref) <- value(details, :change_snapshot_ref),
         {:ok, snapshot} <- ChangeSnapshot.load(ref) do
      Map.put(details, :change, snapshot)
    else
      _ -> details
    end
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
