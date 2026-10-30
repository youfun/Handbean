defmodule Handbean.ChangeSnapshot do
  @moduledoc """
  Builds reversible file-change snapshots for WebUI diff review.

  The UI diff can be clipped for readability, so revert must rely on these
  full before/after snapshots and hashes instead of diff lines.
  """

  @max_snapshot_bytes 1_000_000
  @diff_context_lines 3
  @max_myers_lines 512
  @max_myers_bytes 128_000
  @ref_prefix "change_snapshot:"

  @type snapshot :: map()

  @spec sha256(binary() | nil) :: String.t() | nil
  def sha256(nil), do: nil

  def sha256(content) when is_binary(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  @spec build_edit_snapshot(Path.t(), binary(), binary(), [map()] | nil, keyword()) :: snapshot()
  def build_edit_snapshot(file_path, before_content, after_content, diff_lines \\ nil, opts \\ []) do
    diff_lines = diff_lines || diff_lines(before_content, after_content)
    build_snapshot("edit", file_path, true, before_content, after_content, diff_lines, opts)
  end

  @spec build_write_snapshot(Path.t(), binary() | nil, binary(), keyword()) :: snapshot()
  def build_write_snapshot(file_path, before_content, after_content, opts \\ []) do
    existed_before = is_binary(before_content)
    diff_lines = diff_lines(before_content || "", after_content)

    build_snapshot(
      "write",
      file_path,
      existed_before,
      before_content,
      after_content,
      diff_lines,
      opts
    )
  end

  @spec build_delete_snapshot(Path.t(), binary(), keyword()) :: snapshot()
  def build_delete_snapshot(file_path, before_content, opts \\ [])
      when is_binary(before_content) do
    "delete"
    |> build_snapshot(
      file_path,
      true,
      before_content,
      nil,
      diff_lines(before_content, ""),
      opts
    )
    |> Map.put(:existed_after, false)
  end

  @doc """
  Persists a reversible snapshot outside tool events and returns an opaque
  reference suitable for the bounded result contract.
  """
  @spec persist(snapshot(), map()) :: {:ok, String.t()} | {:error, term()}
  def persist(%{reversible: true, change_id: change_id} = snapshot, context)
      when is_map(context) do
    with conversation_id when is_binary(conversation_id) <- conversation_id(context),
         {:ok, encoded} <- encode_snapshot(snapshot),
         :ok <-
           Handbean.ConversationArtifacts.persist_change_snapshot(
             conversation_id,
             change_id,
             encoded
           ) do
      {:ok, encode_ref(conversation_id, change_id)}
    else
      nil -> {:error, :missing_conversation_id}
      {:error, _reason} = error -> error
    end
  end

  def persist(_snapshot, _context), do: {:error, :not_reversible}

  @doc "Loads a persisted change snapshot from an opaque reference."
  @spec load(String.t()) :: {:ok, snapshot()} | {:error, term()}
  def load(@ref_prefix <> encoded) do
    with {:ok, conversation_id, change_id} <- decode_ref(encoded),
         {:ok, body} <-
           Handbean.ConversationArtifacts.load_change_snapshot(conversation_id, change_id),
         {:ok, snapshot} <- Handbean.JSON.decode(body),
         true <- is_map(snapshot) do
      {:ok, snapshot}
    else
      false -> {:error, :invalid_snapshot_ref}
      [_single] -> {:error, :invalid_snapshot_ref}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_snapshot}
    end
  end

  def load(_ref), do: {:error, :invalid_snapshot_ref}

  @doc """
  Deletes a newly created snapshot after a known duplicate or known failed append.

  Call only for a reference returned by a successful `persist/2` in the current
  operation, when no writer can still publish it. Never call after an exception or
  any uncertain append outcome. The durable reference scan is fail-closed and
  refuses to delete referenced snapshots. Returns `:ok` after deletion,
  `{:error, :snapshot_referenced}` if referenced, `{:error, :invalid_snapshot_ref}`
  for a malformed reference, `{:error, :enoent}` if missing,
  `{:error, :snapshot_scan_inside_transaction}` when called inside an existing
  database transaction, or `{:error, reason}` for another scan, locking, path,
  or filesystem failure.
  """
  @spec delete_uncommitted(String.t()) :: :ok | {:error, term()}
  def delete_uncommitted(ref) do
    [{^ref, result}] = delete_uncommitted_batch([ref])
    result
  end

  @doc """
  Deletes multiple newly created, known-uncommitted snapshots with one durable
  reference scan. The safety conditions and result values are the same as
  `delete_uncommitted/1`. Results are `{ref, result}` pairs in input order;
  duplicate references are deleted once and receive the same result.
  """
  @spec delete_uncommitted_batch([term()]) :: [{term(), :ok | {:error, term()}}]
  def delete_uncommitted_batch(refs) when is_list(refs) do
    unique_refs = Enum.uniq(refs)

    {valid, invalid} =
      Enum.reduce(unique_refs, {[], %{}}, fn ref, {valid, invalid} ->
        case decode_snapshot_ref(ref) do
          {:ok, conversation_id, change_id} ->
            {[{conversation_id, change_id, ref} | valid], invalid}

          {:error, _reason} = error ->
            {valid, Map.put(invalid, ref, error)}
        end
      end)

    results =
      valid
      |> Handbean.ConversationArtifacts.delete_uncommitted_change_snapshots()
      |> Enum.into(invalid)

    Enum.map(refs, &{&1, Map.fetch!(results, &1)})
  end

  defp decode_snapshot_ref(@ref_prefix <> encoded), do: decode_ref(encoded)
  defp decode_snapshot_ref(_ref), do: {:error, :invalid_snapshot_ref}

  @doc "Returns bounded result details and stores full revert data when possible."
  @spec result_details(snapshot(), map()) :: map()
  def result_details(snapshot, context) do
    details = Map.take(snapshot, snapshot_metadata_keys())

    case persist(snapshot, context) do
      {:ok, ref} ->
        Map.put(details, :change_snapshot_ref, ref)

      {:error, :not_reversible} ->
        details

      {:error, _reason} ->
        %{
          details
          | reversible: false,
            revert_status: "unavailable",
            revert_reason: "snapshot_unavailable"
        }
    end
  end

  @spec diff_lines(binary(), binary()) :: [map()] | nil
  def diff_lines(old, new) when old == new, do: nil

  def diff_lines(old, new) when is_binary(old) and is_binary(new) do
    old
    |> line_diff(new)
    |> clip_diff_context()
    |> Enum.flat_map(fn
      {:eq, lines} -> Enum.map(lines, &%{"type" => "eq", "text" => &1})
      {:del, lines} -> Enum.map(lines, &%{"type" => "del", "text" => &1})
      {:ins, lines} -> Enum.map(lines, &%{"type" => "ins", "text" => &1})
      {:skip, count} -> [%{"type" => "skip", "text" => "... #{count} unchanged lines ..."}]
    end)
  end

  defp build_snapshot(
         change_type,
         file_path,
         existed_before,
         before_content,
         after_content,
         diff_lines,
         opts
       ) do
    max_bytes = Keyword.get(opts, :max_snapshot_bytes, @max_snapshot_bytes)
    total_bytes = byte_size(before_content || "") + byte_size(after_content || "")
    reversible = total_bytes <= max_bytes
    change_id = Keyword.get_lazy(opts, :change_id, fn -> "chg_" <> Ecto.UUID.generate() end)

    %{
      change_id: change_id,
      change_type: change_type,
      file_path: file_path,
      existed_before: existed_before,
      existed_after: is_binary(after_content),
      before_sha256: sha256(before_content),
      after_sha256: sha256(after_content),
      before_content: if(reversible, do: before_content, else: nil),
      after_content: if(reversible, do: after_content, else: nil),
      diff_lines: diff_lines,
      diff_stat: diff_stat(diff_lines),
      reversible: reversible,
      revert_status: if(reversible, do: "available", else: "unavailable"),
      revert_reason: if(reversible, do: nil, else: "too_large")
    }
  end

  defp diff_stat(lines) when is_list(lines) do
    %{
      added: Enum.count(lines, &(&1["type"] == "ins")),
      removed: Enum.count(lines, &(&1["type"] == "del"))
    }
  end

  defp diff_stat(_lines), do: %{added: 0, removed: 0}

  defp snapshot_metadata_keys do
    [
      :change_id,
      :change_type,
      :file_path,
      :existed_before,
      :existed_after,
      :before_sha256,
      :after_sha256,
      :diff_stat,
      :reversible,
      :revert_status,
      :revert_reason
    ]
  end

  defp encode_snapshot(snapshot) do
    {:ok, Handbean.JSON.encode!(Handbean.JsonSafe.normalize(snapshot))}
  rescue
    error -> {:error, error}
  end

  defp encode_ref(conversation_id, change_id) do
    @ref_prefix <> Base.url_encode64(conversation_id <> <<0>> <> change_id, padding: false)
  end

  defp decode_ref(encoded) do
    with {:ok, decoded} <- Base.url_decode64(encoded, padding: false),
         [conversation_id, change_id] <- :binary.split(decoded, <<0>>, [:global]),
         true <- safe_id?(conversation_id) and safe_id?(change_id),
         true <- encode_ref(conversation_id, change_id) == @ref_prefix <> encoded do
      {:ok, conversation_id, change_id}
    else
      _ -> {:error, :invalid_snapshot_ref}
    end
  end

  defp conversation_id(context),
    do: Handbean.Utils.SafeMap.get_any(context, :conversation_id, "conversation_id")

  defp safe_id?(id) when is_binary(id) and id not in [".", ".."],
    do: Regex.match?(~r/\A[A-Za-z0-9_.:-]+\z/, id)

  defp safe_id?(_id), do: false

  @doc """
  Builds a line edit script with bounded alignment work.

  Common edges and single-sided changes are handled in linear time. Large
  unmatched regions are represented as a replacement, which is exact but may
  not be a minimal diff. Reversion always uses the full snapshot contents.
  """
  @spec line_diff(binary(), binary()) :: [{:eq | :del | :ins, [binary()]}]
  def line_diff(old, new) when is_binary(old) and is_binary(new) do
    {prefix, old_lines, new_lines} =
      split_common(String.split(old, "\n"), String.split(new, "\n"), [])

    {suffix, old_reversed, new_reversed} =
      split_common(Enum.reverse(old_lines), Enum.reverse(new_lines), [])

    chunks(:eq, Enum.reverse(prefix)) ++
      diff_middle(Enum.reverse(old_reversed), Enum.reverse(new_reversed)) ++
      chunks(:eq, suffix)
  end

  defp split_common([line | old], [line | new], common),
    do: split_common(old, new, [line | common])

  defp split_common(old, new, common), do: {common, old, new}

  defp diff_middle([], new), do: chunks(:ins, new)
  defp diff_middle(old, []), do: chunks(:del, old)

  defp diff_middle(old, new) do
    if length(old) + length(new) <= @max_myers_lines and
         line_bytes(old) + line_bytes(new) <= @max_myers_bytes do
      List.myers_difference(old, new)
    else
      [del: old, ins: new]
    end
  end

  defp line_bytes(lines), do: Enum.reduce(lines, 0, &(byte_size(&1) + &2))
  defp chunks(_type, []), do: []
  defp chunks(type, lines), do: [{type, lines}]

  defp clip_diff_context(diff) do
    change_indices =
      diff
      |> Enum.with_index()
      |> Enum.filter(fn {{type, _lines}, _i} -> type != :eq end)
      |> Enum.map(fn {_chunk, i} -> i end)

    if change_indices == [] do
      diff
    else
      first = hd(change_indices)
      last = List.last(change_indices)
      ctx = @diff_context_lines

      Enum.flat_map(Enum.with_index(diff), fn {{type, lines}, i} ->
        case type do
          :eq ->
            cond do
              i < first -> clip_before(lines, ctx)
              i > last -> clip_after(lines, ctx)
              true -> clip_middle(lines, ctx)
            end

          :del ->
            [{:del, lines}]

          :ins ->
            [{:ins, lines}]
        end
      end)
    end
  end

  defp clip_before(lines, ctx) when length(lines) <= ctx, do: [{:eq, lines}]

  defp clip_before(lines, ctx) do
    keep = Enum.take(lines, -ctx)
    skipped = length(lines) - ctx
    [{:skip, skipped}, {:eq, keep}]
  end

  defp clip_after(lines, ctx) when length(lines) <= ctx, do: [{:eq, lines}]

  defp clip_after(lines, ctx) do
    keep = Enum.take(lines, ctx)
    skipped = length(lines) - ctx
    [{:eq, keep}, {:skip, skipped}]
  end

  defp clip_middle(lines, ctx) when length(lines) <= ctx * 2, do: [{:eq, lines}]

  defp clip_middle(lines, ctx) do
    head = Enum.take(lines, ctx)
    tail = Enum.take(lines, -ctx)
    skipped = length(lines) - ctx * 2
    [{:eq, head}, {:skip, skipped}, {:eq, tail}]
  end
end
