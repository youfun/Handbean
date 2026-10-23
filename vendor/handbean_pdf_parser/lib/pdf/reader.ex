defmodule NativeElixirPdfUtilities.Pdf.Reader do
  @moduledoc """
  Strict, native PDF object reader shared by PDF utilities.

  The reader resolves direct and compressed objects, validates the final xref
  pointer, decodes the standard non-encryption stream filters, and walks the
  page tree with inherited resources. It intentionally does not decrypt PDFs.
  """

  alias NativeElixirPdfUtilities.Diagnostics
  alias NativeElixirPdfUtilities.Limits
  alias NativeElixirPdfUtilities.Tokenizer
  alias NativeElixirPdfUtilities.Validators.PdfValidator
  import Bitwise

  @type ref :: {non_neg_integer(), non_neg_integer()}
  @type value ::
          nil
          | boolean()
          | integer()
          | float()
          | {:name, binary()}
          | {:string, binary()}
          | {:hex, binary()}
          | {:ref, ref()}
          | [value()]
          | %{optional(binary()) => value()}
  @type object :: %{
          value: value(),
          stream: binary() | nil,
          offset: non_neg_integer() | nil,
          tokens: [Tokenizer.token()]
        }
  @type page :: %{
          ref: ref(),
          resources: value() | nil,
          rotate: number() | nil,
          media_box: [number()] | nil
        }
  @type document :: %{
          required(:objects) => %{optional(ref()) => object()},
          optional(atom()) => term()
        }
  @type xref_entry ::
          {:free, non_neg_integer(), non_neg_integer()}
          | {:uncompressed, non_neg_integer(), non_neg_integer()}
          | {:compressed, pos_integer(), non_neg_integer()}
  @type probe_context :: PdfValidator.probe_context()
  @type error_reason ::
          :encrypted_pdf
          | :invalid_pdf_input
          | :unsupported_pdf_feature
          | :resource_limit_exceeded

  @doc """
  Parses a PDF binary into a resolver document.
  """
  @spec read(binary()) :: {:ok, document()} | {:error, {error_reason(), Diagnostics.diagnostic()}}
  def read(pdf) do
    with {:ok, context} <- read_validated(pdf) do
      {:ok, context.document}
    end
  end

  @doc """
  Parses and semantically validates a PDF into a reusable prepared context.

  PDF-consuming operations can use this function to retain the shared catalog,
  page-tree, reference, and inherited-value work performed for `read/1`.
  """
  @spec read_validated(binary()) ::
          {:ok, PdfValidator.context()}
          | {:error, {error_reason(), Diagnostics.diagnostic()}}
  def read_validated(pdf) do
    PdfValidator.with_reader_budget(fn ->
      with {:ok, probe} <- probe(pdf),
           :ok <-
             PdfValidator.validate_unencrypted(probe.trailer,
               operation: :read,
               module: __MODULE__
             ),
           xref = probe.xref,
           trailer = probe.trailer,
           {:ok, objects} <- load_objects(pdf, xref),
           {:ok, context} <-
             PdfValidator.validate(
               %{
                 binary: pdf,
                 objects: objects,
                 trailer: trailer,
                 xref: xref,
                 xref_offset: probe.xref_offset,
                 xref_revisions: probe.xref_revisions
               },
               operation: :read,
               module: __MODULE__
             ) do
        {:ok, context}
      else
        {:error, {_reason, _diagnostic}} = reader_error -> reader_error
      end
    end)
  end

  @doc false
  @spec probe(term()) ::
          {:ok, probe_context()} | {:error, {error_reason(), Diagnostics.diagnostic()}}
  def probe(pdf) do
    PdfValidator.with_reader_budget(fn ->
      with :ok <- PdfValidator.validate_input(pdf, operation: :read, module: __MODULE__),
           {:ok, xref_offset} <- final_xref_offset(pdf),
           {:ok, xref, trailer, revisions} <- parse_xref_chain(pdf, xref_offset, %{}, 0),
           :ok <-
             PdfValidator.validate_xref_structure(xref, trailer, pdf,
               operation: :read,
               module: __MODULE__
             ) do
        {:ok,
         %{
           binary: pdf,
           xref_offset: xref_offset,
           xref_revisions: revisions,
           xref: xref,
           trailer: trailer,
           encrypted?: not is_nil(Map.get(trailer, "Encrypt"))
         }}
      else
        {:error, {_reason, _diagnostic}} = reader_error -> reader_error
      end
    end)
  end

  @doc """
  Resolves an indirect value in a parsed document.
  """
  @spec resolve(document(), value()) ::
          {:ok, value()} | {:error, {error_reason(), Diagnostics.diagnostic()}}
  def resolve(document, value) do
    PdfValidator.resolve(document, value, operation: :read, module: __MODULE__)
  end

  @doc """
  Resolves an indirect stream and decodes its declared filters.
  """
  @spec decoded_stream(document(), value()) ::
          {:ok, binary()} | {:error, {error_reason(), Diagnostics.diagnostic()}}
  def decoded_stream(document, value) do
    PdfValidator.with_reader_budget(fn ->
      with {:ok, stream_context} <-
             PdfValidator.prepare_decoded_stream(document, value,
               operation: :read,
               module: __MODULE__
             ) do
        decode_stream(stream_context.stream, stream_context.filters, stream_context.ref)
      end
    end)
  end

  @doc false
  @spec decode_prepared_stream(PdfValidator.stream_context()) ::
          {:ok, binary()} | {:error, {error_reason(), Diagnostics.diagnostic()}}
  def decode_prepared_stream(stream_context) do
    PdfValidator.with_reader_budget(fn ->
      case stream_context do
        %{stream: stream, filters: filters, ref: ref}
        when is_binary(stream) and is_list(filters) and is_tuple(ref) ->
          decode_stream(stream, filters, ref)

        _ ->
          Diagnostics.error(
            :stream,
            :invalid_pdf_input,
            "prepared stream context is malformed",
            operation: :read,
            module: __MODULE__
          )
      end
    end)
  end

  @doc """
  Resolves a dictionary value, returning an error when it is not a dictionary.
  """
  @spec dictionary(document(), value()) ::
          {:ok, map()} | {:error, {error_reason(), Diagnostics.diagnostic()}}
  def dictionary(document, value) do
    PdfValidator.dictionary(document, value, operation: :read, module: __MODULE__)
  end

  @doc """
  Returns a dictionary key after resolving the dictionary itself.
  """
  @spec fetch(document(), value(), binary()) ::
          {:ok, value() | nil} | {:error, {error_reason(), Diagnostics.diagnostic()}}
  def fetch(document, dictionary, key) do
    PdfValidator.fetch(document, dictionary, key, operation: :read, module: __MODULE__)
  end

  defp final_xref_offset(pdf) do
    PdfValidator.charge_reader_budget(:max_pdf_reader_work, byte_size(pdf))

    case Regex.scan(~r/startxref\s*(\d+)\s*%%EOF\s*\z/s, pdf) do
      [[_, offset_text]] ->
        offset = PdfValidator.reader_integer(offset_text)

        if offset < byte_size(pdf) do
          {:ok, offset}
        else
          error(:xref, :invalid_pdf_input, "final startxref offset is outside the PDF")
        end

      _ ->
        error(:xref, :invalid_pdf_input, "PDF is missing a valid final startxref section")
    end
  end

  defp parse_xref_chain(pdf, offset, seen, depth) do
    cond do
      Map.has_key?(seen, offset) ->
        error(:xref, :invalid_pdf_input, "xref revision chain contains a cycle")

      depth >= Limits.get(:max_pdf_xref_revisions) ->
        error(:limits, :resource_limit_exceeded, "xref revision count exceeds the limit")

      true ->
        with {:ok, entries, trailer} <- parse_xref_revision(pdf, offset),
             {:ok, previous_entries, previous_trailer, revisions} <-
               previous_xref_revision(
                 pdf,
                 Map.get(trailer, "Prev"),
                 Map.put(seen, offset, true),
                 depth
               ) do
          {:ok, Map.merge(previous_entries, entries), Map.merge(previous_trailer, trailer),
           revisions}
        end
    end
  end

  defp previous_xref_revision(pdf, offset, seen, depth) do
    case offset do
      nil ->
        {:ok, %{}, %{}, depth + 1}

      offset when is_integer(offset) and offset >= 0 ->
        parse_xref_chain(pdf, offset, seen, depth + 1)

      _ ->
        error(:xref, :invalid_pdf_input, "xref Prev offset is malformed")
    end
  end

  defp parse_xref_revision(pdf, offset) do
    if offset >= 0 and offset < byte_size(pdf) do
      tail = binary_part(pdf, offset, byte_size(pdf) - offset)

      cond do
        String.starts_with?(tail, "xref") ->
          parse_classic_xref(pdf, offset, tail)

        Regex.match?(~r/\A\d+\s+\d+\s+obj\b/, tail) ->
          parse_xref_stream(pdf, offset)

        true ->
          error(:xref, :invalid_pdf_input, "xref offset does not point to an xref section")
      end
    else
      error(:xref, :invalid_pdf_input, "xref offset is outside the PDF")
    end
  end

  defp parse_classic_xref(pdf, offset, tail) do
    tokens = tokenize_classic_xref_revision(tail)

    with [:xref | rest] <- tokens,
         {:ok, entries, trailer} <- parse_classic_sections(rest, %{}),
         {:ok, supplemental_entries, supplemental_trailer} <-
           supplemental_xref_stream(pdf, Map.get(trailer, "XRefStm"), offset, entries) do
      {:ok, Map.merge(entries, supplemental_entries), Map.merge(supplemental_trailer, trailer)}
    else
      {:error, _} = xref_error -> xref_error
      _ -> error(:xref, :invalid_pdf_input, "classic xref table is malformed")
    end
  end

  defp tokenize_classic_xref_revision(tail) do
    tail
    |> Tokenizer.new()
    |> take_classic_xref_tokens(:sections, [])
  end

  defp take_classic_xref_tokens(tokenizer, state, tokens) do
    with {token, %Tokenizer{} = tokenizer} <- Tokenizer.next(tokenizer) do
      case {state, token} do
        {_state, {:eof, nil}} ->
          Enum.reverse(tokens)

        {:sections, :trailer} ->
          take_classic_xref_tokens(tokenizer, :trailer_value, [:trailer | tokens])

        {:trailer_value, :dict_start} ->
          take_classic_xref_tokens(tokenizer, {:trailer_dictionary, 1}, [:dict_start | tokens])

        {:trailer_value, token} ->
          Enum.reverse([token | tokens])

        {{:trailer_dictionary, 1}, :dict_end} ->
          Enum.reverse([:dict_end | tokens])

        {{:trailer_dictionary, depth}, :dict_start} ->
          take_classic_xref_tokens(
            tokenizer,
            {:trailer_dictionary, depth + 1},
            [:dict_start | tokens]
          )

        {{:trailer_dictionary, depth}, :dict_end} ->
          take_classic_xref_tokens(
            tokenizer,
            {:trailer_dictionary, depth - 1},
            [:dict_end | tokens]
          )

        {state, token} ->
          take_classic_xref_tokens(tokenizer, state, [token | tokens])
      end
    else
      {:error, _} = error -> tokenizer_error(error, :xref)
    end
  end

  defp parse_classic_sections(tokens, entries) do
    max_objects = Limits.get(:max_pdf_objects)

    case tokens do
      [:trailer | rest] ->
        with {:ok, trailer, _rest} <- parse_value(rest),
             true <- is_map(trailer) do
          {:ok, entries, trailer}
        else
          {:error, {_reason, _diagnostic}} = error -> error
          _ -> error(:trailer, :invalid_pdf_input, "trailer dictionary is malformed")
        end

      [{:int, first}, {:int, count} | rest]
      when first >= 0 and count >= 0 and first + count <= max_objects + 1 ->
        with {:ok, entries, rest} <- parse_classic_entries(rest, first, count, entries) do
          parse_classic_sections(rest, entries)
        end

      _ ->
        error(:xref, :invalid_pdf_input, "classic xref subsection is malformed")
    end
  end

  defp parse_classic_entries(tokens, object, remaining, entries) do
    case remaining do
      0 ->
        {:ok, entries, tokens}

      _ ->
        case tokens do
          [{:int, offset}, {:int, generation}, {:op, marker} | rest]
          when offset >= 0 and generation in 0..65_535 and marker in ["n", "f"] ->
            if Map.has_key?(entries, object) do
              error(:xref, :invalid_pdf_input, "classic xref subsections overlap")
            else
              entry =
                if marker == "n",
                  do: {:uncompressed, offset, generation},
                  else: {:free, offset, generation}

              parse_classic_entries(
                rest,
                object + 1,
                remaining - 1,
                Map.put(entries, object, entry)
              )
            end

          _ ->
            error(:xref, :invalid_pdf_input, "classic xref entry is malformed")
        end
    end
  end

  defp supplemental_xref_stream(pdf, stream_offset, classic_offset, classic_entries) do
    case stream_offset do
      nil ->
        {:ok, %{}, %{}}

      stream_offset
      when is_integer(stream_offset) and stream_offset >= 0 and stream_offset != classic_offset ->
        parse_xref_stream(pdf, stream_offset, classic_entries)

      _ ->
        error(:xref, :invalid_pdf_input, "trailer XRefStm offset is malformed")
    end
  end

  defp parse_xref_stream(pdf, offset, bootstrap_entries \\ %{}) do
    with {:ok, ref, object} <- parse_indirect_object_at(pdf, offset, byte_size(pdf), nil),
         true <- is_map(object.value) and name?(Map.get(object.value, "Type"), "XRef") do
      case Map.get(object, :pending_stream) do
        nil ->
          decode_xref_stream_object(object, ref)

        source ->
          decode_xref_stream_with_indirect_length(
            pdf,
            object,
            ref,
            source,
            bootstrap_entries
          )
      end
    else
      false -> error(:xref, :invalid_pdf_input, "xref stream object is malformed")
      {:error, _} = xref_error -> xref_error
    end
  end

  defp decode_xref_stream_object(object, ref, supporting_objects \\ %{}) do
    objects = Map.put(supporting_objects, ref, object)

    with {:ok, stream_context} <-
           PdfValidator.prepare_decoded_stream(%{objects: objects}, {:ref, ref},
             operation: :read,
             module: __MODULE__
           ),
         {:ok, decoded} <- decode_stream(object.stream, stream_context.filters, ref),
         {:ok, entries} <- xref_stream_entries(decoded, object.value) do
      {:ok, entries, object.value}
    else
      {:error, _} = xref_error -> xref_error
    end
  end

  defp decode_xref_stream_with_indirect_length(pdf, object, ref, source, bootstrap_entries) do
    case xref_length_candidates(pdf, source.length_ref) do
      {:ok, candidates} ->
        decoded_candidates =
          Enum.reduce(candidates, [], fn candidate, decoded_candidates ->
            objects = %{ref => object, source.length_ref => candidate}
            pending = Map.delete(object, :pending_stream)

            case materialize_indirect_stream(pdf, objects, ref, pending, source) do
              {:ok, materialized} ->
                case decode_xref_stream_object(materialized, ref, objects) do
                  {:ok, entries, _trailer} = decoded ->
                    [{decoded, entries, candidate.offset} | decoded_candidates]

                  {:error, {:resource_limit_exceeded, _}} = error ->
                    PdfValidator.abort_reader_budget(error)

                  {:error, _} ->
                    decoded_candidates
                end

              {:error, _} ->
                decoded_candidates
            end
          end)

        confirmed =
          Enum.find(decoded_candidates, fn {_decoded, entries, candidate_offset} ->
            confirms_xref_length_candidate?(
              pdf,
              entries,
              bootstrap_entries,
              source.length_ref,
              candidate_offset
            )
          end)

        case {confirmed, decoded_candidates} do
          {{decoded, _entries, _offset}, _candidates} ->
            decoded

          {nil, [{decoded, _entries, _offset}]} ->
            decoded

          _ ->
            error(
              :xref,
              :invalid_pdf_input,
              "xref stream Length reference cannot be resolved safely",
              object: ref
            )
        end

      {:error, _} = candidate_error ->
        candidate_error
    end
  end

  defp xref_length_candidates(pdf, {object, generation}) do
    PdfValidator.charge_reader_budget(:max_pdf_reader_work, byte_size(pdf))
    whitespace = "[\\x00\\t\\n\\f\\r ]"

    {:ok, pattern} =
      Regex.compile(
        "(?:\\A|#{whitespace})(#{object}#{whitespace}+#{generation}#{whitespace}+obj\\b)"
      )

    with {:ok, offsets} <- xref_candidate_offsets(pdf, pattern, 0, [], 0) do
      candidates =
        Enum.reduce(offsets, [], fn offset, candidates ->
          case candidate_object_limit(pdf, offset) do
            {:ok, limit} ->
              case parse_indirect_object_at(pdf, offset, limit, {object, generation}) do
                {:ok, {^object, ^generation}, %{value: value, stream: nil} = candidate}
                when is_integer(value) and value >= 0 ->
                  [candidate | candidates]

                {:error, {:resource_limit_exceeded, _}} = error ->
                  PdfValidator.abort_reader_budget(error)

                _ ->
                  candidates
              end

            :error ->
              candidates
          end
        end)

      {:ok, Enum.reverse(candidates)}
    end
  end

  # Stop searching before constructing an unbounded list of candidate offsets.
  defp xref_candidate_offsets(pdf, pattern, position, offsets, count) do
    case Regex.run(pattern, pdf, offset: position, return: :index, capture: :all_but_first) do
      [{offset, length}] ->
        with :ok <- PdfValidator.validate_reader_size(count + 1, :max_pdf_xref_length_candidates) do
          xref_candidate_offsets(pdf, pattern, offset + length, [offset | offsets], count + 1)
        end

      nil ->
        {:ok, Enum.reverse(offsets)}
    end
  end

  defp candidate_object_limit(pdf, offset) do
    PdfValidator.charge_reader_budget(:max_pdf_reader_work, byte_size(pdf) - offset)
    tail = binary_part(pdf, offset, byte_size(pdf) - offset)

    case Regex.run(~r/\bendobj\b/, tail, return: :index) do
      [{end_offset, end_length}] -> {:ok, offset + end_offset + end_length}
      _ -> :error
    end
  end

  defp confirms_xref_length_candidate?(
         pdf,
         entries,
         bootstrap_entries,
         {object, generation},
         candidate_offset
       ) do
    expected_entries = [Map.get(entries, object), Map.get(bootstrap_entries, object)]

    Enum.any?(expected_entries, fn entry ->
      case entry do
        {:uncompressed, xref_offset, ^generation} ->
          xref_offset <= candidate_offset and
            pdf_whitespace_between?(pdf, xref_offset, candidate_offset)

        _ ->
          false
      end
    end)
  end

  defp pdf_whitespace_between?(pdf, first, last) do
    pdf
    |> binary_part(first, last - first)
    |> String.match?(~r/\A[\x00\t\n\f\r ]*\z/)
  end

  defp xref_stream_entries(data, dictionary) do
    size = Map.get(dictionary, "Size")
    widths = Map.get(dictionary, "W")
    index = Map.get(dictionary, "Index", if(is_integer(size), do: [0, size], else: nil))
    max_objects = Limits.get(:max_pdf_objects)

    with true <- is_integer(size) and size > 0 and size <= max_objects + 1,
         [type_width, field_width, generation_width] <- widths,
         true <-
           Enum.all?(
             [type_width, field_width, generation_width],
             &(is_integer(&1) and &1 >= 0)
           ),
         :ok <- PdfValidator.validate_reader_size(Enum.max(widths), :max_pdf_numeric_token_bytes),
         row_width when row_width > 0 <- type_width + field_width + generation_width,
         {:ok, object_numbers} <- xref_index_objects(index, size),
         true <- byte_size(data) == length(object_numbers) * row_width do
      object_numbers
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, %{}}, fn {object, row}, {:ok, entries} ->
        record = binary_part(data, row * row_width, row_width)

        case xref_stream_entry(record, type_width, field_width, generation_width) do
          {:ok, entry} -> {:cont, {:ok, Map.put(entries, object, entry)}}
          {:error, _} = entry_error -> {:halt, entry_error}
        end
      end)
    else
      {:error, _} = error -> error
      false -> error(:xref, :invalid_pdf_input, "xref stream dimensions are malformed")
      _ -> error(:xref, :invalid_pdf_input, "xref stream dictionary is malformed")
    end
  end

  defp xref_index_objects(index, size) do
    case index do
      index when is_list(index) and rem(length(index), 2) == 0 ->
        index
        |> Enum.chunk_every(2)
        |> Enum.reduce_while({:ok, [], MapSet.new()}, fn pair, {:ok, objects, seen} ->
          case pair do
            [first, count]
            when is_integer(first) and first >= 0 and is_integer(count) and count >= 0 and
                   first + count <= size ->
              PdfValidator.charge_reader_budget(:max_pdf_reader_values, count)
              range = if count == 0, do: [], else: Enum.to_list(first..(first + count - 1))

              if Enum.any?(range, &MapSet.member?(seen, &1)) do
                {:halt, error(:xref, :invalid_pdf_input, "xref stream Index ranges overlap")}
              else
                {:cont,
                 {:ok, Enum.reverse(range, objects),
                  Enum.reduce(range, seen, &MapSet.put(&2, &1))}}
              end

            _ ->
              {:halt, error(:xref, :invalid_pdf_input, "xref stream Index is malformed")}
          end
        end)
        |> case do
          {:ok, objects, _seen} -> {:ok, Enum.reverse(objects)}
          {:error, _} = index_error -> index_error
        end

      _ ->
        error(:xref, :invalid_pdf_input, "xref stream Index is malformed")
    end
  end

  defp xref_stream_entry(record, type_width, field_width, generation_width) do
    <<type_bytes::binary-size(^type_width), field_bytes::binary-size(^field_width),
      generation_bytes::binary-size(^generation_width)>> = record

    type = if type_width == 0, do: 1, else: :binary.decode_unsigned(type_bytes)
    field = if field_width == 0, do: 0, else: :binary.decode_unsigned(field_bytes)
    generation = if generation_width == 0, do: 0, else: :binary.decode_unsigned(generation_bytes)

    case type do
      0 when generation <= 65_535 ->
        {:ok, {:free, field, generation}}

      1 when generation <= 65_535 ->
        {:ok, {:uncompressed, field, generation}}

      type when type in [0, 1] ->
        error(:xref, :invalid_pdf_input, "xref stream generation is malformed")

      2 ->
        {:ok, {:compressed, field, generation}}

      _ ->
        error(:xref, :unsupported_pdf_feature, "xref stream entry type is unsupported")
    end
  end

  defp parse_optional_stream(tokens) do
    case tokens do
      [:stream, {:stream_data, stream}, :endstream | rest] -> {:ok, stream, rest}
      [:stream | _] -> :error
      rest -> {:ok, nil, rest}
    end
  end

  defp parse_value(tokens) do
    parse_value(tokens, 0)
  end

  defp parse_value(tokens, depth) do
    PdfValidator.charge_reader_budget(:max_pdf_reader_values, 1)

    case tokens do
      [{:int, first}, {:int, second}, :R | rest] ->
        {:ok, {:ref, {first, second}}, rest}

      [{:int, value} | rest] ->
        {:ok, value, rest}

      [{:real, value} | rest] ->
        {:ok, value, rest}

      [{:name, name} | rest] ->
        {:ok, {:name, name}, rest}

      [{:string, value} | rest] ->
        {:ok, {:string, value}, rest}

      [{:hex_string, value} | rest] ->
        {:ok, {:hex, value}, rest}

      [true | rest] ->
        {:ok, true, rest}

      [false | rest] ->
        {:ok, false, rest}

      [:null | rest] ->
        {:ok, nil, rest}

      [:lbracket | rest] ->
        with :ok <-
               PdfValidator.validate_value_depth(depth + 1,
                 operation: :read,
                 module: __MODULE__
               ) do
          parse_array(rest, [], depth + 1, 0)
        end

      [:dict_start | rest] ->
        with :ok <-
               PdfValidator.validate_value_depth(depth + 1,
                 operation: :read,
                 module: __MODULE__
               ) do
          parse_dictionary(rest, %{}, depth + 1, 0)
        end

      _ ->
        :error
    end
  end

  defp parse_array(tokens, values, depth, count) do
    case tokens do
      [:rbracket | rest] ->
        {:ok, Enum.reverse(values), rest}

      _ ->
        with :ok <- PdfValidator.validate_reader_size(count + 1, :max_pdf_container_entries),
             {:ok, value, rest} <- parse_value(tokens, depth) do
          parse_array(rest, [value | values], depth, count + 1)
        end
    end
  end

  defp parse_dictionary(tokens, dictionary, depth, count) do
    case tokens do
      [:dict_end | rest] ->
        {:ok, dictionary, rest}

      [{:name, key} | rest] ->
        with :ok <- PdfValidator.validate_reader_size(count + 1, :max_pdf_container_entries),
             {:ok, value, rest} <- parse_value(rest, depth) do
          parse_dictionary(rest, Map.put(dictionary, key, value), depth, count + 1)
        end

      _ ->
        :error
    end
  end

  defp load_objects(pdf, xref) do
    uncompressed =
      xref
      |> Enum.flat_map(fn
        {object, {:uncompressed, offset, generation}} -> [{offset, object, generation}]
        _ -> []
      end)
      |> Enum.sort()

    with {:ok, objects} <- load_uncompressed_objects(pdf, uncompressed, %{}),
         {:ok, objects} <-
           materialize_indirect_streams(pdf, objects, fn parsed ->
             name?(Map.get(parsed.value, "Type"), "ObjStm")
           end),
         {:ok, objects} <- load_compressed_objects(xref, objects),
         {:ok, objects} <-
           materialize_indirect_streams(pdf, objects, fn _parsed -> true end) do
      {:ok, objects}
    end
  end

  defp load_uncompressed_objects(pdf, pending, objects) do
    case pending do
      [] ->
        {:ok, objects}

      [{offset, object, generation} | rest] ->
        limit =
          case rest do
            [{next_offset, _next_object, _next_generation} | _] -> next_offset
            [] -> byte_size(pdf)
          end

        with {:ok, {^object, ^generation}, parsed} <-
               parse_indirect_object_at(pdf, offset, limit, {object, generation}) do
          load_uncompressed_objects(pdf, rest, Map.put(objects, {object, generation}, parsed))
        else
          {:ok, actual_ref, _parsed} ->
            error(
              :xref,
              :invalid_pdf_input,
              "xref entry points to object #{elem(actual_ref, 0)} #{elem(actual_ref, 1)} instead of #{object} #{generation}"
            )

          {:error, {reason, diagnostic}} ->
            {:error,
             {reason, Map.update!(diagnostic, :message, &"#{&1}; object #{object} #{generation}")}}
        end
    end
  end

  defp parse_indirect_object_at(pdf, offset, limit, _expected_ref) do
    if offset >= 0 and limit > offset and limit <= byte_size(pdf) do
      slice = binary_part(pdf, offset, limit - offset)
      header = Regex.run(~r/\A[\x00\t\n\f\r ]*(\d+)\s+(\d+)\s+obj\b/, slice)

      case header do
        [_, object_text, generation_text] ->
          object = PdfValidator.reader_integer(object_text)
          generation = PdfValidator.reader_integer(generation_text)
          ref = {object, generation}

          case indirect_stream_source(slice, offset, limit) do
            {:error, _} = error ->
              error

            {:ok, prefix, source} ->
              with true <- generation in 0..65_535,
                   [{:int, ^object}, {:int, ^generation}, :obj | body] <- prefix,
                   {:ok, value, [:stream]} <- parse_value(body),
                   true <- is_map(value),
                   true <- Map.get(value, "Length") == {:ref, source.length_ref} do
                {:ok, ref,
                 %{
                   value: value,
                   stream: nil,
                   offset: offset,
                   tokens: body,
                   pending_stream: source
                 }}
              else
                {:error, {_reason, _diagnostic}} = error -> error
                _ -> error(:object, :invalid_pdf_input, "indirect object boundary is malformed")
              end

            {:tokens, tokens} ->
              with [{:int, ^object}, {:int, ^generation}, :obj | body] <- tokens,
                   true <- generation in 0..65_535,
                   {:ok, value, value_rest} <- parse_value(body),
                   {:ok, stream, []} <- parse_optional_stream(value_rest) do
                {:ok, ref, %{value: value, stream: stream, offset: offset, tokens: body}}
              else
                {:error, {_reason, _diagnostic}} = error -> error
                _ -> error(:object, :invalid_pdf_input, "indirect object boundary is malformed")
              end
          end

        _ ->
          error(:object, :invalid_pdf_input, "xref offset does not point to an indirect object")
      end
    else
      error(:xref, :invalid_pdf_input, "indirect object offset is outside the PDF")
    end
  end

  defp take_indirect_object_tokens(tokenizer, tokens) do
    case Tokenizer.next(tokenizer) do
      {:error, _} = error -> tokenizer_error(error, :object)
      {:endobj, _tokenizer} -> {:ok, Enum.reverse(tokens)}
      {{:eof, nil}, _tokenizer} -> :error
      {token, tokenizer} -> take_indirect_object_tokens(tokenizer, [token | tokens])
    end
  end

  defp indirect_stream_source(slice, offset, limit) do
    slice
    |> Tokenizer.new()
    |> find_indirect_stream([], offset, limit)
  end

  defp find_indirect_stream(tokenizer, tokens, offset, limit) do
    with {token, %Tokenizer{} = tokenizer} <- Tokenizer.next(tokenizer) do
      case token do
        :stream ->
          case Tokenizer.pending_stream_length(tokenizer) do
            {:indirect, length_ref} ->
              {{_stream_data, span}, _tokenizer} = Tokenizer.next_with_span(tokenizer)

              {:ok, Enum.reverse([:stream | tokens]),
               %{from: offset + span.from, limit: limit, length_ref: length_ref}}

            _ ->
              case take_indirect_object_tokens(tokenizer, [:stream | tokens]) do
                {:ok, tokens} ->
                  {:tokens, tokens}

                {:error, _} = error ->
                  error

                :error ->
                  error(:object, :invalid_pdf_input, "indirect object boundary is malformed")
              end
          end

        :endobj ->
          {:tokens, Enum.reverse(tokens)}

        {:eof, nil} ->
          error(:object, :invalid_pdf_input, "indirect object boundary is malformed")

        _ ->
          find_indirect_stream(tokenizer, [token | tokens], offset, limit)
      end
    else
      {:error, _} = error -> tokenizer_error(error, :object)
    end
  end

  defp materialize_indirect_streams(pdf, objects, selected?) do
    Enum.reduce_while(objects, {:ok, %{}}, fn {ref, parsed}, {:ok, resolved} ->
      case Map.pop(parsed, :pending_stream) do
        {nil, parsed} ->
          {:cont, {:ok, Map.put(resolved, ref, parsed)}}

        {source, parsed} ->
          case selected?.(parsed) do
            true ->
              case materialize_indirect_stream(pdf, objects, ref, parsed, source) do
                {:ok, parsed} -> {:cont, {:ok, Map.put(resolved, ref, parsed)}}
                {:error, _} = stream_error -> {:halt, stream_error}
              end

            false ->
              parsed = Map.put(parsed, :pending_stream, source)
              {:cont, {:ok, Map.put(resolved, ref, parsed)}}
          end
      end
    end)
  end

  defp materialize_indirect_stream(pdf, objects, ref, parsed, source) do
    result =
      PdfValidator.resolve(%{objects: objects}, {:ref, source.length_ref},
        operation: :read,
        module: __MODULE__
      )

    case result do
      {:ok, length} when is_integer(length) and length >= 0 ->
        with true <- source.from + length <= source.limit,
             data <- binary_part(pdf, source.from, length),
             tail_length = source.limit - source.from - length,
             tail <- binary_part(pdf, source.from + length, tail_length),
             tokenizer = Tokenizer.new(tail),
             {:endstream, tokenizer} <- Tokenizer.next(tokenizer),
             {:endobj, _tokenizer} <- Tokenizer.next(tokenizer) do
          {:ok,
           %{
             parsed
             | stream: data,
               tokens: parsed.tokens ++ [{:stream_data, data}, :endstream]
           }}
        else
          {:error, _} = error ->
            tokenizer_error(error, :object)

          _ ->
            error(
              :object,
              :invalid_pdf_input,
              "indirect stream boundary does not match its Length",
              object: ref
            )
        end

      _ ->
        error(
          :object,
          :invalid_pdf_input,
          "indirect stream Length does not resolve to a non-negative integer",
          object: ref
        )
    end
  end

  defp load_compressed_objects(xref, objects) do
    xref
    |> Enum.flat_map(fn
      {object, {:compressed, object_stream, index}} -> [{object, object_stream, index}]
      _ -> []
    end)
    |> Enum.group_by(fn {_object, object_stream, _index} -> object_stream end)
    |> Enum.reduce_while({:ok, objects}, fn {object_stream, requested}, {:ok, objects} ->
      with {:ok, stream_ref} <- object_stream_ref(xref, object_stream),
           %{value: dictionary, stream: stream} <- Map.get(objects, stream_ref),
           true <-
             is_map(dictionary) and is_binary(stream) and
               name?(Map.get(dictionary, "Type"), "ObjStm"),
           {:ok, stream_context} <-
             PdfValidator.prepare_decoded_stream(%{objects: objects}, {:ref, stream_ref},
               operation: :read,
               module: __MODULE__
             ),
           {:ok, decoded} <- decode_stream(stream, stream_context.filters, stream_ref),
           {:ok, contained} <- parse_object_stream(decoded, dictionary, stream_ref),
           {:ok, objects} <- add_compressed_objects(requested, contained, objects, stream_ref) do
        {:cont, {:ok, objects}}
      else
        {:error, _} = stream_error ->
          {:halt, stream_error}

        _ ->
          {:halt,
           error(:object_stream, :invalid_pdf_input, "object stream is malformed",
             object: {object_stream, 0}
           )}
      end
    end)
  end

  defp object_stream_ref(xref, object_stream) do
    case Map.get(xref, object_stream) do
      {:uncompressed, _offset, generation} -> {:ok, {object_stream, generation}}
      _ -> error(:object_stream, :invalid_pdf_input, "object stream has no direct xref entry")
    end
  end

  defp parse_object_stream(data, dictionary, ref) do
    with {:ok, %{count: count, first: first}} <-
           PdfValidator.validate_object_stream_header(dictionary, byte_size(data), ref,
             operation: :read,
             module: __MODULE__
           ),
         :ok <- PdfValidator.charge_reader_budget(:max_pdf_reader_work, first),
         header <- binary_part(data, 0, first),
         tokens when is_list(tokens) <- Tokenizer.new(header) |> Tokenizer.tokenize_all(),
         true <- length(tokens) == count * 2,
         true <- Enum.all?(tokens, &match?({:int, number} when number >= 0, &1)) do
      pairs = tokens |> Enum.map(fn {:int, value} -> value end) |> Enum.chunk_every(2)

      pairs
      |> Enum.reverse()
      |> Enum.reduce_while(
        {:ok, %{}, MapSet.new(), count - 1, byte_size(data) - first},
        fn [object, relative_offset], {:ok, acc, seen, index, next_offset} ->
          length = next_offset - relative_offset

          if length >= 0 and first + relative_offset + length <= byte_size(data) do
            slice = binary_part(data, first + relative_offset, length)

            with tokens when is_list(tokens) <- Tokenizer.new(slice) |> Tokenizer.tokenize_all() do
              case parse_value(tokens) do
                {:ok, value, []} when object > 0 ->
                  case MapSet.member?(seen, object) do
                    false ->
                      parsed = %{value: value, stream: nil, offset: nil, tokens: tokens}

                      {:cont,
                       {:ok, Map.put(acc, index, {object, parsed}), MapSet.put(seen, object),
                        index - 1, relative_offset}}

                    true ->
                      {:halt,
                       error(:object_stream, :invalid_pdf_input, "compressed object is malformed",
                         object: ref
                       )}
                  end

                {:error, {_reason, _diagnostic}} = error ->
                  {:halt, error}

                _ ->
                  {:halt,
                   error(:object_stream, :invalid_pdf_input, "compressed object is malformed",
                     object: ref
                   )}
              end
            else
              {:error, _} = error -> {:halt, tokenizer_error(error, :object_stream)}
            end
          else
            {:halt,
             error(:object_stream, :invalid_pdf_input, "compressed object offset is invalid",
               object: ref
             )}
          end
        end
      )
      |> case do
        {:ok, contained, _seen, _index, _next_offset} -> {:ok, contained}
        {:error, _} = object_stream_error -> object_stream_error
      end
    else
      {:error, _} = validation_error ->
        validation_error

      _ ->
        error(:object_stream, :invalid_pdf_input, "object stream header is invalid", object: ref)
    end
  end

  defp add_compressed_objects(requested, contained, objects, stream_ref) do
    Enum.reduce_while(requested, {:ok, objects}, fn {object, _object_stream, index},
                                                    {:ok, objects} ->
      case Map.fetch(contained, index) do
        {:ok, {^object, parsed}} ->
          {:cont, {:ok, Map.put(objects, {object, 0}, parsed)}}

        _ ->
          {:halt,
           error(
             :object_stream,
             :invalid_pdf_input,
             "compressed xref entry does not match object stream index #{index}",
             object: stream_ref
           )}
      end
    end)
  end

  defp decode_stream(stream, filters, ref) do
    if filters == [] do
      PdfValidator.charge_reader_budget(:max_pdf_reader_decoded_bytes, byte_size(stream))
    end

    with {:ok, decoded} <-
           Enum.reduce_while(filters, {:ok, stream}, &decode_filter(&1, &2, ref)),
         :ok <- validate_decoded_size(stream, decoded) do
      {:ok, decoded}
    else
      {:error, _} = error -> error
    end
  end

  defp decode_filter(%{name: filter, parameters: parameters}, {:ok, data}, ref) do
    PdfValidator.charge_reader_budget(:max_pdf_reader_work, byte_size(data))

    result =
      case filter do
        "FlateDecode" ->
          inflate(data, ref)

        "ASCIIHexDecode" ->
          ascii_hex(data, ref)

        "ASCII85Decode" ->
          ascii85(data, ref)

        "RunLengthDecode" ->
          run_length(data, ref)

        "LZWDecode" ->
          lzw(data, parameters, ref)
      end

    with {:ok, data} <- result,
         :ok <- PdfValidator.charge_reader_budget(:max_pdf_reader_decoded_bytes, byte_size(data)),
         :ok <- PdfValidator.charge_reader_budget(:max_pdf_reader_work, byte_size(data)),
         {:ok, data} <- apply_predictor(data, parameters, ref) do
      {:cont, {:ok, data}}
    else
      {:error, _} = error -> {:halt, error}
    end
  end

  defp inflate(data, ref) do
    zlib = :zlib.open()

    try do
      :ok = :zlib.inflateInit(zlib)

      limit =
        min(
          min(
            Limits.get(:max_pdf_decoded_stream_bytes),
            PdfValidator.remaining_reader_decoded_bytes()
          ),
          max(byte_size(data) * Limits.get(:max_pdf_decompression_ratio), 1)
        )

      inflate_chunks(zlib, data, limit, 0, [], ref)
    rescue
      _ -> error(:filter, :invalid_pdf_input, "FlateDecode data is invalid", object: ref)
    after
      :zlib.close(zlib)
    end
  end

  defp inflate_chunks(zlib, data, limit, decoded_size, decoded, ref) do
    # safeInflate returns at most one bounded zlib output buffer per call.
    {status, output} = :zlib.safeInflate(zlib, data)
    decoded_size = decoded_size + IO.iodata_length(output)

    cond do
      decoded_size > limit ->
        decoded_stream_limit_error(ref)

      status == :finished ->
        :ok = :zlib.inflateEnd(zlib)
        {:ok, IO.iodata_to_binary(Enum.reverse([output | decoded]))}

      true ->
        inflate_chunks(zlib, <<>>, limit, decoded_size, [output | decoded], ref)
    end
  end

  defp decoded_stream_limit_error(ref) do
    error(:limits, :resource_limit_exceeded, "decoded stream exceeds its safety limit",
      object: ref
    )
  end

  defp ascii_hex(data, ref) do
    decode_ascii_hex(data, nil, [], 0, ref)
  end

  defp decode_ascii_hex(bytes, high, acc, size, ref) do
    case bytes do
      <<byte, rest::binary>> when byte in [0, 9, 10, 12, 13, 32] ->
        decode_ascii_hex(rest, high, acc, size, ref)

      <<?>, _rest::binary>> ->
        with :ok <- PdfValidator.validate_reader_decoded_size(size + if(high, do: 1, else: 0)) do
          acc = if high, do: [<<high * 16>> | acc], else: acc
          {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}
        end

      <<byte, rest::binary>> ->
        cond do
          not hex_digit?(byte) ->
            error(:filter, :invalid_pdf_input, "ASCIIHexDecode data contains a non-hex digit",
              object: ref
            )

          is_nil(high) ->
            decode_ascii_hex(rest, hex_value(byte), acc, size, ref)

          true ->
            with :ok <- PdfValidator.validate_reader_decoded_size(size + 1) do
              decode_ascii_hex(rest, nil, [<<high * 16 + hex_value(byte)>> | acc], size + 1, ref)
            end
        end

      <<>> ->
        error(:filter, :invalid_pdf_input, "ASCIIHexDecode data is missing its terminator",
          object: ref
        )
    end
  end

  defp ascii85(data, ref) do
    case data do
      <<byte, rest::binary>> when byte in [0, 9, 10, 12, 13, 32] -> ascii85(rest, ref)
      <<"<~", rest::binary>> -> decode_ascii85(rest, [], [], ref, 0)
      _ -> decode_ascii85(data, [], [], ref, 0)
    end
  end

  defp decode_ascii85(bytes, group, acc, ref, size) do
    case bytes do
      <<byte, rest::binary>> when byte in [0, 9, 10, 12, 13, 32] ->
        decode_ascii85(rest, group, acc, ref, size)

      <<"~>", _rest::binary>> ->
        case group do
          [] ->
            {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}

          [_byte] ->
            error(:filter, :invalid_pdf_input, "ASCII85Decode final group is too short",
              object: ref
            )

          group ->
            group = Enum.reverse(group)
            padded = group ++ List.duplicate(?u, 5 - length(group))

            with :ok <- PdfValidator.validate_reader_decoded_size(size + length(group) - 1),
                 {:ok, decoded} <- decode_ascii85_group(padded, ref) do
              {:ok,
               [binary_part(decoded, 0, length(group) - 1) | acc]
               |> Enum.reverse()
               |> IO.iodata_to_binary()}
            end
        end

      <<?z, rest::binary>> ->
        case group do
          [] ->
            with :ok <- PdfValidator.validate_reader_decoded_size(size + 4) do
              decode_ascii85(rest, [], [<<0, 0, 0, 0>> | acc], ref, size + 4)
            end

          _group ->
            error(:filter, :invalid_pdf_input, "ASCII85Decode z appears inside a group",
              object: ref
            )
        end

      <<byte, rest::binary>> ->
        case byte in 33..117 do
          true ->
            group = [byte | group]

            case length(group) == 5 do
              true ->
                with :ok <- PdfValidator.validate_reader_decoded_size(size + 4),
                     {:ok, decoded} <- decode_ascii85_group(Enum.reverse(group), ref) do
                  decode_ascii85(rest, [], [decoded | acc], ref, size + 4)
                end

              false ->
                decode_ascii85(rest, group, acc, ref, size)
            end

          false ->
            error(:filter, :invalid_pdf_input, "ASCII85Decode byte is out of range", object: ref)
        end

      <<>> ->
        error(:filter, :invalid_pdf_input, "ASCII85Decode data is missing its terminator",
          object: ref
        )
    end
  end

  defp decode_ascii85_group(group, ref) do
    value = Enum.reduce(group, 0, fn byte, value -> value * 85 + byte - 33 end)

    case value <= 0xFFFFFFFF do
      true ->
        {:ok, <<value::unsigned-big-integer-size(32)>>}

      false ->
        error(
          :filter,
          :invalid_pdf_input,
          "ASCII85Decode group exceeds the 32-bit range",
          object: ref
        )
    end
  end

  defp run_length(data, ref) do
    limit =
      min(
        min(
          Limits.get(:max_pdf_decoded_stream_bytes),
          PdfValidator.remaining_reader_decoded_bytes()
        ),
        max(byte_size(data) * Limits.get(:max_pdf_decompression_ratio), 1)
      )

    decode_run_length(data, 0, limit, [], ref)
  end

  defp decode_run_length(bytes, decoded_size, limit, acc, ref) do
    case bytes do
      <<128, _rest::binary>> ->
        {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}

      <<>> ->
        error(:filter, :invalid_pdf_input, "RunLengthDecode data has no end marker", object: ref)

      <<length, rest::binary>> when length <= 127 ->
        count = length + 1

        if byte_size(rest) >= count do
          <<literal::binary-size(^count), rest::binary>> = rest
          decoded_size = decoded_size + count

          if decoded_size > limit do
            decoded_stream_limit_error(ref)
          else
            decode_run_length(rest, decoded_size, limit, [literal | acc], ref)
          end
        else
          error(:filter, :invalid_pdf_input, "RunLengthDecode literal run is truncated",
            object: ref
          )
        end

      <<length, byte, rest::binary>> ->
        count = 257 - length
        decoded_size = decoded_size + count

        if decoded_size > limit do
          decoded_stream_limit_error(ref)
        else
          decode_run_length(
            rest,
            decoded_size,
            limit,
            [:binary.copy(<<byte>>, count) | acc],
            ref
          )
        end

      _ ->
        error(:filter, :invalid_pdf_input, "RunLengthDecode repeat run is truncated", object: ref)
    end
  end

  defp lzw(data, parameters, ref) do
    decode_lzw(data, parameters["EarlyChange"], ref)
  end

  defp decode_lzw(data, early_change, ref) do
    dictionary = Enum.into(0..255, %{}, fn value -> {value, <<value>>} end)

    limit =
      min(
        min(
          Limits.get(:max_pdf_decoded_stream_bytes),
          PdfValidator.remaining_reader_decoded_bytes()
        ),
        max(byte_size(data) * Limits.get(:max_pdf_decompression_ratio), 1)
      )

    decode_lzw_bits(data, 0, 9, dictionary, 258, nil, early_change, 0, limit, [], ref)
  end

  defp decode_lzw_bits(
         data,
         bit_offset,
         width,
         dictionary,
         next_code,
         previous,
         early_change,
         decoded_size,
         limit,
         acc,
         ref
       ) do
    if bit_offset + width > bit_size(data) do
      error(:filter, :invalid_pdf_input, "LZWDecode data ends before its end code", object: ref)
    else
      <<_::bitstring-size(^bit_offset), code::unsigned-big-integer-size(^width), _::bitstring>> =
        data

      case code do
        256 ->
          decode_lzw_bits(
            data,
            bit_offset + width,
            9,
            Enum.into(0..255, %{}, fn value -> {value, <<value>>} end),
            258,
            nil,
            early_change,
            decoded_size,
            limit,
            acc,
            ref
          )

        257 ->
          {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}

        _ ->
          value =
            case Map.fetch(dictionary, code) do
              {:ok, value} ->
                value

              :error when is_binary(previous) and code == next_code ->
                previous <> binary_part(previous, 0, 1)

              :error ->
                nil
            end

          if is_binary(value) do
            decoded_size = decoded_size + byte_size(value)

            if decoded_size > limit do
              error(:limits, :resource_limit_exceeded, "decoded stream exceeds its safety limit",
                object: ref
              )
            else
              {dictionary, next_code} =
                if previous && next_code < 4096 do
                  {Map.put(dictionary, next_code, previous <> binary_part(value, 0, 1)),
                   next_code + 1}
                else
                  {dictionary, next_code}
                end

              next_width =
                if width < 12 and next_code + early_change == 1 <<< width,
                  do: width + 1,
                  else: width

              decode_lzw_bits(
                data,
                bit_offset + width,
                next_width,
                dictionary,
                next_code,
                value,
                early_change,
                decoded_size,
                limit,
                [value | acc],
                ref
              )
            end
          else
            error(:filter, :invalid_pdf_input, "LZWDecode dictionary reference is invalid",
              object: ref
            )
          end
      end
    end
  end

  defp apply_predictor(data, parameters, ref) do
    case parameters["Predictor"] do
      1 ->
        {:ok, data}

      2 ->
        tiff_predictor(data, parameters, ref)

      _predictor ->
        png_predictor(data, parameters, ref)
    end
  end

  defp tiff_predictor(data, parameters, ref) do
    with {:ok, row_bytes, _bytes_per_pixel} <- predictor_dimensions(parameters, ref),
         true <- rem(byte_size(data), row_bytes) == 0 do
      colors = Map.get(parameters, "Colors", 1)
      bits = Map.get(parameters, "BitsPerComponent", 8)
      columns = Map.get(parameters, "Columns", 1)

      rows =
        for <<row::binary-size(^row_bytes) <- data>>,
          do: tiff_row(row, colors, bits, columns)

      {:ok, IO.iodata_to_binary(rows)}
    else
      false ->
        error(:filter, :invalid_pdf_input, "TIFF predictor rows are truncated", object: ref)

      {:error, _} = error ->
        error
    end
  end

  defp tiff_row(row, colors, bits, columns) do
    sample_count = colors * columns
    sample_bits = sample_count * bits
    padding_bits = bit_size(row) - sample_bits
    <<samples::bitstring-size(^sample_bits), padding::bitstring-size(^padding_bits)>> = row

    {decoded, _values} =
      samples
      |> then(fn samples -> for <<sample::unsigned-big-size(^bits) <- samples>>, do: sample end)
      |> Enum.with_index()
      |> Enum.reduce({[], %{}}, fn {sample, index}, {decoded, values} ->
        value = rem(sample + Map.get(values, index - colors, 0), 1 <<< bits)
        {[value | decoded], Map.put(values, index, value)}
      end)

    decoded
    |> Enum.reverse()
    |> Enum.reduce(<<>>, fn sample, row ->
      <<row::bitstring, sample::unsigned-big-size(bits)>>
    end)
    |> then(fn decoded -> <<decoded::bitstring, padding::bitstring>> end)
  end

  defp png_predictor(data, parameters, ref) do
    with {:ok, row_bytes, bytes_per_pixel} <- predictor_dimensions(parameters, ref) do
      cond do
        data == <<>> ->
          {:ok, <<>>}

        byte_size(data) <= row_bytes ->
          error(:filter, :invalid_pdf_input, "PNG predictor rows are truncated", object: ref)

        true ->
          decode_png_rows(
            data,
            row_bytes,
            bytes_per_pixel,
            :binary.copy(<<0>>, row_bytes),
            [],
            ref
          )
      end
    end
  end

  defp decode_png_rows(data, row_bytes, bytes_per_pixel, previous, acc, ref) do
    case data do
      <<>> ->
        {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}

      _ ->
        if byte_size(data) >= row_bytes + 1 do
          <<filter, encoded::binary-size(^row_bytes), rest::binary>> = data

          case png_row(filter, encoded, previous, bytes_per_pixel) do
            {:ok, row} ->
              decode_png_rows(rest, row_bytes, bytes_per_pixel, row, [row | acc], ref)

            :error ->
              error(:filter, :invalid_pdf_input, "PNG predictor row has an invalid filter",
                object: ref
              )
          end
        else
          error(:filter, :invalid_pdf_input, "PNG predictor rows are truncated", object: ref)
        end
    end
  end

  defp png_row(filter, encoded, previous, bytes_per_pixel) do
    case filter do
      filter when filter in 0..4 ->
        encoded
        |> :binary.bin_to_list()
        |> Enum.with_index()
        |> Enum.reduce({[], %{}}, fn {byte, index}, {decoded, values} ->
          left = Map.get(values, index - bytes_per_pixel, 0)
          up = :binary.at(previous, index)

          up_left =
            if index < bytes_per_pixel,
              do: 0,
              else: :binary.at(previous, index - bytes_per_pixel)

          value =
            case filter do
              0 -> byte
              1 -> rem(byte + left, 256)
              2 -> rem(byte + up, 256)
              3 -> rem(byte + div(left + up, 2), 256)
              4 -> rem(byte + paeth(left, up, up_left), 256)
            end

          {[value | decoded], Map.put(values, index, value)}
        end)
        |> then(fn {decoded, _values} ->
          {:ok, decoded |> Enum.reverse() |> :erlang.list_to_binary()}
        end)

      _ ->
        :error
    end
  end

  defp paeth(left, up, up_left) do
    prediction = left + up - up_left

    distances = [
      {abs(prediction - left), left},
      {abs(prediction - up), up},
      {abs(prediction - up_left), up_left}
    ]

    distances |> Enum.min_by(fn {distance, _} -> distance end) |> elem(1)
  end

  defp predictor_dimensions(parameters, ref) do
    colors = parameters["Colors"]
    bits = parameters["BitsPerComponent"]
    columns = parameters["Columns"]
    row_bytes = div(colors * columns * bits + 7, 8)

    case row_bytes <= Limits.get(:max_pdf_decoded_stream_bytes) do
      true ->
        {:ok, row_bytes, max(1, div(colors * bits + 7, 8))}

      false ->
        error(
          :limits,
          :resource_limit_exceeded,
          "predictor row exceeds the decoded-stream safety limit",
          object: ref
        )
    end
  end

  defp validate_decoded_size(input, decoded) do
    cond do
      byte_size(decoded) > Limits.get(:max_pdf_decoded_stream_bytes) ->
        error(:limits, :resource_limit_exceeded, "decoded stream exceeds the byte limit")

      byte_size(input) > 0 and
          byte_size(decoded) > byte_size(input) * Limits.get(:max_pdf_decompression_ratio) ->
        error(:limits, :resource_limit_exceeded, "stream decompression ratio exceeds the limit")

      true ->
        :ok
    end
  end

  defp name?(value, expected) do
    match?({:name, ^expected}, value)
  end

  defp hex_digit?(byte), do: byte in ?0..?9 or byte in ?A..?F or byte in ?a..?f

  defp hex_value(byte) do
    cond do
      byte in ?0..?9 -> byte - ?0
      byte in ?A..?F -> byte - ?A + 10
      true -> byte - ?a + 10
    end
  end

  # Keep the reader's public reason while retaining the tokenizer's explanation and location.
  defp tokenizer_error({:error, {reason, diagnostic}}, stage) do
    if reason == :resource_limit_exceeded do
      {:error, {reason, %{diagnostic | operation: :read, module: __MODULE__}}}
    else
      {:error,
       {:invalid_pdf_input,
        %{
          diagnostic
          | reason: :invalid_pdf_input,
            stage: stage,
            operation: :read,
            module: __MODULE__
        }}}
    end
  end

  defp error(stage, reason, message, details \\ []) do
    {pdf_details, diagnostic_options} = Keyword.split(details, [:object])

    message =
      Enum.reduce(pdf_details, message, fn {:object, {object, generation}}, message ->
        "#{message}; object #{object} #{generation}"
      end)

    Diagnostics.error(
      stage,
      reason,
      message,
      Keyword.merge([operation: :read, module: __MODULE__], diagnostic_options)
    )
  end
end
