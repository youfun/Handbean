defmodule Handbean.Agent.Tool.ResultContract do
  @moduledoc """
  Bounded tool-result contract shared by the executor, events, and transcripts.

  Large bodies live in artifacts. LLM content, PubSub, EventRecorder, and
  transcript details only carry a bounded summary plus opaque references.
  Explicit failure signals take precedence over success/running metadata.
  `is_error` is derived from the reconciled status so the two cannot disagree.
  """

  alias Handbean.Agent.Tool.Result

  @statuses [:succeeded, :failed, :running, :interrupted]
  @side_effects [:not_started, :committed, :unknown]
  @detail_keys [
    :file_path,
    :bytes,
    :lines,
    :exit_code,
    :timed_out,
    :job,
    :job_id,
    :cursor,
    :cleanup_error,
    :diff_lines,
    :diff_stat,
    :change_id,
    :change_snapshot_ref,
    :changes,
    :change_count,
    :change_type,
    :existed_before,
    :existed_after,
    :before_sha256,
    :after_sha256,
    :reversible,
    :revert_status,
    :revert_reason,
    :artifact_ref,
    :artifact_unavailable,
    :indexing,
    :truncated,
    :partial,
    :started_at,
    :completed_at,
    :duration_ms,
    :timing_fidelity
  ]
  @max_detail_string 2_000
  @max_diff_lines 80
  @max_diff_line 400
  @max_details_bytes 8_000
  @max_content_bytes 16_000

  @spec project(Result.t(), keyword()) :: Result.t()
  def project(%Result{} = result, opts \\ []) do
    status = status(result)
    details = project_details(result.details, opts)

    %{
      result
      | status: status,
        is_error: status in [:failed, :interrupted],
        side_effect: side_effect(result.side_effect),
        content: bound_text(result.content, Keyword.get(opts, :max_content, @max_content_bytes)),
        details: details,
        recovery: bound_recovery(result.recovery),
        artifacts: bound_artifacts(result.artifacts),
        images: Handbean.Tool.Images.project(result.images),
        published_media: Handbean.Media.project(result.published_media)
    }
  end

  @spec project_details(map() | nil, keyword()) :: map() | nil
  def project_details(details, opts \\ [])

  def project_details(nil, _opts), do: nil

  def project_details(details, opts) when is_map(details) do
    projected =
      details
      |> drop_full_bodies()
      |> take_whitelist()
      |> bound_values()
      |> attach_artifact(opts)
      |> drop_if_too_large()

    if projected == %{}, do: nil, else: projected
  end

  def project_details(_details, _opts), do: nil

  @spec status(Result.t()) :: atom()
  def status(%Result{status: status}) when status in [:failed, :interrupted], do: status
  def status(%Result{is_error: true}), do: :failed
  def status(%Result{status: status}) when status in @statuses, do: status
  def status(%Result{}), do: :succeeded

  @spec side_effect(atom() | nil) :: atom()
  def side_effect(value) when value in @side_effects, do: value
  def side_effect(_), do: :unknown

  @spec envelope(Result.t()) :: map()
  def envelope(%Result{} = result) do
    %{
      operation_id: result.operation_id,
      status: status(result),
      code: result.code,
      side_effect: side_effect(result.side_effect),
      recovery: bound_recovery(result.recovery),
      artifacts: bound_artifacts(result.artifacts),
      published_media: Handbean.Media.project(result.published_media)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == [] end)
    |> Map.new()
  end

  defp drop_full_bodies(details) do
    Map.drop(details, [
      :original_content,
      "original_content",
      :before_content,
      "before_content",
      :after_content,
      "after_content",
      :content,
      "content",
      :output,
      "output",
      :change,
      "change"
    ])
  end

  defp take_whitelist(details) do
    Enum.reduce(details, %{}, fn {key, value}, acc ->
      name = detail_name(key)

      cond do
        is_nil(value) or is_nil(name) -> acc
        name in @detail_keys or small_metadata?(value) -> Map.put(acc, name, value)
        true -> acc
      end
    end)
  end

  defp detail_name(key) when is_atom(key), do: key

  defp detail_name(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp detail_name(_key), do: nil

  defp small_metadata?(value) when is_binary(value), do: byte_size(value) <= @max_detail_string

  defp small_metadata?(value) when is_number(value) or is_boolean(value) or is_atom(value),
    do: true

  defp small_metadata?(_value), do: false

  defp bound_values(details) do
    bounded =
      details
      |> Enum.reduce(%{}, fn
        {:diff_lines, lines}, acc ->
          Map.put(acc, :diff_lines, bound_diff(lines))

        {:diff_stat, stat}, acc ->
          case bound_diff_stat(stat) do
            nil -> acc
            bounded_stat -> Map.put(acc, :diff_stat, bounded_stat)
          end

        {:changes, changes}, acc ->
          Map.put(acc, :changes, bound_changes(changes))

        {:job, job}, acc when is_map(job) ->
          Map.put(acc, :job, bound_job(job))

        {key, value}, acc when is_binary(value) ->
          Map.put(acc, key, bound_text(value, @max_detail_string))

        {key, value}, acc ->
          Map.put(acc, key, value)
      end)

    case Map.get(details, :changes) do
      changes when is_list(changes) and length(changes) > 32 ->
        bounded
        |> Map.put(:change_count, length(changes))
        |> Map.put(:partial, true)

      _ ->
        bounded
    end
  end

  defp bound_diff_stat(stat) when is_map(stat) do
    added = Map.get(stat, :added, Map.get(stat, "added", 0))
    removed = Map.get(stat, :removed, Map.get(stat, "removed", 0))

    if is_integer(added) and added >= 0 and is_integer(removed) and removed >= 0 do
      %{added: added, removed: removed}
    else
      nil
    end
  end

  defp bound_diff_stat(_stat), do: nil

  defp bound_diff(lines) when is_list(lines) do
    lines
    |> Enum.take(@max_diff_lines)
    |> Enum.map(fn
      %{"type" => type, "text" => text} ->
        %{"type" => to_string(type), "text" => bound_text(to_string(text), @max_diff_line)}

      %{type: type, text: text} ->
        %{"type" => to_string(type), "text" => bound_text(to_string(text), @max_diff_line)}

      other ->
        %{"type" => "eq", "text" => bound_text(to_string(other), @max_diff_line)}
    end)
  end

  defp bound_diff(_lines), do: []

  defp bound_changes(changes) when is_list(changes) do
    changes
    |> Enum.take(32)
    |> Enum.map(fn
      change when is_map(change) ->
        taken =
          Map.take(change, [
            :file_path,
            :change_snapshot_ref,
            :change_type,
            :existed_before,
            :existed_after,
            :before_sha256,
            :after_sha256,
            :diff_stat,
            :reversible,
            :revert_status,
            :revert_reason,
            "file_path",
            "change_snapshot_ref",
            "change_type",
            "existed_before",
            "existed_after",
            "before_sha256",
            "after_sha256",
            "diff_stat",
            "reversible",
            "revert_status",
            "revert_reason"
          ])

        case bound_diff_stat(Map.get(taken, :diff_stat, Map.get(taken, "diff_stat"))) do
          nil ->
            Map.drop(taken, [:diff_stat, "diff_stat"])

          bounded_stat ->
            taken
            |> Map.delete("diff_stat")
            |> Map.put(:diff_stat, bounded_stat)
        end

      _other ->
        %{}
    end)
    |> Enum.reject(&(&1 == %{}))
  end

  defp bound_changes(_changes), do: []

  defp bound_job(job) do
    job
    |> Map.take([:job_id, :state, :cursor, :cleanup_error, :exit_code, "job_id", "state"])
    |> Map.new(fn
      {key, value} when is_binary(value) -> {key, bound_text(value, 500)}
      pair -> pair
    end)
  end

  defp bound_recovery(recovery) when is_map(recovery) do
    recovery
    |> Map.take([
      :action,
      :ref,
      :allowed_overrides,
      :note,
      "action",
      "ref",
      "allowed_overrides",
      "note"
    ])
    |> Map.new(fn
      {key, value} when is_binary(value) ->
        {key, bound_text(value, 1_000)}

      {key, value} when is_list(value) ->
        {key, value |> Enum.take(20) |> Enum.map(&bound_text(&1, 200))}

      pair ->
        pair
    end)
  end

  defp bound_recovery(recovery) when is_atom(recovery) or is_nil(recovery), do: recovery
  defp bound_recovery(recovery), do: bound_text(recovery, 1_000)

  defp bound_artifacts(artifacts) do
    artifacts
    |> List.wrap()
    |> Enum.take(10)
    |> Enum.map(fn
      artifact when is_map(artifact) ->
        artifact
        |> Map.take([:ref, :path, :type, :bytes, "ref", "path", "type", "bytes"])
        |> Map.new(fn
          {key, value} when is_binary(value) -> {key, bound_text(value, 1_000)}
          pair -> pair
        end)

      artifact ->
        %{ref: bound_text(artifact, 1_000)}
    end)
  end

  defp attach_artifact(details, opts) do
    case Keyword.get(opts, :artifact) do
      nil -> details
      ref when is_binary(ref) -> Map.put(details, :artifact_ref, ref)
      :unavailable -> Map.put(details, :artifact_unavailable, true)
    end
  end

  defp drop_if_too_large(details) do
    encoded = Handbean.JSON.encode!(Handbean.JsonSafe.normalize(details))

    if byte_size(encoded) <= @max_details_bytes do
      details
    else
      reduced =
        Map.take(details, [
          :file_path,
          :change_snapshot_ref,
          :change_count,
          :omitted_paths,
          :truncated,
          :diff_stat,
          :partial,
          :artifact_ref,
          :artifact_unavailable,
          :exit_code,
          :started_at,
          :completed_at,
          :duration_ms,
          :timing_fidelity
        ])

      case Map.get(details, :changes) do
        changes when is_list(changes) and changes != [] ->
          reduced
          |> Map.put_new(:change_count, length(changes))
          |> Map.put(:partial, true)

        _ ->
          reduced
      end
    end
  end

  defp bound_text(text, max) when is_binary(text) and byte_size(text) > max do
    head = max - 80
    String.slice(text, 0, max(head, 0)) <> "\n[truncated #{byte_size(text)} bytes]"
  end

  defp bound_text(text, _max) when is_binary(text), do: text

  defp bound_text(other, max),
    do: other |> inspect(limit: 20, printable_limit: 200) |> bound_text(max)
end
