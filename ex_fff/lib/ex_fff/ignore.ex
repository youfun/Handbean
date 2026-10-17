defmodule ExFff.Ignore do
  @moduledoc false

  defstruct rules: [], has_negation?: false

  @type rule :: %{regex: Regex.t(), ignored?: boolean()}
  @type t :: %__MODULE__{rules: [rule()], has_negation?: boolean()}

  @spec root(String.t()) :: t()
  def root(root) do
    extend(%__MODULE__{}, root, "")
  end

  @spec extend(t(), String.t(), String.t()) :: t()
  def extend(%__MODULE__{} = ignore, directory, relative_base) do
    rules =
      [".gitignore", ".handbeanignore"]
      |> Enum.flat_map(fn name -> read_rules(Path.join(directory, name), relative_base) end)

    %{
      ignore
      | rules: ignore.rules ++ rules,
        has_negation?: ignore.has_negation? or Enum.any?(rules, &(not &1.ignored?))
    }
  end

  @spec for_path(String.t(), String.t()) :: t()
  def for_path(root, relative) do
    directories =
      relative
      |> Path.dirname()
      |> ancestor_directories()

    Enum.reduce(directories, %__MODULE__{}, fn base, ignore ->
      directory = if base == "", do: root, else: Path.join(root, base)
      extend(ignore, directory, base)
    end)
  end

  @spec ignored?(t(), String.t()) :: boolean()
  def ignored?(%__MODULE__{rules: rules}, relative) do
    Enum.reduce(rules, false, fn rule, ignored ->
      if Regex.match?(rule.regex, normalize(relative)), do: rule.ignored?, else: ignored
    end)
  end

  @spec prune?(t(), String.t()) :: boolean()
  def prune?(%__MODULE__{has_negation?: true}, _relative), do: false
  def prune?(ignore, relative), do: ignored?(ignore, relative <> "/")

  defp read_rules(path, relative_base) do
    case File.read(path) do
      {:ok, body} -> parse(body, relative_base)
      {:error, _reason} -> []
    end
  end

  defp parse(body, relative_base) do
    body
    |> String.split(~r/\r?\n/, trim: false)
    |> Enum.flat_map(&parse_line(&1, relative_base))
  end

  defp parse_line(line, relative_base) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" or String.starts_with?(trimmed, "#") ->
        []

      true ->
        {ignored?, pattern} =
          if String.starts_with?(trimmed, "!") do
            {false, String.trim_leading(trimmed, "!")}
          else
            {true, trimmed}
          end

        case compile_rule(pattern, relative_base) do
          nil -> []
          regex -> [%{regex: regex, ignored?: ignored?}]
        end
    end
  end

  defp compile_rule(pattern, relative_base) do
    pattern = String.replace(pattern, "\\ ", " ")
    anchored? = String.starts_with?(pattern, "/")
    pattern = pattern |> String.trim_leading("/") |> String.trim_trailing("/")

    if pattern == "" do
      nil
    else
      base = normalize(relative_base)
      base_prefix = if base == "", do: "", else: Regex.escape(base) <> "/"
      body = glob_source(pattern)

      prefix =
        if anchored? or String.contains?(pattern, "/") do
          "^" <> base_prefix
        else
          "^" <> base_prefix <> "(?:.*/)?"
        end

      Regex.compile!(prefix <> body <> "(?:/.*)?$")
    end
  end

  defp glob_source(pattern),
    do: glob_source(String.graphemes(pattern), []) |> IO.iodata_to_binary()

  defp glob_source([], acc), do: Enum.reverse(acc)
  defp glob_source(["*", "*" | rest], acc), do: glob_source(rest, [".*" | acc])
  defp glob_source(["*" | rest], acc), do: glob_source(rest, ["[^/]*" | acc])
  defp glob_source(["?" | rest], acc), do: glob_source(rest, ["[^/]" | acc])
  defp glob_source([char | rest], acc), do: glob_source(rest, [Regex.escape(char) | acc])

  defp ancestor_directories("."), do: [""]

  defp ancestor_directories(path) do
    path
    |> Path.split()
    |> Enum.scan(fn segment, acc -> Path.join(acc, segment) end)
    |> then(&["" | &1])
  end

  defp normalize(path), do: path |> String.replace("\\", "/") |> String.trim("/")
end
