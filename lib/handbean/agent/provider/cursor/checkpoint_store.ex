defmodule Handbean.Agent.Provider.Cursor.CheckpointStore do
  @moduledoc """
  Durable Cursor protocol recovery data (checkpoint + blobs).

  This is not conversation history. `ConversationTranscriptStore` remains
  the user-visible source of truth. Files live under `~/.handbean/cursor-sessions/`.
  """

  @default_dir "~/.handbean/cursor-sessions"

  def load(conversation_id, opts \\ []) when is_binary(conversation_id) do
    path = file_path(conversation_id, opts)

    case File.read(path) do
      {:ok, bin} ->
        case safe_decode(bin) do
          {:ok, data} -> {:ok, data}
          :error -> :error
        end

      {:error, :enoent} ->
        :error

      {:error, _} ->
        :error
    end
  end

  def save(conversation_id, data, opts \\ []) when is_binary(conversation_id) and is_map(data) do
    path = file_path(conversation_id, opts)
    dir = Path.dirname(path)
    tmp = "#{path}.tmp.#{System.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700),
         :ok <-
           File.write(
             tmp,
             :erlang.term_to_binary(
               Map.take(data, [:checkpoint, :blobs, :cursor_conversation_id])
             )
           ),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, reason}
    end
  end

  def delete(conversation_id, opts \\ []) do
    File.rm(file_path(conversation_id, opts))
    :ok
  end

  defp file_path(conversation_id, opts) do
    dir =
      Keyword.get(opts, :dir) ||
        Application.get_env(:handbean, :cursor_session_dir) ||
        Handbean.Home.expand(@default_dir)

    Path.join(dir, "#{sanitize(conversation_id)}.bin")
  end

  defp sanitize(id), do: String.replace(id, ~r/[^A-Za-z0-9._-]/, "_")

  defp safe_decode(bin) do
    try do
      data = :erlang.binary_to_term(bin, [:safe])
      if is_map(data), do: {:ok, data}, else: :error
    rescue
      _ -> :error
    end
  end
end
