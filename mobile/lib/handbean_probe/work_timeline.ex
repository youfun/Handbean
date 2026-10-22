defmodule HandbeanProbe.WorkTimeline do
  @moduledoc """
  Display-only projection of transcript entries into tool work groups.

  Consecutive tool entries are one group until a non-tool entry. Completed
  groups stay collapsed unless `groups` marks that group id open. Assistant
  commentary and final answers stay visible. `segments` is accepted for
  existing callers and ignored. `outputs` still sets `tool_output_open`.
  """
  alias Handbean.TranscriptEntry
  alias HandbeanProbe.Bridge.Payload
  alias HandbeanWeb.WorkspaceHelper

  # Obsolete segment keys stay in the drop list so a second projection, or an
  # entry that still carries them, does not leak the old hiding behavior.
  @projection_keys ~w(work_group_id work_group_first work_group_complete work_collapsed
    work_summary work_failed work_cancelled work_edit work_added work_removed work_indent
    work_verb work_target tool_output_open work_segment_id work_segment_first
    work_segment_open work_hidden work_boundary_summary)

  def project(entries, groups \\ %{}, segments \\ %{}, outputs \\ %{}) when is_list(entries) do
    _ = segments

    expanded_ids =
      Enum.flat_map(groups, fn
        {id, true} -> [id]
        _ -> []
      end)

    entries
    |> Enum.map(&Map.drop(&1, @projection_keys))
    |> WorkspaceHelper.apply_tool_work_collapse(expanded_ids)
    |> Enum.map(&annotate_tool(&1, groups, outputs))
    |> put_outcome_counts()
  end

  defp annotate_tool(%{"content_type" => "tool"} = entry, groups, outputs) do
    role = WorkspaceHelper.tool_work_role(name(entry))

    entry
    |> apply_group_open(groups)
    |> Map.put("work_edit", role == :edit)
    |> Map.put("work_added", diff_count(entry, "add"))
    |> Map.put("work_removed", diff_count(entry, "remove"))
    |> Map.put(
      "tool_output_open",
      Map.get(outputs, entry["id"], entry["direct_command"] == true)
    )
  end

  defp annotate_tool(entry, _groups, _outputs), do: entry

  defp apply_group_open(entry, groups) do
    case group_open(groups, entry["work_group_id"]) do
      open? when is_boolean(open?) -> Map.put(entry, "work_collapsed", not open?)
      _ -> entry
    end
  end

  defp group_open(groups, id) when is_binary(id) do
    if Map.has_key?(groups, id), do: Map.get(groups, id)
  end

  defp group_open(_groups, _id), do: nil

  defp put_outcome_counts(entries) do
    entries
    |> Enum.chunk_by(& &1["work_group_id"])
    |> Enum.flat_map(fn
      [%{"work_group_id" => id} | _] = chunk when is_binary(id) ->
        failed = Enum.count(chunk, &(status(&1) in ["error", "failed"]))
        cancelled = Enum.count(chunk, &(status(&1) == "cancelled"))

        Enum.map(chunk, fn entry ->
          entry
          |> Map.put("work_failed", failed)
          |> Map.put("work_cancelled", cancelled)
        end)

      chunk ->
        chunk
    end)
  end

  # Transcript compat reads (`tool` / `tool_name`, …) go through
  # `Handbean.TranscriptEntry`; tool `input` is string-keyed once via `Payload`.
  def name(entry), do: TranscriptEntry.tool_name(entry) || "tool"
  def status(entry), do: to_string(TranscriptEntry.tool_status(entry) || "done")

  def path(entry) do
    input = input(entry)

    entry["file_path"] || Payload.first(input, ["file_path", "path"]) ||
      TranscriptEntry.input_summary(entry) || "file"
  end

  def input_label(entry) do
    input = input(entry)
    input["command"] || TranscriptEntry.input_summary(entry) || path(entry)
  end

  defp input(entry), do: entry |> TranscriptEntry.input() |> Payload.string_keys()

  def output(entry) do
    value = entry["output"] || TranscriptEntry.error(entry)

    case value do
      nil -> ""
      text when is_binary(text) -> text
      other -> inspect(other, pretty: true, limit: 100)
    end
  end

  defp diff_count(entry, kind) do
    lines =
      if is_list(entry["diff_lines"]), do: Payload.string_keys(entry["diff_lines"]), else: []

    Enum.count(lines, fn line ->
      type = line["type"]

      to_string(type) in if(kind == "add",
        do: ["add", "added", "ins", "+"],
        else: ["remove", "removed", "delete", "del", "-"]
      )
    end)
  end
end
