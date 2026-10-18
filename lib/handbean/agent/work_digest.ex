defmodule Handbean.Agent.WorkDigest do
  @moduledoc """
  Hashes of files written during one run.

  Stores paths and content hashes only. ProgressGuard and Advisor share it.
  """

  def empty, do: %{files: %{}}

  def note(digest, path, content) when is_binary(path) and path != "" do
    hash = hash(content || "")
    history = Map.get(digest.files, path, [])
    %{digest | files: Map.put(digest.files, path, history ++ [hash])}
  end

  def note(digest, _path, _content), do: digest

  def history(digest, path), do: Map.get(digest.files, path, [])

  def changed?(digest), do: digest.files != %{}

  def returns(hashes) when is_list(hashes) do
    hashes
    |> Enum.with_index()
    |> Enum.count(fn {hash, index} ->
      earlier = Enum.take(hashes, index)
      hash in earlier and earlier != [] and List.last(earlier) != hash
    end)
  end

  def hash(content) do
    :crypto.hash(:sha256, to_string(content)) |> Base.encode16(case: :lower)
  end
end
