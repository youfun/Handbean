defmodule Handbean.Storage.ErrorClassifier do
  @moduledoc "Classifies SQLite failures without retaining SQL or database paths."

  @type category :: :busy | :full | :ioerr | :corrupt | :constraint | :unknown

  @spec classify(term()) :: category()
  def classify(error) do
    error
    |> message()
    |> String.downcase()
    |> classify_message()
  end

  defp classify_message(message) do
    cond do
      contains_any?(message, [
        "sqlite_busy",
        "sqlite_locked",
        "database is locked",
        "database is busy",
        "database busy"
      ]) ->
        :busy

      contains_any?(message, ["sqlite_full", "database or disk is full"]) ->
        :full

      contains_any?(message, ["sqlite_ioerr", "disk i/o error", "input/output error"]) ->
        :ioerr

      contains_any?(message, [
        "sqlite_corrupt",
        "sqlite_notadb",
        "database disk image is malformed",
        "file is not a database"
      ]) ->
        :corrupt

      String.contains?(message, "constraint failed") ->
        :constraint

      true ->
        :unknown
    end
  end

  defp message(%{message: message}) when is_binary(message), do: message
  defp message({:error, error}), do: message(error)
  defp message(error) when is_binary(error), do: error
  defp message(error), do: inspect(error)

  defp contains_any?(message, needles), do: Enum.any?(needles, &String.contains?(message, &1))
end
