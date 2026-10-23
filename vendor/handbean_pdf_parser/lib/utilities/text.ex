defmodule NativeElixirPdfUtilities.Text do
  @moduledoc """
  Strict native extraction of embedded Unicode text from PDF documents.

  Extraction resolves the PDF page tree, resources, content streams, Form
  XObjects, and the active font at every text operation. It succeeds only when
  every shown text string has a reliable Unicode mapping; it never guesses from
  an embedded font program or merges CMaps from unrelated fonts.

  PDFs store positioned text operations, not semantic rows, columns, or tables.
  `extract_spans/2` exposes those decoded operations for callers that need to
  interpret document-specific structure. `extract/2` remains a string
  projection: `layout: true` reconstructs approximate visual lines, while
  `layout: false` projects text-show execution order.

  Extraction does not perform OCR. Successfully decoded text can be recovered
  even when its rendering mode does not paint the text, but clipping paths,
  transparency, occlusion, and other causes of visual visibility are not
  evaluated.
  """

  alias NativeElixirPdfUtilities.Diagnostics
  alias NativeElixirPdfUtilities.Limits
  alias NativeElixirPdfUtilities.Pdf.Reader
  alias NativeElixirPdfUtilities.Validators.TextValidator

  @graphics_state_fields [
    :ctm,
    :font,
    :font_size,
    :char_spacing,
    :word_spacing,
    :horizontal_scale,
    :leading,
    :rise,
    :render_mode
  ]

  @typedoc "Options for reconstructed string extraction."
  @type extract_option :: {:layout, boolean()}
  @typedoc "Options for positioned span extraction."
  @type span_option :: {:order, :source | :visual}
  @typedoc "A PDF text rendering mode from 0 through 7."
  @type render_mode :: 0..7
  @typedoc "A six-value PDF affine matrix in `[a, b, c, d, e, f]` order."
  @type matrix :: [float()]

  @typedoc """
  A decoded text-showing operand and its positioned extraction context.

  `source_index` is zero-based within a page and follows text-show execution
  order. Page content streams are traversed in `/Contents` order, and Form
  XObjects are traversed where their `Do` operator occurs. Reusing a Form
  therefore produces new spans with new indexes.

  `x`, `y`, `end_x`, and `end_y` describe the text baseline in normalized
  display coordinates. The origin is the top-left of the rotated MediaBox, X
  increases rightward, Y increases downward, and page rotation and Form CTMs
  are applied. These points are not glyph bounding boxes. The end point uses
  the PDF font widths available to the extractor and can be approximate when a
  font omits explicit metrics.

  `text_matrix` is the PDF text matrix at the start of the operand. `ctm` is the
  active PDF current transformation matrix, including Form transforms. Neither
  matrix includes the final MediaBox/page-rotation normalization represented by
  the baseline coordinates.

  `font_resource` is the active PDF resource name, not a guaranteed font family
  or PostScript name. `font_size` is the `Tf` text-space size, not a calculated
  display-space height.

  `paints_text?` and `adds_to_clip_path?` are derived only from `render_mode`.
  They describe the requested PDF text rendering operation; they do not claim
  that the text is visually visible or clipped. `joins_previous?` identifies a
  text-showing operand that immediately continues the preceding operand without
  an intervening text-positioning, text-object, content-form, or graphics-matrix
  boundary. This follows PDF text-operator execution rather than inferring
  continuity from display coordinates.
  """
  @type text_span :: %{
          text: String.t(),
          source_index: non_neg_integer(),
          x: float(),
          y: float(),
          end_x: float(),
          end_y: float(),
          font_resource: String.t(),
          font_size: float(),
          text_matrix: matrix(),
          ctm: matrix(),
          render_mode: render_mode(),
          paints_text?: boolean(),
          adds_to_clip_path?: boolean(),
          joins_previous?: boolean()
        }

  @typedoc """
  Positioned text for one resolved PDF page.

  `media_box` is `[left, bottom, right, top]` in PDF default user-space units.
  `rotation` is the effective inherited page rotation normalized to 0, 90, 180,
  or 270 degrees. Every resolved page is returned, including pages whose
  `spans` list is empty.
  """
  @type text_page :: %{
          number: pos_integer(),
          media_box: [number()],
          rotation: 0 | 90 | 180 | 270,
          spans: [text_span()]
        }

  @typedoc "A page-preserving positioned-text extraction result."
  @type text_document :: %{
          page_count: non_neg_integer(),
          pages: [text_page()]
        }
  @type error_reason ::
          :encrypted_pdf
          | :invalid_options
          | :invalid_path
          | :invalid_pdf_input
          | :no_extractable_text
          | :resource_limit_exceeded
          | :unsupported_pdf_feature
          | :unsupported_text_encoding
          | File.posix()

  @doc """
  Extracts reliably decodable embedded text from a PDF binary.

  Set `layout: true` (the default) to group spans into approximate visual lines.
  With `layout: false`, spans retain their content-stream order. Extraction fails
  rather than returning partial text when a shown text operation cannot be
  decoded with the active font.
  """
  @spec extract(binary(), [extract_option()]) ::
          {:ok, String.t()} | {:error, {error_reason(), Diagnostics.diagnostic()}}
  def extract(pdf_binary, opts \\ []) do
    with {:ok, request} <- TextValidator.validate_request(pdf_binary, opts, :extract),
         {:ok, pdf_context} <- Reader.read_validated(request.pdf),
         {:ok, text_context} <- TextValidator.prepare(pdf_context),
         {:ok, pages} <- extract_pages(text_context) do
      visible_pages =
        pages
        |> Enum.map(fn page -> {page.number, Enum.filter(page.spans, & &1.paints_text?)} end)
        |> Enum.reject(fn {_page_number, spans} -> spans == [] end)

      case visible_pages do
        [] ->
          error(:text_extraction, :no_extractable_text, "PDF contains no extractable text")

        pages ->
          case request.options.layout do
            true ->
              projections = Enum.map(pages, &layout_page_projection/1)

              case TextValidator.validate_layout_whitespace(
                     Enum.map(projections, &{&1.page_number, &1.whitespace_bytes})
                   ) do
                :ok ->
                  {:ok, projections |> Enum.map(&render_layout_page/1) |> Enum.join("\f")}

                {:error, _} = projection_error ->
                  text_error(projection_error, :extract)
              end

            false ->
              {:ok,
               pages
               |> Enum.map(fn {_page_number, spans} -> plain_page(spans) end)
               |> Enum.join("\n")}
          end
      end
    else
      {:error, _} = extraction_error -> text_error(extraction_error, :extract)
    end
  end

  @doc """
  Extracts positioned, reliably decoded text spans from a PDF binary.

  The result preserves every resolved page and every non-empty text operand
  that can be decoded, including rendering modes 3 (neither painted nor added
  to the clipping path) and 7 (added to the clipping path without painting).
  This preservation guarantee applies to decoded text operations, not to OCR,
  undecodable fonts, glyph outlines, semantic tables, or evaluated visual
  visibility.

  Spans use source execution order by default. Set `order: :visual` to return a
  best-effort display ordering using the same line grouping as `extract/2`;
  `source_index` remains unchanged so source order can always be restored.

  A valid PDF with no decodable text returns an `:ok` document containing empty
  page span lists. Extraction remains strict and returns a structured error
  rather than a partial document when a shown string cannot be decoded.
  """
  @spec extract_spans(binary(), [span_option()]) ::
          {:ok, text_document()} | {:error, {error_reason(), Diagnostics.diagnostic()}}
  def extract_spans(pdf_binary, opts \\ []) do
    with {:ok, request} <- TextValidator.validate_request(pdf_binary, opts, :extract_spans),
         {:ok, pdf_context} <- Reader.read_validated(request.pdf),
         {:ok, text_context} <- TextValidator.prepare(pdf_context),
         {:ok, pages} <- extract_pages(text_context) do
      pages =
        if request.options.order == :visual do
          Enum.map(pages, fn page -> %{page | spans: visual_spans(page.spans)} end)
        else
          pages
        end

      {:ok, %{page_count: length(pages), pages: pages}}
    else
      {:error, _} = extraction_error -> text_error(extraction_error, :extract_spans)
    end
  end

  @doc """
  Reads a PDF file and extracts reliably decodable embedded text from it.
  """
  @spec extract_file(String.t(), [extract_option()]) ::
          {:ok, String.t()} | {:error, {error_reason(), Diagnostics.diagnostic()}}
  def extract_file(path, opts \\ []) do
    extract_file_with(path, opts, :extract_file, &extract/2)
  end

  @doc """
  Reads a PDF file and extracts its page-preserving positioned text spans.

  This has the same ordering, geometry, preservation, and strict diagnostic
  behavior as `extract_spans/2`. File extraction errors include the source path.
  """
  @spec extract_file_spans(String.t(), [span_option()]) ::
          {:ok, text_document()} | {:error, {error_reason(), Diagnostics.diagnostic()}}
  def extract_file_spans(path, opts \\ []) do
    extract_file_with(path, opts, :extract_file_spans, &extract_spans/2)
  end

  defp extract_file_with(path, opts, operation, extractor) do
    case TextValidator.validate_path(path, operation) do
      {:ok, path} ->
        case NativeElixirPdfUtilities.FileReader.read(path, Limits.get(:max_pdf_input_bytes)) do
          {:ok, pdf_binary} ->
            case extractor.(pdf_binary, opts) do
              {:ok, result} ->
                {:ok, result}

              {:error, {reason, diagnostic}} ->
                {:error,
                 {reason, diagnostic |> Map.put(:source, path) |> Map.put(:operation, operation)}}
            end

          {:error, {reason, diagnostic}} ->
            {:error,
             {reason,
              Diagnostics.with_context(diagnostic,
                operation: operation,
                module: __MODULE__,
                source: path
              )}}

          {:error, reason} ->
            error(:file, reason, "file read failed: #{reason}", operation: :read, source: path)
        end

      {:error, _} = path_error ->
        text_error(path_error, operation)
    end
  end

  defp extract_pages(text_context) do
    text_context.pages
    |> Enum.reduce_while({:ok, []}, fn page, {:ok, pages} ->
      case extract_page(page) do
        {:ok, page} -> {:cont, {:ok, [page | pages]}}
        {:error, _} = extraction_error -> {:halt, extraction_error}
      end
    end)
    |> case do
      {:ok, pages} -> {:ok, Enum.reverse(pages)}
      error -> error
    end
  end

  defp extract_page(page) do
    initial_state = text_state(page)

    Enum.reduce_while(page.contents, {:ok, initial_state, []}, fn operations,
                                                                  {:ok, state, spans} ->
      case interpret(operations, state, page.number) do
        {:ok, state, new_spans} ->
          {:cont, {:ok, state, Enum.reverse(new_spans, spans)}}

        {:error, {reason, diagnostic}} ->
          {:halt, {:error, {reason, with_debug_details(diagnostic, page: page.number)}}}
      end
    end)
    |> case do
      {:ok, _state, spans} ->
        {:ok,
         %{
           number: page.number,
           media_box: page.media_box,
           rotation: page.rotation,
           spans: Enum.reverse(spans)
         }}

      error ->
        error
    end
  end

  defp interpret(operations, state, page_number) do
    Enum.reduce_while(operations, {:ok, state, []}, fn operation, {:ok, state, spans} ->
      case apply_operator(operation, state, spans, page_number) do
        {:ok, state, spans} -> {:cont, {:ok, state, spans}}
        {:error, _} = extraction_error -> {:halt, extraction_error}
      end
    end)
    |> case do
      {:ok, state, spans} -> {:ok, state, Enum.reverse(spans)}
      {:error, _} = extraction_error -> extraction_error
    end
  end

  defp apply_operator(operation, state, spans, page) do
    operator = operation.operator
    operands = operation.operands

    case {operator, operands} do
      {"q", []} ->
        saved_state = Map.take(state, @graphics_state_fields)
        {:ok, %{state | stack: [saved_state | state.stack]}, spans}

      {"Q", []} ->
        [saved_state | stack] = state.stack

        restored_state =
          state
          |> Map.merge(saved_state)
          |> Map.put(:stack, stack)
          |> break_text_join()

        {:ok, restored_state, spans}

      {"cm", matrix} ->
        with {:ok, ctm} <- TextValidator.compose_matrix(matrix, state.ctm, page, "cm") do
          {:ok, state |> Map.put(:ctm, ctm) |> break_text_join(), spans}
        end

      {"BT", []} ->
        {:ok,
         %{
           state
           | in_text?: true,
             text_matrix: identity(),
             line_matrix: identity(),
             join_next_span?: false
         }, spans}

      {"ET", []} ->
        {:ok, %{state | in_text?: false, join_next_span?: false}, spans}

      {"Tf", [{:name, _font_name}, size]} ->
        {:ok, %{state | font: operation.font, font_size: size}, spans}

      {"gs", [{:name, _name}]} ->
        case operation do
          %{font: font, font_size: size} ->
            {:ok, %{state | font: font, font_size: size}, spans}

          _ ->
            {:ok, state, spans}
        end

      {"Tm", matrix} ->
        {:ok, %{state | text_matrix: matrix, line_matrix: matrix, join_next_span?: false}, spans}

      {operator, [tx, ty]} when operator in ["Td", "TD"] ->
        with {:ok, line_matrix} <-
               TextValidator.translate_matrix(state.line_matrix, tx, ty, page, operator) do
          state = %{
            state
            | line_matrix: line_matrix,
              text_matrix: line_matrix,
              leading: if(operator == "TD", do: -ty, else: state.leading),
              join_next_span?: false
          }

          {:ok, state, spans}
        end

      {"T*", []} ->
        with {:ok, line_matrix} <-
               TextValidator.translate_matrix(state.line_matrix, 0.0, -state.leading, page, "T*") do
          {:ok,
           %{state | line_matrix: line_matrix, text_matrix: line_matrix, join_next_span?: false},
           spans}
        end

      {"TL", [leading]} ->
        {:ok, %{state | leading: leading}, spans}

      {"Tc", [value]} ->
        {:ok, %{state | char_spacing: value}, spans}

      {"Tw", [value]} ->
        {:ok, %{state | word_spacing: value}, spans}

      {"Tz", [value]} ->
        {:ok, %{state | horizontal_scale: value}, spans}

      {"Tr", [mode]} ->
        {:ok, %{state | render_mode: mode}, spans}

      {"Ts", [value]} ->
        {:ok, %{state | rise: value}, spans}

      {"Tj", [_string]} ->
        show(state, spans, operation.decoded, page)

      {"TJ", [{:array, _values}]} ->
        show_array(operation.prepared_values, state, spans, page)

      {"'", [_string]} ->
        with {:ok, state, spans} <-
               apply_operator(%{operator: "T*", operands: []}, state, spans, page) do
          show(state, spans, operation.decoded, page)
        end

      {"\"", [word_spacing, char_spacing, _string]} ->
        state = %{state | word_spacing: word_spacing, char_spacing: char_spacing}

        with {:ok, state, spans} <-
               apply_operator(%{operator: "T*", operands: []}, state, spans, page) do
          show(state, spans, operation.decoded, page)
        end

      {"Do", [{:name, _name}]} ->
        state = break_text_join(state)

        with {:ok, state, spans} <- execute_form(operation.form, state, spans, page) do
          {:ok, break_text_join(state), spans}
        end

      _ ->
        {:ok, state, spans}
    end
  end

  defp break_text_join(state) do
    Map.put(state, :join_next_span?, false)
  end

  defp show(state, spans, decoded, page) do
    add_span(state, spans, decoded, page, state.join_next_span?)
  end

  defp show_array(values, state, spans, page) do
    values
    |> Enum.reduce_while(
      {:ok, state, spans, state.join_next_span?},
      fn value, {:ok, state, spans, joins_previous?} ->
        case value do
          {:adjustment, value} ->
            case TextValidator.adjust_text_matrix(state, value, page) do
              {:ok, matrix} ->
                {:cont, {:ok, %{state | text_matrix: matrix}, spans, joins_previous?}}

              {:error, _} = geometry_error ->
                {:halt, geometry_error}
            end

          {:text, decoded} ->
            case add_span(state, spans, decoded, page, joins_previous?) do
              {:ok, state, spans} ->
                {:cont, {:ok, state, spans, joins_previous? or decoded.text != ""}}

              {:error, _} = span_error ->
                {:halt, span_error}
            end
        end
      end
    )
    |> case do
      {:ok, state, spans, _shown?} -> {:ok, state, spans}
      {:error, _} = array_error -> array_error
    end
  end

  defp add_span(state, spans, decoded, page, join_previous?) do
    cond do
      decoded.text == "" ->
        {:ok, state, spans}

      state.next_source_index >= Limits.get(:max_text_spans) ->
        error(:limits, :resource_limit_exceeded, "text span count exceeds the limit", page: page)

      true ->
        with {:ok, geometry} <- TextValidator.span_geometry(state, decoded, page) do
          span = %{
            text: decoded.text,
            source_index: state.next_source_index,
            x: geometry.x,
            y: geometry.y,
            end_x: geometry.end_x,
            end_y: geometry.end_y,
            font_resource: state.font.name,
            font_size: state.font_size,
            text_matrix: state.text_matrix,
            ctm: state.ctm,
            render_mode: state.render_mode,
            paints_text?: state.render_mode not in [3, 7],
            adds_to_clip_path?: state.render_mode in 4..7,
            joins_previous?: join_previous?
          }

          {:ok,
           %{
             state
             | text_matrix: geometry.next_text_matrix,
               next_source_index: state.next_source_index + 1,
               join_next_span?: true
           }, [span | spans]}
        end
    end
  end

  defp execute_form(form, state, spans, page) do
    case form do
      nil ->
        {:ok, state, spans}

      form ->
        with {:ok, ctm} <-
               TextValidator.compose_matrix(form.matrix, state.ctm, page, "Do Form Matrix") do
          child_state = %{
            state
            | ctm: ctm,
              stack: [],
              in_text?: false,
              join_next_span?: false
          }

          with {:ok, child_state, child_spans} <- interpret(form.instructions, child_state, page) do
            {:ok, %{state | next_source_index: child_state.next_source_index},
             Enum.reverse(child_spans, spans)}
          end
        end
    end
  end

  defp plain_page(spans) do
    spans
    |> Enum.map_reduce(nil, fn span, previous_source_index ->
      joins_visible_previous? =
        span.joins_previous? and previous_source_index == span.source_index - 1

      separator = if is_nil(previous_source_index) or joins_visible_previous?, do: "", else: " "
      {[separator, span.text], span.source_index}
    end)
    |> elem(0)
    |> IO.iodata_to_binary()
  end

  defp layout_page_projection({page_number, spans}) do
    min_x = spans |> Enum.map(& &1.x) |> Enum.min()

    lines =
      spans
      |> Enum.sort_by(&{&1.y, &1.x})
      |> group_lines([])
      |> Enum.map(fn line -> line.spans |> Enum.sort_by(& &1.x) |> project_line(min_x) end)

    %{
      page_number: page_number,
      lines: lines,
      whitespace_bytes: Enum.sum(Enum.map(lines, & &1.whitespace_bytes))
    }
  end

  defp render_layout_page(projection) do
    projection.lines
    |> Enum.map(fn line ->
      line.parts
      |> Enum.map(fn {spaces, text} -> [String.duplicate(" ", spaces), text] end)
      |> IO.iodata_to_binary()
      |> String.trim_trailing()
    end)
    |> Enum.join("\n")
  end

  defp visual_spans(spans) do
    spans
    |> Enum.sort_by(&{&1.y, &1.x})
    |> group_lines([])
    |> Enum.flat_map(fn line -> Enum.sort_by(line.spans, & &1.x) end)
  end

  defp group_lines(spans, lines) do
    case spans do
      [] ->
        Enum.reverse(lines)

      [span | rest] ->
        case lines do
          [%{y: y, font_size: font_size, spans: line_spans} = line | previous]
          when abs(span.y - y) <= 1.5 ->
            updated = %{
              line
              | spans: [span | line_spans],
                font_size: max(font_size, span.font_size)
            }

            group_lines(rest, [updated | previous])

          _ ->
            group_lines(
              rest,
              [%{y: span.y, font_size: span.font_size, spans: [span]} | lines]
            )
        end
    end
  end

  defp project_line(spans, min_x) do
    {parts, _current_x, _first?, whitespace_bytes} =
      Enum.reduce(spans, {[], min_x, true, 0}, fn span,
                                                  {parts, current_x, first?, whitespace_bytes} ->
        space_width = max(span.font_size * 0.25, 4.0)
        gap = span.x - current_x

        spaces =
          cond do
            first? -> max(round((span.x - min_x) / space_width), 0)
            gap > space_width * 0.35 -> max(round(gap / space_width), 1)
            true -> 0
          end

        {[{spaces, span.text} | parts], max(span.end_x, span.x), false, whitespace_bytes + spaces}
      end)

    %{parts: Enum.reverse(parts), whitespace_bytes: whitespace_bytes}
  end

  defp text_state(page) do
    %{
      ctm: identity(),
      text_matrix: identity(),
      line_matrix: identity(),
      font: nil,
      font_size: 0.0,
      char_spacing: 0.0,
      word_spacing: 0.0,
      horizontal_scale: 100.0,
      leading: 0.0,
      rise: 0.0,
      render_mode: 0,
      in_text?: false,
      join_next_span?: false,
      stack: [],
      next_source_index: 0,
      rotation: page.rotation,
      page: %{media_box: page.media_box, rotation: page.rotation}
    }
  end

  defp identity, do: [1.0, 0.0, 0.0, 1.0, 0.0, 0.0]

  defp text_error({:error, {reason, diagnostic}}, operation) do
    {:error,
     {reason, diagnostic |> Map.put(:operation, operation) |> Map.put(:module, __MODULE__)}}
  end

  defp error(stage, reason, message, details \\ []) do
    {pdf_details, diagnostic_options} = Keyword.split(details, [:page])

    {:error, {reason, diagnostic}} =
      Diagnostics.error(
        stage,
        reason,
        message,
        Keyword.merge([operation: :extract, module: __MODULE__], diagnostic_options)
      )

    {:error, {reason, with_debug_details(diagnostic, pdf_details)}}
  end

  defp with_debug_details(diagnostic, details) do
    message =
      Enum.reduce(details, diagnostic.message, fn detail, message ->
        case detail do
          {:page, page} ->
            "#{message}; page #{page}"
        end
      end)

    Map.put(diagnostic, :message, message)
  end
end
