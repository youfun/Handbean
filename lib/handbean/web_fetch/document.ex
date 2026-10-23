defmodule Handbean.WebFetch.Document do
  @moduledoc false

  @blocks ~w(p div section article main header footer blockquote ul ol table tr h1 h2 h3 h4 h5 h6)
  @discard "script, style, noscript, template, nav, aside, form, svg, head, [hidden], [aria-hidden=true]"

  def extract(body, headers, url, max_chars, opts \\ []) do
    content_type = header(headers, "content-type")

    type =
      content_type |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase()

    format = Handbean.Documents.format(type) || download_format(type, url)

    case format do
      nil ->
        with :ok <- supported_type(type),
             {:ok, body} <- decode(body, content_type),
             {:ok, title, text} <- render(body, type, url) do
          slice(text, %{title: title, content_type: type}, max_chars, opts)
        end

      format ->
        with {:ok, document} <- Handbean.Documents.extract(body, format, opts) do
          metadata = document |> Map.delete(:text) |> Map.merge(%{title: "", content_type: type})
          slice(document.text, metadata, max_chars, opts)
        end
    end
  end

  defp download_format(type, %URI{path: path})
       when type in ["application/octet-stream", "application/zip"],
       do: Handbean.Documents.format(path)

  defp download_format(_, _), do: nil

  defp slice(text, metadata, max_chars, opts) do
    offset = Keyword.get(opts, :offset, 0)
    total = String.length(text)

    if offset > total do
      {:error, "offset is beyond extracted document end (#{total} characters)"}
    else
      content = String.slice(text, offset, max_chars)
      next = offset + String.length(content)

      {:ok,
       Map.merge(metadata, %{
         content: content,
         truncated: next < total,
         offset: offset,
         next_offset: if(next < total, do: next),
         total_chars: total
       })}
    end
  end

  defp supported_type(type) when type in ["text/html", "application/xhtml+xml"], do: :ok
  defp supported_type("text/" <> _), do: :ok

  defp supported_type(_),
    do: {:error, "Unsupported or missing Content-Type; use browser for other formats"}

  defp decode(body, content_type) do
    charset =
      case Regex.run(~r/charset\s*=\s*["']?([^\s;"']+)/i, content_type) do
        [_, value] -> String.downcase(value)
        nil -> "utf-8"
      end

    cond do
      charset in ["iso-8859-1", "latin1", "latin-1"] ->
        {:ok, :unicode.characters_to_binary(body, :latin1, :utf8)}

      charset in ["utf-8", "utf8", "us-ascii", "ascii"] and String.valid?(body) ->
        {:ok, String.trim_leading(body, <<0xEF, 0xBB, 0xBF>>)}

      true ->
        {:error, "Unsupported charset or invalid text encoding (supported: UTF-8 and ISO-8859-1)"}
    end
  end

  defp render(body, type, url) when type in ["text/html", "application/xhtml+xml"] do
    with {:ok, tree} <-
           Floki.parse_document(preserve_whitespace(body), html_parser: Floki.HTMLParser.Mochiweb) do
      title =
        tree
        |> Floki.find("title")
        |> Floki.text()
        |> decode_title()
        |> decode_title()
        |> String.trim()
        |> String.slice(0, 500)

      tree = Floki.filter_out(tree, @discard)
      root = List.first(Floki.find(tree, "main, article"))
      nodes = if root, do: [root], else: tree
      text = nodes |> Enum.map(&render_node(&1, url)) |> IO.iodata_to_binary() |> String.trim()
      {:ok, title, text}
    else
      _ -> {:error, "HTML parsing failed"}
    end
  end

  defp render(body, _type, _url), do: {:ok, "", body}

  # Mochiweb's tree builder drops whitespace-only data tokens, including between
  # highlighted code spans. Its tokenizer retains them. Re-encode those tokens
  # as character references, which the tree builder preserves. Tokenize rather
  # than regex-rewriting HTML so quoted attributes and raw-text tags stay intact.
  defp preserve_whitespace(body) do
    body
    |> :floki_mochi_html.tokens()
    |> Enum.map(fn
      {:data, text, true} ->
        for <<char <- text>>, do: ["&#", Integer.to_string(char), ";"]

      {:data, text, false} ->
        escape(text)

      {:start_tag, tag, attrs, singleton} ->
        attrs = Enum.map(attrs, fn {key, value} -> [" ", key, "=\"", escape(value), "\""] end)
        ["<", tag, attrs, if(singleton, do: "/>", else: ">")]

      {:end_tag, tag} ->
        ["</", tag, ">"]

      _ ->
        ""
    end)
    |> IO.iodata_to_binary()
  end

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp decode_title(text) do
    Regex.replace(~r/&(?:#[xX][0-9a-fA-F]+|#\d+|[a-zA-Z][a-zA-Z0-9]+);/, text, fn entity ->
      case Floki.Entities.decode(entity) do
        {:ok, decoded} -> decoded
        {:error, _} -> entity
      end
    end)
  end

  defp render_node(text, _url) when is_binary(text), do: String.replace(text, ~r/\s+/u, " ")
  defp render_node({:comment, _}, _url), do: ""
  defp render_node({:doctype, _, _, _}, _url), do: ""
  defp render_node({:pi, _}, _url), do: ""
  defp render_node({:pi, _, _}, _url), do: ""

  defp render_node({"textarea", _, children}, _url),
    do: children |> Floki.text() |> decode_title() |> decode_title()

  defp render_node({"pre", _, children}, _url) do
    code = Floki.text(children, sep: "", deep: true)
    # A fence longer than every run in the source cannot be closed by its code.
    fence_size = Regex.scan(~r/`+/, code) |> Enum.reduce(2, fn [s], n -> max(n, byte_size(s)) end)
    fence = String.duplicate("`", fence_size + 1)
    ["\n\n", fence, "\n", code, "\n", fence, "\n\n"]
  end

  defp render_node({"a", attrs, children}, url) do
    label = Enum.map(children, &render_node(&1, url))

    case link(attrs, url) do
      nil -> label
      href -> [label, " (", href, ")"]
    end
  end

  defp render_node({"br", _, _}, _url), do: "\n"

  defp render_node({"li", _, children}, url),
    do: ["\n- ", Enum.map(children, &render_node(&1, url))]

  defp render_node({tag, _, children}, url) do
    content = Enum.map(children, &render_node(&1, url))
    if tag in @blocks, do: ["\n\n", content, "\n\n"], else: content
  end

  defp link(attrs, url) do
    with {"href", href} <- List.keyfind(attrs, "href", 0),
         {:ok, relative} <- URI.new(href),
         resolved <- URI.merge(url, relative),
         true <- resolved.scheme in ["http", "https"] and is_nil(resolved.userinfo) do
      URI.to_string(resolved)
    else
      _ -> nil
    end
  end

  defp header(headers, key), do: headers |> List.keyfind(key, 0, {key, ""}) |> elem(1)
end
