defmodule Handbean.Memory.ObservationStore do
  @moduledoc """
  JSONL-based observation persistence.

  Stores observations per conversation in `~/.handbean/observations/<conversation_id>.jsonl`.
  Each line is a JSON object representing one Observation entry.

  This is a simple module (no GenServer) for Phase 0. Operations are
  append-only reads/writes with file-level locking via the BEAM's
  built-in file handle semantics.
  """

  alias Handbean.Memory.Observation

  require Logger

  @doc """
  Return the base directory for observation storage.
  """
  @spec base_dir() :: String.t()
  def base_dir, do: Handbean.Home.expand("~/.handbean/observations")

  @doc """
  Return the file path for a given conversation_id.
  """
  @spec file_path(String.t()) :: String.t()
  def file_path(conversation_id) when is_binary(conversation_id) do
    sanitized = sanitize_filename(conversation_id)
    Path.join(base_dir(), "#{sanitized}.jsonl")
  end

  @doc """
  Append an observation to the conversation's JSONL file.

  Returns `:ok` on success, `{:error, reason}` on failure.
  """
  @spec append(String.t(), Observation.t()) :: :ok | {:error, term()}
  def append(conversation_id, %Observation{} = obs) when is_binary(conversation_id) do
    path = file_path(conversation_id)

    with :ok <- ensure_dir(path),
         {:ok, json} <- Handbean.JSON.encode(Observation.to_map(obs)),
         :ok <- append_line(path, json) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("[OM.ObservationStore] Failed to append observation: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Load the most recent N observations for a conversation.

  Returns a list of Observation structs, newest first.
  """
  @spec load_recent(String.t(), non_neg_integer()) :: [Observation.t()]
  def load_recent(conversation_id, limit \\ 10) when is_binary(conversation_id) do
    path = file_path(conversation_id)

    case File.open(path, [:read, :utf8]) do
      {:ok, io} ->
        observations = read_reverse_lines(io, limit)
        File.close(io)
        observations

      {:error, :enoent} ->
        []

      {:error, reason} ->
        Logger.warning("[OM.ObservationStore] Failed to read observations: #{inspect(reason)}")
        []
    end
  end

  @doc """
  Count observations that have not yet been processed (reflected).

  Returns the count of observations where `metadata.reflected` is not `true`.
  """
  @spec count_unprocessed(String.t()) :: non_neg_integer()
  def count_unprocessed(conversation_id) when is_binary(conversation_id) do
    path = file_path(conversation_id)

    case File.open(path, [:read, :utf8]) do
      {:ok, io} ->
        count = count_unprocessed_lines(io)
        File.close(io)
        count

      {:error, :enoent} ->
        0

      {:error, _reason} ->
        0
    end
  end

  @doc """
  Mark observations as reflected by their IDs.

  This is a simple rewrite of the file — for Phase 0 with limited data,
  this is acceptable. Future phases can optimize with index files.
  """
  @spec mark_reflected(String.t(), [String.t()]) :: :ok | {:error, term()}
  def mark_reflected(conversation_id, observation_ids)
      when is_binary(conversation_id) and is_list(observation_ids) do
    path = file_path(conversation_id)
    id_set = MapSet.new(observation_ids)

    with {:ok, content} <- File.read(path) do
      updated_lines =
        content
        |> String.split("\n", trim: true)
        |> Enum.map(fn line ->
          case Handbean.JSON.decode(line) do
            {:ok, map} ->
              if MapSet.member?(id_set, map["id"]) do
                updated_meta = Map.put(map["metadata"] || %{}, "reflected", true)
                map |> Map.put("metadata", updated_meta) |> Handbean.JSON.encode!()
              else
                line
              end

            {:error, _} ->
              line
          end
        end)

      File.write!(path, Enum.join(updated_lines, "\n") <> "\n")
      :ok
    else
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    e ->
      Logger.error("[OM.ObservationStore] Failed to mark reflected: #{Exception.message(e)}")
      {:error, e}
  end

  @doc """
  Clean up old observations beyond a maximum count, keeping the most recent.
  """
  @spec trim(String.t(), non_neg_integer()) :: :ok | {:error, term()}
  def trim(conversation_id, max_entries \\ 10_000) when is_binary(conversation_id) do
    path = file_path(conversation_id)

    with {:ok, content} <- File.read(path) do
      lines = String.split(content, "\n", trim: true)

      if length(lines) > max_entries do
        kept = Enum.take(lines, -max_entries)
        File.write!(path, Enum.join(kept, "\n") <> "\n")
      end

      :ok
    else
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Private Helpers ──

  defp append_line(path, line) do
    case File.open(path, [:append, :utf8]) do
      {:ok, io} ->
        IO.puts(io, line)
        File.close(io)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_dir(path) do
    dir = Path.dirname(path)

    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Read lines from the end of the file (most recent first).
  # This is a simple implementation for Phase 0 — reads the whole file
  # into memory. For files with many observations, future phases can
  # optimize with tail-based reading.
  defp read_reverse_lines(io, limit) do
    lines =
      IO.stream(io, :line)
      |> Enum.to_list()

    lines
    |> Enum.reverse()
    |> Enum.take(limit)
    |> Enum.map(fn line ->
      case Handbean.JSON.decode(String.trim(line)) do
        {:ok, map} -> Observation.from_map(map)
        {:error, _} -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp count_unprocessed_lines(io) do
    IO.stream(io, :line)
    |> Enum.count(fn line ->
      case Handbean.JSON.decode(String.trim(line)) do
        {:ok, %{"metadata" => %{"reflected" => true}}} -> false
        {:ok, _} -> true
        {:error, _} -> false
      end
    end)
  end

  defp sanitize_filename(id) when is_binary(id) do
    id
    |> String.replace(~r/[^a-zA-Z0-9_-]/, "_")
    |> String.slice(0, 200)
  end
end
