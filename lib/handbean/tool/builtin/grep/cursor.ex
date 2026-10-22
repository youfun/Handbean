defmodule Handbean.Tool.Builtin.Grep.Cursor do
  @moduledoc false

  @version 1

  @type t :: {String.t(), integer(), String.t(), String.t()}

  @spec encode(%{required(:path) => String.t(), required(:line) => integer()}, map(), String.t()) ::
          String.t()
  def encode(%{path: path, line: line}, input, workspace) do
    payload = {@version, path, line, query_key(input), workspace_key(workspace)}
    Base.url_encode64(:erlang.term_to_binary(payload), padding: false)
  end

  @spec decode(term(), map(), String.t()) :: t() | nil | :invalid
  def decode(cursor, _input, _workspace) when cursor in [nil, ""], do: nil

  def decode(cursor, input, workspace) when is_binary(cursor) do
    with {:ok, binary} <- Base.url_decode64(cursor, padding: false),
         {:ok, {@version, path, line, query, workspace_key}} <- cursor_term(binary),
         true <- is_binary(path) and is_integer(line) and query == query_key(input),
         true <- workspace_key == workspace_key(workspace) do
      {path, line, query, workspace_key}
    else
      _ -> :invalid
    end
  end

  def decode(_cursor, _input, _workspace), do: :invalid

  @spec after?(map(), t() | nil | :invalid) :: boolean()
  def after?(_hit, nil), do: true

  def after?(hit, {path, line, _query, _workspace}),
    do: {hit.path, hit.line} > {path, line}

  def after?(_hit, :invalid), do: false

  defp cursor_term(binary) do
    {:ok, :erlang.binary_to_term(binary, [:safe])}
  rescue
    ArgumentError -> :error
  end

  defp query_key(input) do
    :crypto.hash(
      :sha256,
      :erlang.term_to_binary({
        Handbean.Utils.SafeMap.get_any(input, ["pattern", :pattern]),
        Handbean.Utils.SafeMap.get_any(input, "path", :path),
        Handbean.Utils.SafeMap.get_any(input, "glob", :glob),
        Handbean.Utils.SafeMap.get_any(input, "literal", :literal),
        Handbean.Utils.SafeMap.get_any(input, "ignore_case", :ignore_case)
      })
    )
    |> Base.encode16(case: :lower)
  end

  defp workspace_key(workspace), do: Path.expand(workspace || "")
end
