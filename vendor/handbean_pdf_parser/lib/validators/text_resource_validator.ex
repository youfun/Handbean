defmodule NativeElixirPdfUtilities.Validators.TextResourceValidator do
  @moduledoc false

  alias NativeElixirPdfUtilities.Diagnostics
  alias NativeElixirPdfUtilities.Limits
  alias NativeElixirPdfUtilities.Pdf.Reader
  alias NativeElixirPdfUtilities.Pdf.TextEncoding
  alias NativeElixirPdfUtilities.Validators.PdfValidator
  alias NativeElixirPdfUtilities.Validators.TextValidator
  import Bitwise

  @max_cid 65_535
  @unicode_mapping_section ~r/(\d+)\s+begin(bfchar|bfrange)\s*.*?\s*end\2/s
  @codespace_section ~r/(\d+)\s+begincodespacerange\s*(.*?)\s*endcodespacerange/s
  @cid_mapping_section ~r/(\d+)\s+begin(cidchar|cidrange|notdefchar|notdefrange)\s*.*?\s*end\2/s

  @doc """
  Prepares reachable fonts, strings, and Form XObjects for text execution.
  """
  @spec prepare_contents(map(), term(), [[TextValidator.instruction()]], pos_integer()) ::
          {:ok, [[map()]]} | {:error, {atom(), Diagnostics.diagnostic()}}
  def prepare_contents(document, resources, contents, page_number) do
    case prepare_contents(
           document,
           resources,
           contents,
           page_number,
           TextValidator.new_preparation_context()
         ) do
      {:ok, contents, _preparation_context} -> {:ok, contents}
      {:error, _} = preparation_error -> preparation_error
    end
  end

  @doc false
  @spec prepare_contents(
          map(),
          term(),
          [[TextValidator.instruction()]],
          pos_integer(),
          TextValidator.preparation_context()
        ) ::
          {:ok, [[map()]], TextValidator.preparation_context()}
          | {:error, {atom(), Diagnostics.diagnostic()}}
  def prepare_contents(document, resources, contents, page_number, preparation_context) do
    contents
    |> Enum.reduce_while(
      {:ok, [], %{font: nil, stack: [], preparation: preparation_context}},
      fn instructions, {:ok, prepared, state} ->
        case prepare_instructions(
               instructions,
               document,
               resources,
               state,
               page_number,
               0
             ) do
          {:ok, instructions, state} ->
            {:cont, {:ok, [instructions | prepared], state}}

          {:error, _} = preparation_error ->
            {:halt, preparation_error}
        end
      end
    )
    |> case do
      {:ok, prepared, state} ->
        {:ok, Enum.reverse(prepared), state.preparation}

      {:error, {reason, diagnostic}} ->
        {:error, {reason, with_debug_details(diagnostic, page: page_number)}}
    end
  end

  defp prepare_instructions(instructions, document, resources, state, page, depth) do
    instructions
    |> Enum.reduce_while({:ok, [], state}, fn instruction, {:ok, prepared, state} ->
      case prepare_instruction(instruction, document, resources, state, page, depth) do
        {:ok, instruction, state} -> {:cont, {:ok, [instruction | prepared], state}}
        {:error, _} = preparation_error -> {:halt, preparation_error}
      end
    end)
    |> case do
      {:ok, prepared, state} -> {:ok, Enum.reverse(prepared), state}
      {:error, _} = preparation_error -> preparation_error
    end
  end

  defp prepare_instruction(instruction, document, resources, state, page, depth) do
    case instruction do
      %{operator: "q"} ->
        {:ok, instruction, %{state | stack: [state.font | state.stack]}}

      %{operator: "Q"} ->
        [font | stack] = state.stack
        {:ok, instruction, %{state | font: font, stack: stack}}

      %{operator: "Tf", operands: [{:name, font_name}, _size]} ->
        with {:ok, font, preparation} <-
               resolve_font(document, resources, font_name, page, state.preparation) do
          {:ok, Map.put(instruction, :font, font),
           %{state | font: font, preparation: preparation}}
        end

      %{operator: "gs", operands: [{:name, name}]} ->
        with {:ok, font_state, preparation} <-
               prepare_ext_graphics_state(
                 document,
                 resources,
                 name,
                 page,
                 state.preparation
               ) do
          case font_state do
            nil ->
              {:ok, instruction, %{state | preparation: preparation}}

            %{font: font} = font_state ->
              {:ok, Map.merge(instruction, font_state),
               %{state | font: font, preparation: preparation}}
          end
        end

      %{operator: operator, operands: [string]} when operator in ["Tj", "'"] ->
        with {:ok, decoded, preparation} <-
               decode_string(string, state.font, page, state.preparation) do
          {:ok, Map.put(instruction, :decoded, decoded), %{state | preparation: preparation}}
        end

      %{operator: "\"", operands: [_word_spacing, _char_spacing, string]} ->
        with {:ok, decoded, preparation} <-
               decode_string(string, state.font, page, state.preparation) do
          {:ok, Map.put(instruction, :decoded, decoded), %{state | preparation: preparation}}
        end

      %{operator: "TJ", operands: [{:array, values}]} ->
        values
        |> Enum.reduce_while({:ok, [], state.preparation}, fn value,
                                                              {:ok, prepared, preparation} ->
          case TextValidator.number(value) do
            {:ok, number} ->
              {:cont, {:ok, [{:adjustment, number} | prepared], preparation}}

            :error ->
              case decode_string(value, state.font, page, preparation) do
                {:ok, decoded, preparation} ->
                  {:cont, {:ok, [{:text, decoded} | prepared], preparation}}

                {:error, _} = decoding_error ->
                  {:halt, decoding_error}
              end
          end
        end)
        |> case do
          {:ok, prepared, preparation} ->
            {:ok, Map.put(instruction, :prepared_values, Enum.reverse(prepared)),
             %{state | preparation: preparation}}

          {:error, _} = decoding_error ->
            decoding_error
        end

      %{operator: "Do", operands: [{:name, name}]} ->
        with {:ok, form, preparation} <-
               prepare_form(
                 name,
                 document,
                 resources,
                 state.font,
                 page,
                 depth,
                 state.preparation
               ) do
          {:ok, Map.put(instruction, :form, form), %{state | preparation: preparation}}
        end

      _ ->
        {:ok, instruction, state}
    end
  end

  defp prepare_form(
         name,
         document,
         resources,
         inherited_font,
         page,
         depth,
         preparation_context
       ) do
    case depth >= Limits.get(:max_form_xobject_depth) do
      true ->
        error(:limits, :resource_limit_exceeded, "Form XObject nesting exceeds the limit",
          page: page
        )

      false ->
        with {:ok, resources} <- Reader.dictionary(document, resources),
             {:ok, xobjects} <- Reader.dictionary(document, Map.get(resources, "XObject")),
             {:ok, xobject_ref} <- required_value(xobjects, name, "XObject", page),
             {:ok, xobject} <- Reader.dictionary(document, xobject_ref) do
          case name?(Map.get(xobject, "Subtype"), "Form") do
            true ->
              with {:ok, preparation_context} <-
                     TextValidator.charge_form_expansion(preparation_context, page),
                   {:ok, instructions, preparation_context} <-
                     TextValidator.prepare_content_stream(
                       document,
                       xobject_ref,
                       page,
                       preparation_context
                     ),
                   :ok <- TextValidator.validate_scopes([instructions], page),
                   {:ok, matrix} <- matrix_value(document, Map.get(xobject, "Matrix")),
                   {:ok, instructions, state} <-
                     prepare_instructions(
                       instructions,
                       document,
                       Map.get(xobject, "Resources", resources),
                       %{font: inherited_font, stack: [], preparation: preparation_context},
                       page,
                       depth + 1
                     ) do
                {:ok, %{instructions: instructions, matrix: matrix}, state.preparation}
              end

            false ->
              {:ok, nil, preparation_context}
          end
        end
    end
  end

  defp resolve_font(document, resources, font_name, page, preparation_context) do
    with {:ok, resources} <- Reader.dictionary(document, resources),
         {:ok, fonts} <- Reader.dictionary(document, Map.get(resources, "Font")),
         {:ok, font_ref} <- required_value(fonts, font_name, "font", page),
         {:ok, font} <- Reader.dictionary(document, font_ref) do
      prepare_font(document, font_ref, font, font_name, page, preparation_context)
    else
      {:error, {reason, diagnostic}} ->
        {:error, {reason, with_debug_details(diagnostic, page: page, font: font_name)}}
    end
  end

  defp prepare_ext_graphics_state(document, resources, name, page, preparation_context) do
    with {:ok, resources} <- Reader.dictionary(document, resources),
         ext_graphics_states when not is_nil(ext_graphics_states) <-
           Map.get(resources, "ExtGState"),
         {:ok, ext_graphics_states} <- Reader.dictionary(document, ext_graphics_states),
         {:ok, ext_graphics_state_ref} <-
           required_value(ext_graphics_states, name, "ExtGState", page),
         {:ok, ext_graphics_state} <- Reader.dictionary(document, ext_graphics_state_ref) do
      case Map.get(ext_graphics_state, "Font") do
        nil ->
          {:ok, nil, preparation_context}

        font_value ->
          case Reader.resolve(document, font_value) do
            {:ok, [{:ref, _ref} = font_ref, size]} when is_number(size) ->
              with true <- PdfValidator.valid_number?(size),
                   {:ok, font_dictionary} <- Reader.dictionary(document, font_ref),
                   {:ok, font, preparation_context} <-
                     prepare_font(
                       document,
                       font_ref,
                       font_dictionary,
                       name,
                       page,
                       preparation_context
                     ) do
                {:ok, %{font: font, font_size: size * 1.0}, preparation_context}
              else
                false ->
                  error(
                    :resources,
                    :invalid_pdf_input,
                    "ExtGState resource #{name} font size exceeds the numeric magnitude limit",
                    page: page
                  )

                {:error, _} = font_error ->
                  font_error
              end

            {:ok, _malformed} ->
              error(
                :resources,
                :invalid_pdf_input,
                "ExtGState resource #{name} Font entry is malformed",
                page: page
              )

            {:error, _} = resolution_error ->
              resolution_error
          end
      end
    else
      nil ->
        error(:resources, :invalid_pdf_input, "ExtGState resources are missing", page: page)

      {:error, _} = resource_error ->
        resource_error
    end
  end

  defp prepare_font(document, font_ref, font, font_name, page, preparation_context) do
    case font_ref do
      {:ref, ref} ->
        case Map.fetch(preparation_context.prepared_fonts, ref) do
          {:ok, {prepared_font, stream_uses}} ->
            case TextValidator.charge_stream_uses(preparation_context, stream_uses, page) do
              {:ok, preparation_context} ->
                {:ok, Map.put(prepared_font, :name, font_name), preparation_context}

              {:error, {reason, diagnostic}} ->
                {:error, {reason, with_debug_details(diagnostic, page: page, font: font_name)}}
            end

          :error ->
            original_stream_uses = preparation_context.stream_uses

            with {:ok, prepared_font, preparation_context} <-
                   parse_font(document, font, font_name, page, preparation_context) do
              cached =
                {Map.delete(prepared_font, :name),
                 preparation_context.stream_uses - original_stream_uses}

              preparation_context = %{
                preparation_context
                | prepared_fonts: Map.put(preparation_context.prepared_fonts, ref, cached)
              }

              {:ok, prepared_font, preparation_context}
            end
        end

      _ ->
        parse_font(document, font, font_name, page, preparation_context)
    end
  end

  defp parse_font(document, font, font_name, page, preparation_context) do
    cmap =
      case Map.get(font, "ToUnicode") do
        nil ->
          {:ok, nil, preparation_context}

        cmap_ref ->
          with {:ok, stream, preparation_context} <-
                 TextValidator.decoded_stream(
                   document,
                   cmap_ref,
                   page,
                   preparation_context
                 ),
               {:ok, preparation_context} <-
                 reserve_cmap_work(stream, preparation_context, page, font_name, "ToUnicode"),
               {:ok, cmap, cmap_bytes} <-
                 parse_cmap(stream, page, font_name, preparation_context.cmap_bytes) do
            {:ok, cmap, %{preparation_context | cmap_bytes: cmap_bytes}}
          end
      end

    with {:ok, cmap, preparation_context} <- cmap,
         {:ok, cid_encoding, preparation_context} <-
           type0_cid_encoding(document, font, page, font_name, preparation_context),
         {:ok, widths, default_width} <- font_metrics(document, font) do
      {:ok,
       %{
         name: font_name,
         dictionary: font,
         cmap: cmap,
         cid_encoding: cid_encoding,
         document: document,
         widths: widths,
         default_width: default_width
       }, preparation_context}
    end
  end

  defp font_metrics(document, font) do
    case name?(Map.get(font, "Subtype"), "Type0") do
      true -> type0_font_metrics(document, font)
      false -> simple_font_metrics(document, font)
    end
  end

  defp type0_cid_encoding(document, font, page, font_name, preparation_context) do
    case name?(Map.get(font, "Subtype"), "Type0") do
      true ->
        case Map.get(font, "Encoding") do
          {:name, "Identity-H"} ->
            {:ok, :identity, preparation_context}

          {:name, _name} ->
            error(
              :cmap,
              :unsupported_text_encoding,
              "predefined Type0 Encoding CMaps other than Identity-H are unsupported",
              page: page,
              font: font_name
            )

          nil ->
            error(:font, :invalid_pdf_input, "Type0 font Encoding entry is missing",
              page: page,
              font: font_name
            )

          encoding ->
            with {:ok, dictionary} <- Reader.dictionary(document, encoding),
                 {:ok, stream, preparation_context} <-
                   TextValidator.decoded_stream(
                     document,
                     encoding,
                     page,
                     preparation_context
                   ) do
              case {Map.get(dictionary, "UseCMap"), Map.get(dictionary, "WMode", 0)} do
                {nil, 0} ->
                  with {:ok, preparation_context} <-
                         reserve_cmap_work(
                           stream,
                           preparation_context,
                           page,
                           font_name,
                           "Type0 Encoding"
                         ),
                       {:ok, cmap} <- parse_cid_cmap(stream, page, font_name) do
                    {:ok, cmap, preparation_context}
                  end

                {nil, _vertical} ->
                  error(
                    :cmap,
                    :unsupported_text_encoding,
                    "vertical Type0 Encoding CMaps are unsupported",
                    page: page,
                    font: font_name
                  )

                {_use_cmap, _writing_mode} ->
                  error(
                    :cmap,
                    :unsupported_text_encoding,
                    "Type0 Encoding UseCMap inheritance is unsupported",
                    page: page,
                    font: font_name
                  )
              end
            end
        end

      false ->
        {:ok, nil, preparation_context}
    end
  end

  defp simple_font_metrics(document, font) do
    first_char = Map.get(font, "FirstChar", 0)

    with true <- is_integer(first_char) and first_char >= 0,
         {:ok, widths} <- Reader.resolve(document, Map.get(font, "Widths")),
         true <-
           is_nil(widths) or
             (is_list(widths) and Enum.all?(widths, &PdfValidator.valid_number?/1)),
         {:ok, default_width} <- simple_default_width(document, font) do
      width_map =
        case widths do
          nil ->
            %{}

          widths ->
            widths
            |> Enum.with_index(first_char)
            |> Map.new(fn {width, code} -> {code, width} end)
        end

      {:ok, width_map, default_width}
    else
      false -> error(:font, :invalid_pdf_input, "simple font width metrics are malformed")
      {:error, _} = metric_error -> metric_error
    end
  end

  defp simple_default_width(document, font) do
    case Map.get(font, "FontDescriptor") do
      nil ->
        {:ok, 500}

      descriptor ->
        with {:ok, descriptor} <- Reader.dictionary(document, descriptor) do
          width = Map.get(descriptor, "MissingWidth", 500)

          case PdfValidator.valid_number?(width) do
            true -> {:ok, width}
            false -> error(:font, :invalid_pdf_input, "font MissingWidth is malformed")
          end
        end
    end
  end

  defp type0_font_metrics(document, font) do
    with {:ok, descendants} <- Reader.resolve(document, Map.get(font, "DescendantFonts")),
         [descendant | _] <- descendants,
         {:ok, descendant} <- Reader.dictionary(document, descendant),
         default_width = Map.get(descendant, "DW", 1000),
         true <- PdfValidator.valid_number?(default_width),
         {:ok, widths} <- Reader.resolve(document, Map.get(descendant, "W")),
         {:ok, widths} <- cid_widths(widths) do
      {:ok, widths, default_width}
    else
      {:error, _} = metric_error -> metric_error
      _ -> error(:font, :invalid_pdf_input, "Type0 descendant font metrics are malformed")
    end
  end

  defp cid_widths(values) do
    case values do
      nil ->
        {:ok, %{}}

      values when is_list(values) ->
        parse_cid_widths(values, %{}, 0)

      _ ->
        error(:font, :invalid_pdf_input, "CID font W array is malformed")
    end
  end

  defp parse_cid_widths(values, widths, entry_count) do
    case values do
      [] ->
        {:ok, widths}

      [first, listed | rest] when is_integer(first) and first >= 0 and is_list(listed) ->
        count = length(listed)

        with true <- Enum.all?(listed, &PdfValidator.valid_number?/1),
             :ok <- validate_cid_width_entries(first, count, entry_count) do
          listed_widths =
            Map.new(Enum.with_index(listed, first), fn {width, code} -> {code, width} end)

          parse_cid_widths(rest, Map.merge(widths, listed_widths), entry_count + count)
        else
          false -> error(:font, :invalid_pdf_input, "CID font listed widths are malformed")
          {:error, _} = width_error -> width_error
        end

      [first, last, width | rest]
      when is_integer(first) and first >= 0 and is_integer(last) and last >= first and
             is_number(width) ->
        count = last - first + 1

        with true <- PdfValidator.valid_number?(width),
             :ok <- validate_cid_width_entries(first, count, entry_count) do
          range_widths = Map.new(first..last, &{&1, width})
          parse_cid_widths(rest, Map.merge(widths, range_widths), entry_count + count)
        else
          false ->
            error(
              :font,
              :invalid_pdf_input,
              "CID font range width exceeds the numeric magnitude limit"
            )

          {:error, _} = width_error ->
            width_error
        end

      _ ->
        error(:font, :invalid_pdf_input, "CID font W array is malformed")
    end
  end

  defp validate_cid_width_entries(first, count, entry_count) do
    cond do
      entry_count + count > Limits.get(:max_cid_width_entries) ->
        error(:font, :resource_limit_exceeded, "CID font width entry count exceeds the limit")

      first > @max_cid or (count > 0 and first + count - 1 > @max_cid) ->
        error(:font, :invalid_pdf_input, "CID font W array contains an out-of-range CID")

      true ->
        :ok
    end
  end

  defp decode_string(string, font, page, preparation) do
    remaining = Limits.get(:max_extracted_text_bytes) - preparation.extracted_bytes

    {_kind, bytes} = string

    work =
      case font do
        %{cmap: %{lookup_work: work, min_width: width}} -> div(byte_size(bytes), width) * work
        _ -> 0
      end

    with {:ok, preparation} <- charge_cmap_work(preparation, work, page, font && font.name),
         {:ok, decoded} <- decode_string_bytes(string, font, page, remaining) do
      {:ok, decoded,
       %{preparation | extracted_bytes: preparation.extracted_bytes + byte_size(decoded.text)}}
    end
  end

  defp decode_string_bytes(string, font, page, remaining) do
    {_kind, bytes} = string

    cond do
      is_nil(font) ->
        error(
          :text_encoding,
          :unsupported_text_encoding,
          "text is shown without an active font",
          page: page
        )

      font.cmap ->
        with {:ok, decoded} <- decode_cmap(bytes, font.cmap, page, font.name, remaining) do
          {:ok, Map.put(decoded, :width_codes, width_codes(font, decoded))}
        end

      name?(Map.get(font.dictionary, "Subtype"), "Type0") ->
        error(:text_encoding, :unsupported_text_encoding, "Type0 font has no ToUnicode CMap",
          page: page,
          font: font.name
        )

      true ->
        decode_simple_font(bytes, font, page, remaining)
    end
  end

  defp decode_simple_font(bytes, font, page, remaining) do
    with {:ok, encoding, differences} <- font_encoding(font.document, font.dictionary),
         {:ok, decoded} <- decode_simple_bytes(bytes, encoding, differences, remaining) do
      {:ok, decoded}
    else
      {:error, {reason, diagnostic}} ->
        {:error, {reason, with_debug_details(diagnostic, page: page, font: font.name)}}
    end
  end

  defp font_encoding(document, font) do
    case Map.get(font, "Encoding") do
      nil ->
        with {:ok, encoding} <- default_font_encoding(font) do
          {:ok, encoding, %{}}
        end

      {:name, name} ->
        if TextEncoding.supported?(name) do
          {:ok, name, %{}}
        else
          error(:text_encoding, :unsupported_text_encoding, "simple font encoding is unsupported")
        end

      encoding_ref ->
        with {:ok, encoding} <- Reader.dictionary(document, encoding_ref) do
          base =
            case Map.get(encoding, "BaseEncoding") do
              {:name, name} -> {:ok, name}
              nil -> default_font_encoding(font)
              _ -> :error
            end

          with {:ok, base} <- base,
               true <- TextEncoding.supported?(base),
               {:ok, differences} <- differences(Map.get(encoding, "Differences")) do
            {:ok, base, differences}
          else
            false ->
              error(
                :text_encoding,
                :unsupported_text_encoding,
                "simple font base encoding is unsupported"
              )

            :error ->
              error(:text_encoding, :invalid_pdf_input, "simple font Encoding is malformed")

            {:error, _} = encoding_error ->
              encoding_error
          end
        end
    end
  end

  defp default_font_encoding(font) do
    case Map.get(font, "BaseFont") do
      {:name, base_font} when is_binary(base_font) ->
        if String.valid?(base_font) do
          base_font = base_font |> String.split("+") |> List.last()

          case base_font do
            "Symbol" ->
              {:ok, "SymbolEncoding"}

            "ZapfDingbats" ->
              {:ok, "ZapfDingbatsEncoding"}

            base_font
            when base_font in [
                   "Times-Roman",
                   "Times-Bold",
                   "Times-Italic",
                   "Times-BoldItalic",
                   "Helvetica",
                   "Helvetica-Bold",
                   "Helvetica-Oblique",
                   "Helvetica-BoldOblique",
                   "Courier",
                   "Courier-Bold",
                   "Courier-Oblique",
                   "Courier-BoldOblique"
                 ] ->
              {:ok, "StandardEncoding"}

            _ ->
              error(
                :text_encoding,
                :unsupported_text_encoding,
                "custom simple font has no reliable Unicode encoding"
              )
          end
        else
          error(:text_encoding, :invalid_pdf_input, "font BaseFont name is malformed")
        end

      _ ->
        error(
          :text_encoding,
          :unsupported_text_encoding,
          "simple font has no declared or standard base encoding"
        )
    end
  end

  defp differences(values) do
    case values do
      nil ->
        {:ok, %{}}

      values when is_list(values) ->
        values
        |> Enum.reduce_while({:ok, %{}, nil}, fn value, {:ok, mappings, code} ->
          case value do
            value when is_integer(value) and value in 0..255 ->
              {:cont, {:ok, mappings, value}}

            {:name, glyph} when is_integer(code) and code in 0..255 ->
              {:cont, {:ok, Map.put(mappings, code, glyph), code + 1}}

            _ ->
              {:halt,
               error(:text_encoding, :invalid_pdf_input, "font Differences array is malformed")}
          end
        end)
        |> case do
          {:ok, mappings, _code} -> {:ok, mappings}
          {:error, _} = differences_error -> differences_error
        end

      _ ->
        error(:text_encoding, :invalid_pdf_input, "font Differences entry is malformed")
    end
  end

  defp decode_simple_bytes(bytes, encoding, differences, remaining) do
    bytes
    |> :binary.bin_to_list()
    |> Enum.reduce_while({:ok, [], remaining}, fn code, {:ok, characters, remaining} ->
      case TextEncoding.character(encoding, code, differences) do
        {:ok, character} ->
          case charge_bytes(remaining, byte_size(character), :text) do
            {:ok, remaining} -> {:cont, {:ok, [character | characters], remaining}}
            {:error, _} = limit_error -> {:halt, limit_error}
          end

        :error ->
          {:halt,
           error(
             :text_encoding,
             :unsupported_text_encoding,
             "font encoding cannot be converted to Unicode"
           )}
      end
    end)
    |> case do
      {:ok, characters, _remaining} ->
        {:ok,
         %{text: characters |> Enum.reverse() |> Enum.join(), codes: :binary.bin_to_list(bytes)}}

      decoding_error ->
        decoding_error
    end
  end

  defp width_codes(font, decoded) do
    case font.cid_encoding do
      :identity ->
        Enum.map(decoded.source_codes, &:binary.decode_unsigned/1)

      %{mappings: mappings, notdef: notdef} ->
        Enum.map(decoded.source_codes, fn source ->
          Map.get(mappings, source, Map.get(notdef, source, 0))
        end)

      nil ->
        decoded.codes
    end
  end

  defp parse_cmap(stream, page, font, cmap_bytes) do
    stream = strip_cmap_comments(stream)

    case Regex.match?(~r/\/\S+\s+usecmap\b/, stream) do
      true ->
        error(
          :cmap,
          :unsupported_text_encoding,
          "ToUnicode usecmap inheritance is unsupported",
          page: page,
          font: font
        )

      false ->
        with {:ok, codespaces} <- parse_codespaces(stream, "ToUnicode"),
             {:ok, mappings, remaining} <-
               parse_unicode_mappings(
                 stream,
                 Limits.get(:max_cmap_expanded_bytes) - cmap_bytes
               ),
             true <- map_size(mappings) > 0 do
          sizes =
            codespaces
            |> Enum.map(fn {first, _last} -> byte_size(first) end)
            |> Enum.uniq()
            |> Enum.sort(:desc)

          {:ok,
           %{
             codespaces: codespaces,
             mappings: mappings,
             sizes: sizes,
             min_width: List.last(sizes),
             lookup_work: length(sizes) * (length(codespaces) + 1)
           }, Limits.get(:max_cmap_expanded_bytes) - remaining}
        else
          false ->
            error(
              :cmap,
              :unsupported_text_encoding,
              "ToUnicode CMap has no usable Unicode mappings",
              page: page,
              font: font
            )

          {:error, _} = error ->
            error
        end
    end
  end

  defp parse_cid_cmap(stream, page, font) do
    stream = strip_cmap_comments(stream)

    cond do
      Regex.match?(~r/\/\S+\s+usecmap\b/, stream) ->
        error(
          :cmap,
          :unsupported_text_encoding,
          "Type0 Encoding usecmap inheritance is unsupported",
          page: page,
          font: font
        )

      Regex.match?(~r/\/WMode\s+1\s+def\b/, stream) ->
        error(
          :cmap,
          :unsupported_text_encoding,
          "vertical Type0 Encoding CMaps are unsupported",
          page: page,
          font: font
        )

      true ->
        with {:ok, codespaces} <- parse_codespaces(stream, "Type0 Encoding"),
             {:ok, mappings} <-
               parse_cid_mappings(stream, ["cidchar", "cidrange"], 0),
             {:ok, notdef} <-
               parse_cid_mappings(
                 stream,
                 ["notdefchar", "notdefrange"],
                 map_size(mappings)
               ) do
          {:ok, %{codespaces: codespaces, mappings: mappings, notdef: notdef}}
        else
          :limit ->
            error(
              :cmap,
              :resource_limit_exceeded,
              "Type0 Encoding CMap entry count exceeds the limit",
              page: page,
              font: font
            )

          :error ->
            error(:cmap, :invalid_pdf_input, "Type0 Encoding CMap mappings are malformed",
              page: page,
              font: font
            )

          {:error, _} = cmap_error ->
            cmap_error
        end
    end
  end

  defp strip_cmap_comments(stream) do
    Regex.replace(~r/%[^\r\n]*/, stream, "")
  end

  # Reserve expansion and lookup work independently of retained map cardinality.
  # The normal parsers below remain responsible for syntax and mapping validity.
  defp reserve_cmap_work(stream, preparation, page, font, label) do
    if byte_size(stream) > Limits.get(:max_cmap_bytes) do
      error(:cmap, :resource_limit_exceeded, "#{label} CMap exceeds the byte limit",
        page: page,
        font: font
      )
    else
      reserve_cmap_sections(stream, preparation, page, font, label)
    end
  end

  defp reserve_cmap_sections(stream, preparation, page, font, label) do
    uncommented = strip_cmap_comments(stream)

    mapping_pattern =
      if label == "ToUnicode", do: @unicode_mapping_section, else: @cid_mapping_section

    sections =
      Regex.scan(mapping_pattern, uncommented) ++
        Enum.map(Regex.scan(@codespace_section, uncommented), fn [section, count, _body] ->
          [section, count, "codespacerange"]
        end)

    with {:ok, preparation} <- charge_cmap_work(preparation, byte_size(stream), page, font) do
      Enum.reduce_while(sections, {:ok, preparation}, fn [section, _count, operator],
                                                         {:ok, preparation} ->
        entries =
          case operator do
            range when range in ["bfrange", "cidrange", "notdefrange"] ->
              Regex.scan(
                ~r/<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*(?:\[[^\]]*\]|<[0-9A-Fa-f]+>|\d+)/,
                section
              )

            _ ->
              Regex.scan(~r/<[0-9A-Fa-f]+>\s*(?:<[0-9A-Fa-f]+>|\d+)/, section)
          end

        Enum.reduce_while(entries, {:ok, preparation}, fn entry, {:ok, preparation} ->
          count =
            case entry do
              [_, first, last] ->
                max(String.to_integer(last, 16) - String.to_integer(first, 16) + 1, 0)

              [_] ->
                1
            end

          case charge_cmap_work(preparation, count, page, font) do
            {:ok, preparation} -> {:cont, {:ok, preparation}}
            error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, preparation} -> {:cont, {:ok, preparation}}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp charge_cmap_work(preparation, work, page, font) do
    used = preparation.cmap_work + work

    if used <= Limits.get(:max_cmap_work) do
      {:ok, %{preparation | cmap_work: used}}
    else
      error(
        :limits,
        :resource_limit_exceeded,
        "aggregate CMap processing work exceeds max_cmap_work",
        page: page,
        font: font
      )
    end
  end

  defp parse_unicode_mappings(stream, remaining) do
    @unicode_mapping_section
    |> Regex.scan(stream)
    |> Enum.reduce_while({:ok, %{}, remaining}, fn [section, _count, operator],
                                                   {:ok, mappings, remaining} ->
      parsed =
        case operator do
          "bfchar" -> parse_bfchar(section, remaining)
          "bfrange" -> parse_bfrange(section, map_size(mappings), remaining)
        end

      case parsed do
        {:ok, section_mappings, remaining} ->
          mappings = Map.merge(mappings, section_mappings)

          case map_size(mappings) <= Limits.get(:max_cmap_entries) do
            true ->
              {:cont, {:ok, mappings, remaining}}

            false ->
              {:halt,
               error(
                 :cmap,
                 :resource_limit_exceeded,
                 "ToUnicode CMap entry count exceeds the limit"
               )}
          end

        {:error, _} = mapping_error ->
          {:halt, mapping_error}
      end
    end)
  end

  defp parse_cid_mappings(stream, operators, existing) do
    @cid_mapping_section
    |> Regex.scan(stream)
    |> Enum.filter(fn [_section, _count, operator] -> operator in operators end)
    |> Enum.reduce_while({:ok, %{}}, fn [section, _count, operator], {:ok, mappings} ->
      parsed =
        case operator do
          "cidchar" ->
            parse_cid_char(section, operator, existing + map_size(mappings))

          "cidrange" ->
            parse_cid_range(section, operator, existing + map_size(mappings), :sequential)

          "notdefchar" ->
            parse_cid_char(section, operator, existing + map_size(mappings))

          "notdefrange" ->
            parse_cid_range(section, operator, existing + map_size(mappings), :constant)
        end

      case parsed do
        {:ok, section_mappings} ->
          {:cont, {:ok, Map.merge(mappings, section_mappings)}}

        failure ->
          {:halt, failure}
      end
    end)
  end

  defp parse_codespaces(stream, label) do
    sections = Regex.scan(@codespace_section, stream)

    sections
    |> Enum.reduce_while({:ok, []}, fn [_, count, section], {:ok, values} ->
      entries = Regex.scan(~r/<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>/, section)

      valid? =
        String.to_integer(count) == length(entries) and
          cmap_section_consumed?(section, ~r/<[0-9A-Fa-f]+>\s*<[0-9A-Fa-f]+>/)

      if valid? do
        parsed =
          Enum.map(entries, fn [_, first, last] -> {hex_bytes(first), hex_bytes(last)} end)

        if Enum.all?(parsed, fn {first, last} ->
             is_binary(first) and byte_size(first) == byte_size(last) and first <= last
           end) do
          {:cont, {:ok, Enum.reverse(parsed, values)}}
        else
          {:halt, error(:cmap, :invalid_pdf_input, "#{label} codespace range is malformed")}
        end
      else
        {:halt, error(:cmap, :invalid_pdf_input, "#{label} codespace count is malformed")}
      end
    end)
    |> case do
      {:ok, []} -> error(:cmap, :invalid_pdf_input, "#{label} codespace range is missing")
      {:ok, values} -> {:ok, Enum.reverse(values)}
      result -> result
    end
  end

  defp parse_cid_char(stream, operator, existing) do
    pattern = Regex.compile!("(\\d+)\\s+begin#{operator}\\s*(.*?)\\s*end#{operator}", "s")

    Regex.scan(pattern, stream)
    |> Enum.reduce_while({:ok, %{}}, fn [_, count, section], {:ok, mappings} ->
      entries = Regex.scan(~r/<([0-9A-Fa-f]+)>\s+(\d+)/, section)

      valid? =
        String.to_integer(count) == length(entries) and
          cmap_section_consumed?(section, ~r/<[0-9A-Fa-f]+>\s+\d+/)

      case valid? do
        true ->
          parsed =
            Enum.map(entries, fn [_, source, cid] ->
              {hex_bytes(source), String.to_integer(cid)}
            end)

          case Enum.all?(parsed, fn {source, cid} ->
                 is_binary(source) and cid in 0..@max_cid
               end) do
            true ->
              mappings = Map.merge(mappings, Map.new(parsed))

              case existing + map_size(mappings) <= Limits.get(:max_cmap_entries) do
                true -> {:cont, {:ok, mappings}}
                false -> {:halt, :limit}
              end

            false ->
              {:halt, :error}
          end

        false ->
          {:halt, :error}
      end
    end)
  end

  defp parse_cid_range(stream, operator, existing, mapping_type) do
    pattern = Regex.compile!("(\\d+)\\s+begin#{operator}\\s*(.*?)\\s+end#{operator}", "s")

    Regex.scan(pattern, stream)
    |> Enum.reduce_while({:ok, %{}}, fn [_, declared_count, section], {:ok, mappings} ->
      entries = Regex.scan(~r/<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*(\d+)/, section)

      valid? =
        String.to_integer(declared_count) == length(entries) and
          cmap_section_consumed?(section, ~r/<[0-9A-Fa-f]+>\s*<[0-9A-Fa-f]+>\s*\d+/)

      case valid? do
        true ->
          Enum.reduce_while(entries, {:ok, mappings}, fn [_, first, last, cid], {:ok, mappings} ->
            first = hex_bytes(first)
            last = hex_bytes(last)
            cid = String.to_integer(cid)

            case is_binary(first) and is_binary(last) and
                   byte_size(first) == byte_size(last) and first <= last do
              true ->
                count = :binary.decode_unsigned(last) - :binary.decode_unsigned(first) + 1

                cond do
                  cid > @max_cid or
                      (mapping_type == :sequential and cid + count - 1 > @max_cid) ->
                    {:halt, :error}

                  existing + map_size(mappings) + count > Limits.get(:max_cmap_entries) ->
                    {:halt, :limit}

                  true ->
                    range =
                      0..(count - 1)
                      |> Map.new(fn offset ->
                        mapped_cid =
                          case mapping_type do
                            :sequential -> cid + offset
                            :constant -> cid
                          end

                        {increment_binary(first, offset), mapped_cid}
                      end)

                    {:cont, {:ok, Map.merge(mappings, range)}}
                end

              false ->
                {:halt, :error}
            end
          end)
          |> case do
            {:ok, mappings} -> {:cont, {:ok, mappings}}
            failure -> {:halt, failure}
          end

        false ->
          {:halt, :error}
      end
    end)
  end

  defp parse_bfchar(stream, remaining) do
    Regex.scan(~r/(\d+)\s+beginbfchar\s*(.*?)\s*endbfchar/s, stream)
    |> Enum.reduce_while({:ok, %{}, remaining}, fn [_, count, section],
                                                   {:ok, mappings, remaining} ->
      entries = Regex.scan(~r/<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>/, section)

      if String.to_integer(count) == length(entries) and
           cmap_section_consumed?(section, ~r/<[0-9A-Fa-f]+>\s*<[0-9A-Fa-f]+>/) do
        Enum.reduce_while(entries, {:ok, mappings, remaining}, fn [_, source, target],
                                                                  {:ok, mappings, remaining} ->
          with source when is_binary(source) <- hex_bytes(source),
               {:ok, target} <- utf16(hex_bytes(target)),
               {:ok, remaining} <-
                 charge_bytes(remaining, byte_size(source) + byte_size(target), :cmap) do
            {:cont, {:ok, Map.put(mappings, source, target), remaining}}
          else
            {:error, _} = limit_error ->
              {:halt, limit_error}

            _ ->
              {:halt, error(:cmap, :invalid_pdf_input, "ToUnicode bfchar mapping is malformed")}
          end
        end)
        |> case do
          {:ok, mappings, remaining} -> {:cont, {:ok, mappings, remaining}}
          {:error, _} = bfchar_error -> {:halt, bfchar_error}
        end
      else
        {:halt, error(:cmap, :invalid_pdf_input, "ToUnicode bfchar count is malformed")}
      end
    end)
  end

  defp parse_bfrange(stream, existing, remaining) do
    Regex.scan(~r/(\d+)\s+beginbfrange\s*(.*?)\s*endbfrange/s, stream)
    |> Enum.reduce_while({:ok, %{}, remaining}, fn [_, declared_count, section],
                                                   {:ok, mappings, remaining} ->
      entries =
        Regex.scan(
          ~r/<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*(\[[^\]]*\]|<[0-9A-Fa-f]+>)/,
          section
        )

      declared_count = String.to_integer(declared_count)

      section_valid? =
        declared_count == length(entries) and
          cmap_section_consumed?(
            section,
            ~r/<[0-9A-Fa-f]+>\s*<[0-9A-Fa-f]+>\s*(?:\[[^\]]*\]|<[0-9A-Fa-f]+>)/
          )

      if section_valid? do
        entries
        |> Enum.reduce_while({:ok, mappings, remaining}, fn [_, first, last, target],
                                                            {:ok, mappings, remaining} ->
          with first when is_binary(first) <- hex_bytes(first),
               last when is_binary(last) and byte_size(last) == byte_size(first) <-
                 hex_bytes(last),
               true <- first <= last,
               count <- :binary.decode_unsigned(last) - :binary.decode_unsigned(first) + 1,
               true <- count + existing + map_size(mappings) <= Limits.get(:max_cmap_entries),
               {:ok, entries, remaining} <- bfrange_entries(first, count, target, remaining) do
            {:cont, {:ok, Map.merge(mappings, entries), remaining}}
          else
            {:error, _} = limit_error ->
              {:halt, limit_error}

            _ ->
              {:halt, error(:cmap, :invalid_pdf_input, "ToUnicode bfrange mapping is malformed")}
          end
        end)
        |> case do
          {:ok, mappings, remaining} -> {:cont, {:ok, mappings, remaining}}
          {:error, _} = bfrange_error -> {:halt, bfrange_error}
        end
      else
        {:halt, error(:cmap, :invalid_pdf_input, "ToUnicode bfrange count is malformed")}
      end
    end)
  end

  defp cmap_section_consumed?(section, entry_pattern) do
    section
    |> then(&Regex.replace(entry_pattern, &1, ""))
    |> String.trim()
    |> then(&(&1 == ""))
  end

  defp bfrange_entries(first, count, target, remaining) do
    case target do
      "[" <> array ->
        targets = for [_, target] <- Regex.scan(~r/<([0-9A-Fa-f]+)>/, array), do: target

        if length(targets) == count do
          Enum.with_index(targets)
          |> Enum.reduce_while({:ok, %{}, remaining}, fn {target, offset},
                                                         {:ok, mappings, remaining} ->
            with {:ok, target} <- utf16(hex_bytes(target)),
                 {:ok, remaining} <-
                   charge_bytes(remaining, byte_size(first) + byte_size(target), :cmap) do
              {:cont,
               {:ok, Map.put(mappings, increment_binary(first, offset), target), remaining}}
            else
              error -> {:halt, error}
            end
          end)
        else
          error(:cmap, :invalid_pdf_input, "ToUnicode bfrange array length is invalid")
        end

      target ->
        target = target |> String.trim_leading("<") |> String.trim_trailing(">") |> hex_bytes()

        if is_binary(target) do
          0..(count - 1)
          |> Enum.reduce_while({:ok, %{}, remaining}, fn offset, {:ok, mappings, remaining} ->
            with source when is_binary(source) <- increment_binary(first, offset),
                 destination when is_binary(destination) <- increment_binary(target, offset),
                 {:ok, text} <- utf16(destination),
                 {:ok, remaining} <-
                   charge_bytes(remaining, byte_size(source) + byte_size(text), :cmap) do
              {:cont, {:ok, Map.put(mappings, source, text), remaining}}
            else
              {:error, _} = limit_error ->
                {:halt, limit_error}

              _ ->
                {:halt,
                 error(:cmap, :invalid_pdf_input, "ToUnicode bfrange destination overflows")}
            end
          end)
        else
          error(:cmap, :invalid_pdf_input, "ToUnicode bfrange destination is malformed")
        end
    end
  end

  defp decode_cmap(bytes, cmap, page, font, remaining) do
    decode_cmap_bytes(bytes, cmap, page, font, [], [], [], remaining)
  end

  defp decode_cmap_bytes(bytes, cmap, page, font, text_acc, codes, source_codes, remaining) do
    case bytes do
      <<>> ->
        {:ok,
         %{
           text: text_acc |> Enum.reverse() |> Enum.join(),
           codes: Enum.reverse(codes),
           source_codes: Enum.reverse(source_codes)
         }}

      bytes ->
        candidate =
          cmap.sizes
          |> Enum.find(fn size ->
            byte_size(bytes) >= size and
              (cmap.codespaces == [] or
                 Enum.any?(cmap.codespaces, fn {first, last} ->
                   byte_size(first) == size and binary_part(bytes, 0, size) >= first and
                     binary_part(bytes, 0, size) <= last
                 end))
          end)

        if candidate do
          <<code::binary-size(^candidate), rest::binary>> = bytes

          case Map.get(cmap.mappings, code) do
            nil ->
              error(
                :text_encoding,
                :unsupported_text_encoding,
                "ToUnicode CMap has no mapping for a shown character code",
                page: page,
                font: font
              )

            mapped_text ->
              with {:ok, remaining} <- charge_bytes(remaining, byte_size(mapped_text), :text) do
                decode_cmap_bytes(
                  rest,
                  cmap,
                  page,
                  font,
                  [mapped_text | text_acc],
                  [:binary.decode_unsigned(code) | codes],
                  [code | source_codes],
                  remaining
                )
              else
                {:error, {reason, diagnostic}} ->
                  {:error, {reason, with_debug_details(diagnostic, page: page, font: font)}}
              end
          end
        else
          error(
            :text_encoding,
            :unsupported_text_encoding,
            "shown character code is outside the ToUnicode codespace",
            page: page,
            font: font
          )
        end
    end
  end

  defp charge_bytes(remaining, bytes, kind) do
    if bytes <= remaining do
      {:ok, remaining - bytes}
    else
      message =
        case kind do
          :text -> "aggregate extracted text bytes exceed the limit"
          :cmap -> "aggregate expanded CMap bytes exceed the limit"
        end

      error(:limits, :resource_limit_exceeded, message)
    end
  end

  defp matrix_value(document, values) do
    case values do
      nil ->
        {:ok, [1.0, 0.0, 0.0, 1.0, 0.0, 0.0]}

      values ->
        with {:ok, matrix} <-
               PdfValidator.number_array(document, values, 6,
                 operation: :extract,
                 module: __MODULE__
               ) do
          {:ok, Enum.map(matrix, &(&1 * 1.0))}
        end
    end
  end

  defp required_value(dictionary, key, label, page) do
    case Map.get(dictionary, key) do
      nil ->
        error(:resources, :invalid_pdf_input, "#{label} resource #{key} is missing", page: page)

      value ->
        {:ok, value}
    end
  end

  defp name?(value, expected) do
    case value do
      {:name, value} -> value == expected
      _ -> false
    end
  end

  defp hex_bytes(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bytes} -> bytes
      :error -> nil
    end
  end

  defp utf16(bytes) do
    case bytes do
      nil ->
        :error

      bytes ->
        case :unicode.characters_to_binary(bytes, {:utf16, :big}, :utf8) do
          value when is_binary(value) -> {:ok, value}
          _ -> :error
        end
    end
  end

  defp increment_binary(binary, offset) do
    size = bit_size(binary)
    value = :binary.decode_unsigned(binary) + offset

    case value < 1 <<< size do
      true -> <<value::unsigned-big-size(size)>>
      false -> nil
    end
  end

  defp with_debug_details(diagnostic, details) do
    message =
      Enum.reduce(details, diagnostic.message, fn detail, message ->
        case detail do
          {:page, page} -> "#{message}; page #{page}"
          {:font, font} -> "#{message}; font #{font}"
        end
      end)

    Map.put(diagnostic, :message, message)
  end

  defp error(stage, reason, message, details \\ []) do
    {pdf_details, diagnostic_options} = Keyword.split(details, [:page, :font])

    {:error, {reason, diagnostic}} =
      Diagnostics.error(
        stage,
        reason,
        message,
        Keyword.merge([operation: :extract, module: __MODULE__], diagnostic_options)
      )

    message =
      Enum.reduce(pdf_details, diagnostic.message, fn detail, message ->
        case detail do
          {:page, page} -> "#{message}; page #{page}"
          {:font, font} -> "#{message}; font #{font}"
        end
      end)

    {:error, {reason, Map.put(diagnostic, :message, message)}}
  end
end
