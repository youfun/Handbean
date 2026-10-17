defmodule Handbean.BrowserAnnotation do
  @moduledoc """
  Annotation payload shared by the desktop browser panel.

  `from_untrusted/1` rebuilds every field from page output. Unknown keys are
  dropped. `format_prompt/1` is the markdown block written into the composer
  draft. With a screenshot the numbered markers locate each element, so the
  prompt omits rects. Without one, each mark keeps the viewport rect measured
  at capture time.
  """

  alias Handbean.Browser.Policy

  @selector_max 500
  @tag_max 32
  @text_max 240
  @comment_max 1_000
  @file_max 300
  @url_max 2_000
  @title_max 300
  @captured_max 40
  @element_max 20
  @coord_max 100_000

  @type source :: %{
          required(:file) => String.t(),
          required(:line) => pos_integer(),
          optional(:column) => pos_integer()
        }
  @type rect :: %{
          required(:x) => number(),
          required(:y) => number(),
          required(:width) => number(),
          required(:height) => number()
        }
  @type element :: %{
          required(:index) => pos_integer(),
          required(:selector) => String.t(),
          required(:tag) => String.t(),
          required(:text) => String.t() | nil,
          required(:rect) => rect(),
          required(:source) => source() | nil,
          required(:comment) => String.t() | nil
        }
  @type t :: %{
          required(:url) => String.t(),
          required(:title) => String.t() | nil,
          required(:viewport) => %{
            required(:width) => number(),
            required(:height) => number(),
            required(:dpr) => number()
          },
          required(:elements) => [element()],
          required(:captured_at) => String.t(),
          required(:screenshot) => boolean()
        }

  @doc """
  Rebuild a payload from untrusted input.

  Returns `{:error, :invalid_url}` when the URL is missing or not http(s),
  and `{:error, :invalid_payload}` when the value is not a map.
  """
  @spec from_untrusted(term()) :: {:ok, t()} | {:error, :invalid_url | :invalid_payload}
  def from_untrusted(input) when is_map(input) do
    url = field(input, "url")

    if valid_url?(url) do
      {:ok,
       %{
         url: String.trim(url),
         title: optional_line(field(input, "title"), @title_max),
         viewport: viewport(field(input, "viewport")),
         elements: elements(field(input, "elements")),
         captured_at: captured_at(field(input, "captured_at") || field(input, "capturedAt")),
         screenshot: field(input, "screenshot") == true
       }}
    else
      {:error, :invalid_url}
    end
  end

  def from_untrusted(_), do: {:error, :invalid_payload}

  @doc "Markdown appended to the current composer draft."
  @spec format_prompt(t()) :: String.t()
  def format_prompt(payload) when is_map(payload) do
    screenshot? = payload.screenshot == true

    lines = [
      heading(screenshot?),
      "",
      "- URL: #{payload.url}"
    ]

    lines =
      if present?(payload.title),
        do: lines ++ ["- Title: #{one_line(payload.title)}"],
        else: lines

    lines =
      lines ++
        [
          "- Viewport: #{format_viewport(payload.viewport)}",
          "- Captured: #{one_line(payload.captured_at)}"
        ]

    lines =
      Enum.reduce(payload.elements, lines, fn element, acc ->
        acc ++ element_lines(element, screenshot?)
      end)

    Enum.join(lines, "\n")
  end

  defp heading(true) do
    "Browser annotations from the embedded preview — the attached screenshot shows the same numbered markers."
  end

  defp heading(false) do
    "Browser annotations from the embedded preview — no screenshot could be taken, so each mark carries its viewport rect instead."
  end

  defp element_lines(element, screenshot?) do
    comment = if present?(element.comment), do: one_line(element.comment), else: "(no comment)"

    lines = [
      "",
      "##{element.index} `#{one_line(element.selector)}` (#{one_line(element.tag)}) — #{comment}"
    ]

    lines =
      if screenshot?, do: lines, else: lines ++ ["  - rect: #{format_rect(element.rect)}"]

    lines =
      if present?(element.text),
        do: lines ++ ["  - text: \"#{one_line(element.text)}\""],
        else: lines

    if element.source,
      do: lines ++ ["  - source: `#{format_source(element.source)}`"],
      else: lines
  end

  defp format_viewport(%{width: width, height: height, dpr: dpr}) do
    "#{format_num(width)}×#{format_num(height)} @#{format_num(dpr)}x"
  end

  defp format_rect(%{x: x, y: y, width: width, height: height}) do
    "#{format_num(width)}×#{format_num(height)} at (#{format_num(x)}, #{format_num(y)})"
  end

  defp format_source(%{file: file, line: line} = source) do
    base = "#{one_line(file)}:#{line}"
    if is_integer(source[:column]), do: base <> ":#{source.column}", else: base
  end

  defp elements(list) when is_list(list) do
    list
    |> Enum.reduce([], fn item, acc ->
      case element(item) do
        {:ok, built} -> [built | acc]
        :drop -> acc
      end
    end)
    |> Enum.reverse()
    |> Enum.take(@element_max)
    |> Enum.with_index(1)
    |> Enum.map(fn {built, index} -> %{built | index: index} end)
  end

  defp elements(_), do: []

  defp element(input) when is_map(input) do
    with selector when is_binary(selector) <-
           optional_line(field(input, "selector"), @selector_max),
         tag when is_binary(tag) <- optional_line(field(input, "tag"), @tag_max),
         {:ok, rect} <- rect(field(input, "rect")) do
      {:ok,
       %{
         index: 0,
         selector: selector,
         tag: tag,
         text: optional_line(field(input, "text"), @text_max),
         rect: rect,
         source: source(field(input, "source")),
         comment: optional_line(field(input, "comment"), @comment_max)
       }}
    else
      _ -> :drop
    end
  end

  defp element(_), do: :drop

  defp rect(input) when is_map(input) do
    with {:ok, x} <- coord(field(input, "x")),
         {:ok, y} <- coord(field(input, "y")),
         {:ok, width} <- coord(field(input, "width")),
         {:ok, height} <- coord(field(input, "height")) do
      {:ok, %{x: x, y: y, width: width, height: height}}
    else
      _ -> :error
    end
  end

  defp rect(_), do: :error

  defp coord(value) when is_integer(value) and value >= 0 and value <= @coord_max,
    do: {:ok, value}

  defp coord(value) when is_float(value) and value >= 0 and value <= @coord_max do
    if value == value, do: {:ok, value}, else: :error
  end

  defp coord(_), do: :error

  defp source(input) when is_map(input) do
    file = optional_line(field(input, "file"), @file_max)
    line = positive_int(field(input, "line"))

    if is_binary(file) and is_integer(line) do
      built = %{file: file, line: line}

      case positive_int(field(input, "column")) do
        column when is_integer(column) -> Map.put(built, :column, column)
        _ -> built
      end
    end
  end

  defp source(_), do: nil

  defp viewport(input) when is_map(input) do
    %{
      width: positive_number(field(input, "width"), 1280),
      height: positive_number(field(input, "height"), 720),
      dpr: positive_number(field(input, "dpr"), 1)
    }
  end

  defp viewport(_), do: %{width: 1280, height: 720, dpr: 1}

  defp positive_number(value, _default)
       when is_integer(value) and value > 0 and value <= @coord_max,
       do: value

  defp positive_number(value, _default)
       when is_float(value) and value > 0 and value <= @coord_max,
       do: value

  defp positive_number(_, default), do: default

  defp positive_int(value) when is_integer(value) and value > 0 and value <= @coord_max, do: value

  defp positive_int(value) when is_float(value) and value > 0 and value == trunc(value) do
    truncated = trunc(value)
    if truncated <= @coord_max, do: truncated
  end

  defp positive_int(_), do: nil

  defp captured_at(value) do
    case optional_line(value, @captured_max) do
      text when is_binary(text) -> text
      _ -> DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    end
  end

  defp valid_url?(url) when is_binary(url) do
    trimmed = String.trim(url)

    trimmed == url and trimmed != "" and String.length(trimmed) <= @url_max and
      not String.contains?(trimmed, ["\n", "\r", " ", "\t"]) and
      Policy.allowed_navigation_url?(trimmed)
  end

  defp valid_url?(_), do: false

  defp optional_line(value, max) when is_binary(value) do
    case one_line(value, max) do
      "" -> nil
      text -> text
    end
  end

  defp optional_line(_, _), do: nil

  defp one_line(value, max \\ 10_000) do
    value
    |> to_string()
    |> String.replace(~r/[\r\n]+/, " ")
    |> String.replace("`", "'")
    |> String.trim()
    |> String.slice(0, max)
  end

  defp present?(value), do: is_binary(value) and value != ""

  defp format_num(value) when is_integer(value), do: Integer.to_string(value)

  defp format_num(value) when is_float(value) do
    if value == trunc(value) do
      Integer.to_string(trunc(value))
    else
      :erlang.float_to_binary(value, [:compact, decimals: 4])
    end
  end

  defp field(map, key) when is_binary(key) do
    Map.get(map, key) || Map.get(map, atom_key(key))
  end

  defp atom_key("url"), do: :url
  defp atom_key("title"), do: :title
  defp atom_key("viewport"), do: :viewport
  defp atom_key("elements"), do: :elements
  defp atom_key("captured_at"), do: :captured_at
  defp atom_key("capturedAt"), do: :captured_at
  defp atom_key("screenshot"), do: :screenshot
  defp atom_key("selector"), do: :selector
  defp atom_key("tag"), do: :tag
  defp atom_key("text"), do: :text
  defp atom_key("rect"), do: :rect
  defp atom_key("source"), do: :source
  defp atom_key("comment"), do: :comment
  defp atom_key("file"), do: :file
  defp atom_key("line"), do: :line
  defp atom_key("column"), do: :column
  defp atom_key("x"), do: :x
  defp atom_key("y"), do: :y
  defp atom_key("width"), do: :width
  defp atom_key("height"), do: :height
  defp atom_key("dpr"), do: :dpr
  defp atom_key(_), do: nil
end
