defmodule Handbean.Documents.Office do
  @moduledoc false

  alias Handbean.Documents.{Archive, XML}

  @relationships [
    "http://schemas.openxmlformats.org/officeDocument/2006/relationships/",
    "http://purl.oclc.org/ooxml/officeDocument/relationships/"
  ]

  def extract(bytes, format) do
    with {:ok, archive} <- Archive.open(bytes),
         {:ok, parts} <- xml_parts(archive),
         {:ok, main} <- related(parts, "", "officeDocument"),
         {:ok, root} <- part(parts, main),
         {:ok, lines, warnings} <- render(format, root, main, parts) do
      text = Enum.join(lines, "\n")

      if byte_size(text) <= 2 * 1024 * 1024 do
        {:ok, %{format: format, text: text, warnings: warnings}}
      else
        {:error, "Extracted document exceeds the 2 MiB text limit"}
      end
    end
  end

  defp xml_parts(archive) do
    archive.entries
    |> Map.keys()
    |> Enum.filter(&String.ends_with?(&1, [".xml", ".rels"]))
    |> Enum.reduce_while({:ok, %{}}, fn name, {:ok, parts} ->
      with {:ok, bytes} <- Archive.fetch(archive, name),
           {:ok, node} <- XML.parse(bytes) do
        {:cont, {:ok, Map.put(parts, name, node)}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp render(:docx, {"document", _, _} = root, _main, _parts) do
    root
    |> XML.descendants("body")
    |> Enum.flat_map(&document_blocks/1)
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, [], 0}, fn {text, index}, {:ok, groups, used} ->
      case label_lines(text, "Paragraph #{index}", 2 * 1024 * 1024 - used) do
        {:ok, lines, size} -> {:cont, {:ok, [lines | groups], used + size + 1}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, groups, _} ->
        {:ok, groups |> Enum.reverse() |> List.flatten(),
         [
           "DOCX body paragraph/table text only; headers, footers, printed page numbers and layout are not available."
         ]}

      error ->
        error
    end
  end

  defp render(:pptx, {"presentation", _, _} = root, main, parts) do
    root
    |> XML.descendants("sldId")
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, [], 0}, fn {slide, index}, {:ok, sections, used} ->
      with {:ok, target} <- related(parts, main, "slide", XML.relationship_id(slide)),
           {:ok, node} <- part(parts, target),
           text <- node |> XML.descendants("p") |> Enum.map_join("\n", &paragraph/1),
           {:ok, lines, size} <- label_lines(text, "Slide #{index}", 2 * 1024 * 1024 - used) do
        {:cont, {:ok, [Enum.join(lines, "\n") | sections], used + size + 1}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, sections, _} ->
        {:ok, Enum.reverse(sections),
         ["Slide text only; charts, images and speaker notes are not rendered."]}

      error ->
        error
    end
  end

  defp render(:xlsx, {"workbook", _, _} = root, main, parts) do
    with {:ok, shared} <- shared_strings(parts, main) do
      root
      |> XML.descendants("sheet")
      |> Enum.reduce_while({:ok, [], 0}, fn sheet, {:ok, sections, used} ->
        with {:ok, target} <- related(parts, main, "worksheet", XML.relationship_id(sheet)),
             {:ok, node} <- part(parts, target),
             {:ok, text} <- worksheet(node, shared),
             label <- XML.attr(sheet, "name") || "Unnamed",
             {:ok, lines, size} <-
               label_lines(
                 text,
                 "Sheet #{inspect(label, printable_limit: :infinity)}",
                 2 * 1024 * 1024 - used
               ) do
          {:cont, {:ok, [Enum.join(lines, "\n") | sections], used + size + 1}}
        else
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, sections, _} ->
          {:ok, Enum.reverse(sections),
           [
             "XLSX cells use stored values; formulas are not evaluated. Dates may be numeric serials; formatting, charts and hidden-state filtering are not applied."
           ]}

        error ->
          error
      end
    end
  end

  defp render(_, _, _, _),
    do: {:error, "Office package does not match its declared document format"}

  defp document_blocks(node) do
    Enum.flat_map(XML.children(node), fn
      {"p", _, _} = p ->
        [paragraph(p)]

      {"tbl", _, _} = table ->
        Enum.map(XML.children(table, "tr"), fn row ->
          row
          |> XML.children("tc")
          |> Enum.map_join("\t", &(document_blocks(&1) |> Enum.join(" | ")))
        end)

      child ->
        document_blocks(child)
    end)
  end

  defp paragraph({"t", _, _} = node), do: XML.text(node)
  defp paragraph({"tab", _, _}), do: "\t"
  defp paragraph({name, _, _}) when name in ["br", "cr"], do: "\n"
  defp paragraph(node), do: node |> XML.children() |> Enum.map_join(&paragraph/1)

  defp shared_strings(parts, main) do
    case related(parts, main, "sharedStrings") do
      {:ok, target} ->
        with {:ok, root} <- part(parts, target) do
          strings = root |> XML.children("si") |> Enum.map(&paragraph/1)
          {:ok, List.to_tuple(strings)}
        end

      {:error, :missing_relationship} ->
        {:ok, {}}

      error ->
        error
    end
  end

  defp worksheet(root, shared) do
    root
    |> XML.descendants("row")
    |> Enum.reduce_while({:ok, [], 0}, fn row, {:ok, rows, used} ->
      case cells(XML.children(row, "c"), shared) do
        {:ok, cells} ->
          text = "[Row #{XML.attr(row, "r") || "?"}] " <> Enum.join(cells, " | ")
          used = used + byte_size(text)

          if used <= 2 * 1024 * 1024,
            do: {:cont, {:ok, [text | rows], used}},
            else: {:halt, {:error, "Extracted document exceeds the 2 MiB text limit"}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, rows, _} -> {:ok, rows |> Enum.reverse() |> Enum.join("\n")}
      error -> error
    end
  end

  defp cells(nodes, shared) do
    Enum.reduce_while(nodes, {:ok, [], 0}, fn node, {:ok, values, used} ->
      case cell(node, shared) do
        {:ok, value} when byte_size(value) + used <= 2 * 1024 * 1024 ->
          rendered = "#{XML.attr(node, "r") || "?"}=#{inspect(value, printable_limit: :infinity)}"
          used = used + byte_size(rendered)

          if used <= 2 * 1024 * 1024,
            do: {:cont, {:ok, [rendered | values], used}},
            else: {:halt, {:error, "Extracted document exceeds the 2 MiB text limit"}}

        {:ok, _value} ->
          {:halt, {:error, "Extracted document exceeds the 2 MiB text limit"}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, values, _} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp cell(node, shared) do
    value = node |> XML.children("v") |> Enum.map_join(&XML.text/1)

    case XML.attr(node, "t") do
      "s" ->
        case Integer.parse(value) do
          {index, ""} when index >= 0 and index < tuple_size(shared) -> {:ok, elem(shared, index)}
          _ -> {:error, "Invalid XLSX shared-string reference"}
        end

      "inlineStr" ->
        {:ok, paragraph(node)}

      _ ->
        formula = node |> XML.children("f") |> Enum.map_join(&XML.text/1)
        {:ok, if(value == "" and formula != "", do: "=#{formula} [no cached value]", else: value)}
    end
  end

  defp related(parts, source, type, id \\ nil) do
    case type do
      "slide" when is_nil(id) -> {:error, "Missing Office relationship id"}
      "worksheet" when is_nil(id) -> {:error, "Missing Office relationship id"}
      _ -> do_related(parts, source, type, id)
    end
  end

  defp do_related(parts, source, type, id) do
    rels =
      if source == "",
        do: "_rels/.rels",
        else: Path.join([Path.dirname(source), "_rels", Path.basename(source) <> ".rels"])

    with {:ok, root} <- part(parts, rels) do
      matches =
        root
        |> XML.children("Relationship")
        |> Enum.filter(fn rel ->
          XML.attr(rel, "Type") in Enum.map(@relationships, &(&1 <> type)) and
            (is_nil(id) or XML.attr(rel, "Id") == id)
        end)

      case matches do
        [] ->
          {:error, :missing_relationship}

        [rel] ->
          if XML.attr(rel, "TargetMode") in [nil, "Internal"],
            do: target(source, XML.attr(rel, "Target")),
            else: {:error, "External Office relationships are not followed"}

        _ ->
          {:error, "Ambiguous Office relationships"}
      end
    end
  end

  defp target(source, value) when is_binary(value) do
    with {:ok, uri} <- URI.new(value),
         true <-
           is_nil(uri.scheme) and is_nil(uri.host) and is_nil(uri.query) and is_nil(uri.fragment),
         path when is_binary(path) <- uri.path,
         true <- not String.contains?(path, ["\\", "%", <<0>>]) do
      base =
        if String.starts_with?(path, "/"),
          do: [],
          else:
            source |> Path.dirname() |> String.split("/", trim: true) |> Enum.reject(&(&1 == "."))

      normalize_target(base, String.split(path, "/", trim: true))
    else
      _ -> {:error, "Invalid Office relationship target"}
    end
  end

  defp target(_, _), do: {:error, "Invalid Office relationship target"}
  defp normalize_target(parts, []), do: {:ok, Enum.join(parts, "/")}
  defp normalize_target(parts, ["." | rest]), do: normalize_target(parts, rest)
  defp normalize_target([], [".." | _]), do: {:error, "Office relationship escapes the package"}
  defp normalize_target(parts, [".." | rest]), do: normalize_target(Enum.drop(parts, -1), rest)
  defp normalize_target(parts, [part | rest]), do: normalize_target(parts ++ [part], rest)

  defp label_lines(text, label, remaining) do
    text = if text == "", do: "No extractable text", else: text
    lines = String.split(text, "\n")
    prefix = "[#{label}] "
    size = byte_size(text) + length(lines) * byte_size(prefix)

    if size <= remaining,
      do: {:ok, Enum.map(lines, &(prefix <> &1)), size},
      else: {:error, "Extracted document exceeds the 2 MiB text limit"}
  end

  defp part(parts, name) do
    case Map.fetch(parts, name) do
      {:ok, node} -> {:ok, node}
      :error -> {:error, "Missing Office XML part: #{name}"}
    end
  end
end
