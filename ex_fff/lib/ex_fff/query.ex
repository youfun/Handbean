defmodule ExFff.Query do
  @moduledoc """
  Query parser for ExFff search expressions.

  Supports a compact search syntax:

  - `"schema"` — fuzzy match terms (AND semantics)
  - `"*.ex"` — include patterns (suffix fast path for a single extension)
  - `"*schedules*"` — basename glob (`*`, `?`, `**`); no `/` means match the file name only
  - `"desktop/macos **/*Conversation*"` — a glob containing `/` matches the full relative path
  - `"!test/"` — exclude patterns (paths containing substring)
  - `"user controller"` — multi-term AND search
  """

  defstruct terms: [],
            include_patterns: [],
            exclude_patterns: [],
            globs: [],
            limit: 20

  @type glob :: %{
          required(:regex) => Regex.t(),
          required(:basename?) => boolean(),
          optional(:pattern) => String.t(),
          optional(:path_fallback?) => boolean()
        }

  @type t :: %__MODULE__{
          terms: [String.t()],
          include_patterns: [String.t()],
          exclude_patterns: [String.t()],
          globs: [glob()],
          limit: pos_integer()
        }

  @doc """
  Parse a raw query string into a structured `ExFff.Query`.

  ## Examples

      iex> ExFff.Query.parse("schema")
      %ExFff.Query{terms: ["schema"], include_patterns: [], exclude_patterns: []}

      iex> ExFff.Query.parse("*.ex")
      %ExFff.Query{terms: [], include_patterns: [".ex"], exclude_patterns: []}

      iex> ExFff.Query.parse("user !test/")
      %ExFff.Query{terms: ["user"], include_patterns: [], exclude_patterns: ["test/"]}

      iex> ExFff.Query.parse("user controller *.ex !test/")
      %ExFff.Query{terms: ["user", "controller"], include_patterns: [".ex"], exclude_patterns: ["test/"]}

  """
  @spec parse(String.t()) :: t()
  def parse(string) when is_binary(string) do
    trimmed = String.trim(string)

    if trimmed == "" do
      %__MODULE__{limit: 0}
    else
      tokens = String.split(trimmed, ~r/\s+/)
      classify(tokens, %__MODULE__{})
    end
  end

  defp classify([], acc), do: acc

  defp classify([token | rest], acc) do
    acc =
      cond do
        String.starts_with?(token, "!") ->
          %{acc | exclude_patterns: acc.exclude_patterns ++ [String.trim_leading(token, "!")]}

        extension_glob?(token) ->
          ext = String.trim_leading(token, "*")
          %{acc | include_patterns: acc.include_patterns ++ [ext]}

        glob_token?(token) ->
          %{acc | globs: acc.globs ++ [compile_glob(token)]}

        true ->
          %{acc | terms: acc.terms ++ [token]}
      end

    classify(rest, acc)
  end

  # `*.ext` only — no extra glob metacharacters — keeps the suffix fast path.
  defp extension_glob?(token) do
    case String.split(token, ".", parts: 2) do
      ["*", ext] ->
        ext != "" and not String.contains?(ext, ["*", "?", "/"])

      _ ->
        false
    end
  end

  defp glob_token?(token) do
    String.contains?(token, ["*", "?"])
  end

  defp compile_glob(token) do
    source = "^" <> glob_source(token) <> "$"

    %{
      pattern: token,
      regex: Regex.compile!(source, [:caseless]),
      basename?: not String.contains?(token, "/")
    }
  end

  defp glob_source(pattern) do
    pattern
    |> String.graphemes()
    |> glob_source([])
    |> IO.iodata_to_binary()
  end

  defp glob_source([], acc), do: Enum.reverse(acc)
  defp glob_source(["*", "*" | rest], acc), do: glob_source(rest, [".*" | acc])
  defp glob_source(["*" | rest], acc), do: glob_source(rest, ["[^/]*" | acc])
  defp glob_source(["?" | rest], acc), do: glob_source(rest, ["[^/]" | acc])
  defp glob_source([char | rest], acc), do: glob_source(rest, [Regex.escape(char) | acc])
end
