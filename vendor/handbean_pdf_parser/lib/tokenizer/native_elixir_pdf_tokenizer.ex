defmodule NativeElixirPdfUtilities.Tokenizer do
  @moduledoc """
  A PDF tokenizer in pure Elixir.

  Produces a stream of tokens from a PDF byte stream. It skips whitespace and comments.
  It recognizes:
    * numbers (integers and reals)
    * keywords: `obj`, `endobj`, `stream`, `endstream`, `xref`, `trailer`, `startxref`
    * booleans `true`/`false`, `null`
    * names `/Name` (with `#xx` hex escapes decoded)
    * strings: literal `( ... )` with escapes and nesting; hex `<...>`
    * punctuation: `[` `]` `<<` `>>` and `R`
    * operators: any other keyword returned as `{:op, word}`

  Streams:
    * After emitting `:stream`, the next token is `{:stream_data, binary}` either read by
      the preceding dictionary `/Length` (if an integer) or by scanning until `endstream`.
    * The tokenizer does not resolve indirect `/Length` references.

  Token-reading functions return `{:error, {reason, diagnostic}}` on invalid syntax.
  Bulk calls stop at the first error instead of returning partial tokens.
  Diagnostic lines and byte columns are one-based; byte offsets in messages are
  zero-based. All positions refer to the binary passed to `new/1`.
  """

  alias NativeElixirPdfUtilities.Validators.PdfValidator
  alias NativeElixirPdfUtilities.Diagnostics

  defstruct bin: <<>>,
            pos: 0,
            size: 0,
            dict_depth: 0,
            length_scopes: [],
            last_length: nil,
            last_length_ref: nil,
            in_stream: false

  @type t :: %__MODULE__{bin: binary(), pos: non_neg_integer(), size: non_neg_integer()}

  @type token ::
          {:int, integer()}
          | {:real, float()}
          | {:name, binary()}
          | {:string, binary()}
          | {:hex_string, binary()}
          | {:stream_data, binary()}
          | {:op, binary()}
          | :null
          | true
          | false
          | :lbracket
          | :rbracket
          | :dict_start
          | :dict_end
          | :obj
          | :endobj
          | :stream
          | :endstream
          | :xref
          | :trailer
          | :startxref
          | :R
          | {:eof, nil}

  @type error_reason ::
          :resource_limit_exceeded
          | :unexpected_char
          | :unexpected_gt
          | :not_a_number
          | :unterminated_literal_string
          | :unterminated_hex_string
          | :invalid_hex_string
  @type tokenizer_error :: {:error, {error_reason(), Diagnostics.diagnostic()}}

  # NUL, HT, LF, FF, CR, SP
  @whitespace [0, 9, 10, 12, 13, 32]
  @delims ~c"()<>[]{}/%"
  @pdf_integer ~r/\A[+-]?[0-9]+\z/
  @pdf_real ~r/\A[+-]?(?:[0-9]+\.[0-9]*|\.[0-9]+)\z/

  @doc """
  Initialize the tokenizer from a binary.
  """
  @spec new(binary()) :: t()
  def new(bin) do
    case bin do
      bin when is_binary(bin) -> %__MODULE__{bin: bin, pos: 0, size: byte_size(bin)}
    end
  end

  @doc """
  Return the next token and updated tokenizer state.
  """
  @spec next(t()) :: {token(), t()} | tokenizer_error()
  def next(%__MODULE__{} = st) do
    result =
      if st.in_stream do
        return_stream_data(st)
      else
        st = skip_ws_and_comments(st)

        if st.pos >= st.size do
          {{:eof, nil}, st}
        else
          case byte_at(st) do
            ?/ ->
              parse_name(st)

            ?( ->
              parse_literal_string(st)

            ?< ->
              parse_lt(st)

            ?> ->
              parse_gt(st)

            ?[ ->
              {:lbracket, bump(st, 1)}

            ?] ->
              {:rbracket, bump(st, 1)}

            c when c in [?', ?"] ->
              {{:op, <<c>>}, bump(st, 1)}

            c when (c >= ?0 and c <= ?9) or c == ?+ or c == ?- or c == ?. ->
              parse_number_or_keyword(st)

            c when (c >= ?A and c <= ?Z) or (c >= ?a and c <= ?z) ->
              parse_keyword(st)

            _ ->
              {{:error, {:unexpected_char, byte_at(st), st.pos}}, bump(st, 1)}
          end
        end
      end

    case result do
      {:error, _} = error ->
        error

      {{:error, failure}, _state} ->
        lexical_error(failure, st.bin)

      {token, state} = success ->
        PdfValidator.charge_reader_budget(:max_pdf_reader_work, state.pos - st.pos)
        if token != {:eof, nil}, do: PdfValidator.charge_reader_budget(:max_pdf_reader_tokens, 1)
        success
    end
  end

  @doc """
  Return the next token along with its byte span in the original binary.

  The span is a map with `:from` and `:to` (exclusive end index). For `{:stream_data, _}`
  tokens, `from` excludes the EOL after the `stream` keyword.
  """
  @spec next_with_span(t()) ::
          {{token(),
            %{from: non_neg_integer(), to: non_neg_integer(), stream_mode?: atom() | nil}}, t()}
          | tokenizer_error()
  def next_with_span(%__MODULE__{} = st) do
    if st.in_stream do
      # compute start after the single EOL that precedes stream data
      start = st.pos + eol_len_at_pos(st)
      mode = if is_integer(st.last_length) and st.last_length >= 0, do: :length, else: :scanned
      {tok, st2} = return_stream_data(st)
      PdfValidator.charge_reader_budget(:max_pdf_reader_work, st2.pos - st.pos)
      PdfValidator.charge_reader_budget(:max_pdf_reader_tokens, 1)
      {{tok, %{from: start, to: st2.pos, stream_mode?: mode}}, st2}
    else
      st_ws = skip_ws_and_comments(st)
      start = st_ws.pos

      case next(st) do
        {:error, _} = error -> error_operation(error, :next_with_span)
        {tok, st2} -> {{tok, %{from: start, to: st2.pos, stream_mode?: nil}}, st2}
      end
    end
  end

  @doc """
  Look at the next token without advancing the tokenizer state.
  """
  @spec peek(t()) :: token() | tokenizer_error()
  def peek(%__MODULE__{} = st) do
    case next(st) do
      {:error, _} = error -> error_operation(error, :peek)
      {tok, _state} -> tok
    end
  end

  @doc """
  Tokenize the entire binary, returning a list of tokens.
  """
  @spec tokenize_all(t()) :: [token()] | tokenizer_error()
  def tokenize_all(%__MODULE__{} = st) do
    collect_tokens(st, :tokenize_all, [])
  end

  @doc """
  Tokenize the entire binary, returning a list of {token, span}.
  """
  @spec tokenize_all_with_spans(t()) ::
          [
            {token(),
             %{from: non_neg_integer(), to: non_neg_integer(), stream_mode?: atom() | nil}}
          ]
          | tokenizer_error()
  def tokenize_all_with_spans(%__MODULE__{} = st) do
    collect_tokens(st, :tokenize_all_with_spans, [])
  end

  defp collect_tokens(st, operation, tokens) do
    result = if operation == :tokenize_all, do: next(st), else: next_with_span(st)

    case result do
      {:error, _} = error -> error_operation(error, operation)
      {{:eof, nil}, _state} -> Enum.reverse(tokens)
      {{{:eof, nil}, _span}, _state} -> Enum.reverse(tokens)
      {token, state} -> collect_tokens(state, operation, [token | tokens])
    end
  end

  defp error_operation({:error, {reason, diagnostic}}, operation) do
    {:error, {reason, Map.put(diagnostic, :operation, operation)}}
  end

  defp lexical_error(failure, bin) do
    {reason, position, message} =
      case failure do
        {:unexpected_char, byte, position} ->
          {:unexpected_char, position, "unexpected byte #{inspect(<<byte>>)}"}

        {:unexpected_gt, position} ->
          {:unexpected_gt, position, "unexpected >; close a dictionary with >>"}

        {:not_a_number, word, position} ->
          {:not_a_number, position, "invalid or unrepresentable PDF number #{inspect(word)}"}

        {:unterminated_literal_string, position} ->
          {:unterminated_literal_string, position, "literal string is missing its closing )"}

        {:unterminated_hex_string, position} ->
          {:unterminated_hex_string, position, "hex string is missing its closing >"}

        {:invalid_hex_string, position} ->
          {:invalid_hex_string, position, "hex string contains a non-hexadecimal byte"}
      end

    newlines = :binary.matches(binary_part(bin, 0, position), ["\r\n", "\r", "\n"])

    line_start =
      case List.last(newlines) do
        nil -> 0
        {offset, length} -> offset + length
      end

    Diagnostics.error(:tokenizer, reason, "#{message}; tokenizer input byte #{position}",
      operation: :next,
      module: __MODULE__,
      line: length(newlines) + 1,
      column: position - line_start + 1
    )
  end

  @doc """
  If called after a `:stream` token, returns a hint for the stream length:
  - `{:direct, int}` when `/Length` was a direct integer
  - `{:indirect, {obj, gen}}` when `/Length` was an indirect reference
  - `:unknown` when no hint is available
  """
  @spec pending_stream_length(t()) ::
          {:direct, non_neg_integer()} | {:indirect, {integer(), integer()}} | :unknown
  def pending_stream_length(%__MODULE__{} = st) do
    cond do
      is_integer(st.last_length) and st.last_length >= 0 ->
        {:direct, st.last_length}

      match?({a, b} when is_integer(a) and is_integer(b), st.last_length_ref) ->
        {:indirect, st.last_length_ref}

      true ->
        :unknown
    end
  end

  # ===== Core scanning helpers =====

  # Skip whitespace and comments from the current position.
  defp skip_ws_and_comments(%__MODULE__{} = st) do
    do_skip(st)
  end

  # skip whitespace and comments
  defp do_skip(%__MODULE__{} = st) do
    if st.pos >= st.size do
      st
    else
      b = byte_at(st)

      cond do
        b in @whitespace -> do_skip(bump(st, 1))
        b == ?% -> do_skip(skip_comment(st))
        true -> st
      end
    end
  end

  # Skip a single comment line starting with '%', until EOL or EOF.
  defp skip_comment(%__MODULE__{} = st) do
    # skip until CR or LF or EOF
    advance_to_eol(st)
  end

  defp advance_to_eol(%__MODULE__{} = st) do
    if st.pos >= st.size do
      st
    else
      case byte_at(st) do
        # LF
        10 -> bump(st, 1)
        # CR
        13 -> bump(st, 1)
        _ -> advance_to_eol(bump(st, 1))
      end
    end
  end

  # Increase the position in the underlying binary by n bytes.
  defp bump(%__MODULE__{pos: pos} = st, n) do
    %{st | pos: pos + n}
  end

  # Read the byte at the current position.
  defp byte_at(%__MODULE__{bin: bin, pos: pos}) do
    :binary.at(bin, pos)
  end

  # Slice `len` bytes from the current position.
  defp slice(%__MODULE__{bin: bin, pos: pos}, len) do
    :binary.part(bin, pos, len)
  end

  # Whether a byte is a delimiter per PDF syntax.
  defp is_delim?(c) do
    c in @delims
  end

  # ===== Name =====

  # Parse a name object starting with '/'.
  defp parse_name(%__MODULE__{} = st) do
    # skip '/'
    st1 = bump(st, 1)
    {bytes, st2} = take_until_delim(st1)

    name = decode_name(bytes)
    st2 = put_last_name(st2, name)
    {{:name, name}, st2}
  end

  # Decode a PDF name byte sequence (handles #xx hex escapes) into a binary.
  defp decode_name(bytes) do
    decode_name(bytes, [])
    |> IO.iodata_to_binary()
  end

  defp decode_name(bytes, acc) do
    case bytes do
      <<>> ->
        Enum.reverse(acc)

      <<?#, a, b, rest::binary>> ->
        if hex_char?(a) and hex_char?(b) do
          <<val>> = <<hexval(a) * 16 + hexval(b)>>
          decode_name(rest, [val | acc])
        else
          # not a valid #xx escape; keep '#' literal and continue
          decode_name(<<a, b, rest::binary>>, [?# | acc])
        end

      <<c, rest::binary>> ->
        decode_name(rest, [c | acc])
    end
  end

  # True if byte is a hex digit.
  defp hex_char?(c) do
    (c >= ?0 and c <= ?9) or (c >= ?A and c <= ?F) or (c >= ?a and c <= ?f)
  end

  # Convert a hex digit byte to its integer value.
  defp hexval(c) do
    cond do
      c >= ?0 and c <= ?9 -> c - ?0
      c >= ?A and c <= ?F -> c - ?A + 10
      c >= ?a and c <= ?f -> c - ?a + 10
    end
  end

  # Read bytes until a delimiter or whitespace is reached.
  defp take_until_delim(%__MODULE__{} = st) do
    take_until_delim(st, 0)
  end

  defp take_until_delim(%__MODULE__{} = st, n) do
    cond do
      st.pos + n >= st.size ->
        {slice(st, n), bump(st, n)}

      :binary.at(st.bin, st.pos + n) in @whitespace ->
        {slice(st, n), bump(st, n)}

      :binary.at(st.bin, st.pos + n) in @delims ->
        {slice(st, n), bump(st, n)}

      true ->
        take_until_delim(st, n + 1)
    end
  end

  # ===== Literal String "(...)" =====

  # Parse a literal string enclosed in parentheses, handling escapes and nesting.
  defp parse_literal_string(%__MODULE__{} = st) do
    # skip '('
    st1 = bump(st, 1)

    case collect_lit(st1, 0, []) do
      {:ok, iodata, st2} ->
        {{:string, IO.iodata_to_binary(iodata)}, st2}

      {:error, st2} ->
        {{:error, {:unterminated_literal_string, st.pos}}, st2}
    end
  end

  defp collect_lit(%__MODULE__{} = st, balance, acc) do
    if st.pos >= st.size do
      {:error, st}
    else
      case byte_at(st) do
        # escape
        ?\\ ->
          collect_escape(bump(st, 1), balance, acc)

        ?( ->
          collect_lit(bump(st, 1), balance + 1, [?( | acc])

        ?) ->
          if balance == 0 do
            # end of string
            {:ok, Enum.reverse(acc), bump(st, 1)}
          else
            collect_lit(bump(st, 1), balance - 1, [?) | acc])
          end

        ?\r ->
          st2 = bump(st, 1)
          st3 = if st2.pos < st2.size and byte_at(st2) == ?\n, do: bump(st2, 1), else: st2
          collect_lit(st3, balance, [?\n | acc])

        ?\n ->
          collect_lit(bump(st, 1), balance, [?\n | acc])

        c ->
          collect_lit(bump(st, 1), balance, [c | acc])
      end
    end
  end

  # Handle a backslash escape sequence within a literal string.
  defp collect_escape(%__MODULE__{} = st, balance, acc) do
    case st.pos >= st.size do
      true ->
        {:error, st}

      false ->
        c = byte_at(st)

        cond do
          c == ?n ->
            collect_lit(bump(st, 1), balance, [?\n | acc])

          c == ?r ->
            collect_lit(bump(st, 1), balance, [?\r | acc])

          c == ?t ->
            collect_lit(bump(st, 1), balance, [?\t | acc])

          c == ?b ->
            collect_lit(bump(st, 1), balance, [?\b | acc])

          c == ?f ->
            collect_lit(bump(st, 1), balance, [?\f | acc])

          c == ?( ->
            collect_lit(bump(st, 1), balance, [?( | acc])

          c == ?) ->
            collect_lit(bump(st, 1), balance, [?) | acc])

          c == ?\\ ->
            collect_lit(bump(st, 1), balance, [?\\ | acc])

          c >= ?0 and c <= ?7 ->
            {val, st2} = collect_octal(st, 0, 0)
            collect_lit(st2, balance, [val | acc])

          # line continuation: backslash followed by CR or LF (or CRLF) is ignored
          # LF
          c == 10 ->
            collect_lit(bump(st, 1), balance, acc)

          c == 13 ->
            st2 = bump(st, 1)
            st3 = if st2.pos < st2.size and byte_at(st2) == 10, do: bump(st2, 1), else: st2
            collect_lit(st3, balance, acc)

          true ->
            # unknown escape -> keep char as-is
            collect_lit(bump(st, 1), balance, [c | acc])
        end
    end
  end

  # Parse up to three octal digits after a backslash escape and emit the byte.
  defp collect_octal(%__MODULE__{} = st, nread, acc) do
    cond do
      nread >= 3 or st.pos >= st.size ->
        {<<acc>>, st}

      byte_at(st) >= ?0 and byte_at(st) <= ?7 ->
        c = byte_at(st)
        collect_octal(bump(st, 1), nread + 1, acc * 8 + (c - ?0))

      true ->
        {<<acc>>, st}
    end
  end

  # ===== Hex String or Dict Start =====

  # Parse either a dict start '<<' or a hex string '<...>'.
  defp parse_lt(%__MODULE__{} = st) do
    if st.pos + 1 < st.size and :binary.at(st.bin, st.pos + 1) == ?< do
      st2 = bump(st, 2)
      {:dict_start, inc_dict_depth(st2)}
    else
      parse_hex_string(bump(st, 1))
    end
  end

  # Parse a hex string '<...>' into bytes (odd nibbles are padded with 0).
  defp parse_hex_string(%__MODULE__{} = st) do
    case collect_until_gt(st, [], nil) do
      {:ok, hexes, st2} ->
        # If odd count, pad with 0
        hexes = if rem(length(hexes), 2) == 1, do: hexes ++ [?0], else: hexes
        bytes = hex_pairs_to_bin(hexes, [])
        {{:hex_string, IO.iodata_to_binary(bytes)}, st2}

      {:error, :unterminated, st2} ->
        {{:error, {:unterminated_hex_string, st.pos - 1}}, st2}

      {:error, {:invalid, position}, st2} ->
        {{:error, {:invalid_hex_string, position}}, st2}
    end
  end

  # Collect hexadecimal digits until the closing '>', ignoring PDF whitespace only.
  defp collect_until_gt(%__MODULE__{} = st, acc, invalid_position) do
    case st.pos >= st.size do
      true ->
        {:error, :unterminated, st}

      false ->
        case byte_at(st) do
          ?> ->
            case invalid_position do
              nil -> {:ok, Enum.reverse(acc), bump(st, 1)}
              position -> {:error, {:invalid, position}, bump(st, 1)}
            end

          c when c in @whitespace ->
            collect_until_gt(bump(st, 1), acc, invalid_position)

          c ->
            case hex_char?(c) do
              true -> collect_until_gt(bump(st, 1), [c | acc], invalid_position)
              false -> collect_until_gt(bump(st, 1), acc, invalid_position || st.pos)
            end
        end
    end
  end

  defp hex_pairs_to_bin(hexes, acc) do
    case hexes do
      [] ->
        Enum.reverse(acc)

      [a, b | rest] ->
        <<val>> = <<hexval(a) * 16 + hexval(b)>>
        hex_pairs_to_bin(rest, [val | acc])
    end
  end

  # ===== Dict End or stray '>' =====

  # Parse a dict end '>>' (finalizing pending /Length) or flag an unexpected single '>'.
  defp parse_gt(%__MODULE__{} = st) do
    if st.pos + 1 < st.size and :binary.at(st.bin, st.pos + 1) == ?> do
      st2 = bump(st, 2)
      st3 = close_length_scope(st2)
      {:dict_end, dec_dict_depth(st3)}
    else
      {{:error, {:unexpected_gt, st.pos}}, bump(st, 1)}
    end
  end

  # ===== Numbers & Keywords =====

  # Parse a number or a keyword that looks like a number prefix.
  defp parse_number_or_keyword(%__MODULE__{} = st) do
    {word, st2} = take_word(st)
    parse_number_from_word(word, st2)
  end

  # Parse a bareword keyword (operators or known symbols like obj/endobj/R/etc.).
  defp parse_keyword(%__MODULE__{} = st) do
    {word, st2} = take_word(st)

    case word do
      "obj" ->
        {:obj, st2}

      "endobj" ->
        {:endobj, st2}

      "stream" ->
        begin_stream(st2)

      "endstream" ->
        {:endstream, st2}

      "xref" ->
        {:xref, st2}

      "trailer" ->
        {:trailer, st2}

      "startxref" ->
        {:startxref, st2}

      "R" ->
        st3 = maybe_capture_length_ref_on_R(st2)
        {:R, st3}

      "true" ->
        {true, st2}

      "false" ->
        {false, st2}

      "null" ->
        {:null, st2}

      _ ->
        {{:op, word}, st2}
    end
  end

  # Read a bareword until a delimiter or whitespace.
  defp take_word(%__MODULE__{} = st) do
    take_word(st, 0)
  end

  defp take_word(%__MODULE__{} = st, n) do
    cond do
      st.pos + n >= st.size ->
        {slice(st, n), bump(st, n)}

      :binary.at(st.bin, st.pos + n) in @whitespace ->
        {slice(st, n), bump(st, n)}

      is_delim?(:binary.at(st.bin, st.pos + n)) ->
        {slice(st, n), bump(st, n)}

      true ->
        take_word(st, n + 1)
    end
  end

  # Interpret a bareword as a PDF integer or real, retaining the start of invalid numbers.
  defp parse_number_from_word(word, st) do
    with :ok <- PdfValidator.validate_reader_size(byte_size(word), :max_pdf_numeric_token_bytes) do
      cond do
        Regex.match?(@pdf_integer, word) ->
          {integer, ""} = Integer.parse(word)
          st = maybe_capture_length_int(st, integer)
          {{:int, integer}, st}

        Regex.match?(@pdf_real, word) ->
          normalized =
            cond do
              String.starts_with?(word, ".") -> "0" <> word
              String.starts_with?(word, "+.") -> "+0" <> binary_part(word, 1, byte_size(word) - 1)
              String.starts_with?(word, "-.") -> "-0" <> binary_part(word, 1, byte_size(word) - 1)
              String.ends_with?(word, ".") -> word <> "0"
              true -> word
            end

          try do
            {{:real, :erlang.binary_to_float(normalized)}, st}
          rescue
            ArgumentError -> {{:error, {:not_a_number, word, st.pos - byte_size(word)}}, st}
          end

        true ->
          {{:error, {:not_a_number, word, st.pos - byte_size(word)}}, st}
      end
    end
  end

  # ===== Stream data handling =====

  # Switch into stream mode. The next token will be {:stream_data, bin}.
  defp begin_stream(%__MODULE__{} = st) do
    # After 'stream' keyword there must be a single EOL (CR, LF, or CRLF) which is not part of the data
    # We set in_stream so next/1 returns {:stream_data, bin}
    {:stream, %{st | in_stream: true}}
  end

  # Emit stream data either by known /Length (direct) or scanning until 'endstream'.
  defp return_stream_data(%__MODULE__{} = st) do
    st1 = skip_single_eol(st)

    cond do
      is_integer(st.last_length) and st.last_length >= 0 ->
        len = st.last_length
        data = safe_slice(st1, len)
        st2 = bump(st1, byte_size(data))
        # reset stream markers; length applies to this stream only
        st3 = %{
          st2
          | in_stream: false,
            last_length: nil,
            last_length_ref: nil
        }

        {{:stream_data, data}, st3}

      true ->
        # Fallback: scan until the next 'endstream' and take bytes up to (without trailing EOL)
        {data, st2} = take_until_endstream(st1)

        st3 = %{
          st2
          | in_stream: false,
            last_length: nil,
            last_length_ref: nil
        }

        {{:stream_data, data}, st3}
    end
  end

  # Consume a single CR, LF or CRLF sequence if present at current position.
  defp skip_single_eol(%__MODULE__{} = st) do
    cond do
      st.pos >= st.size ->
        st

      byte_at(st) == 13 ->
        st2 = bump(st, 1)
        if st2.pos < st2.size and byte_at(st2) == 10, do: bump(st2, 1), else: st2

      byte_at(st) == 10 ->
        bump(st, 1)

      true ->
        st
    end
  end

  # Return the EOL length (0/1/2) at current position without advancing.
  defp eol_len_at_pos(%__MODULE__{} = st) do
    cond do
      st.pos >= st.size ->
        0

      byte_at(st) == 13 ->
        if st.pos + 1 < st.size and :binary.at(st.bin, st.pos + 1) == 10, do: 2, else: 1

      byte_at(st) == 10 ->
        1

      true ->
        0
    end
  end

  # Slice up to `len` bytes, clamped to remaining document size.
  defp safe_slice(%__MODULE__{bin: bin, pos: pos, size: size}, len) do
    max_len = max(0, min(len, size - pos))
    :binary.part(bin, pos, max_len)
  end

  # Find the next 'endstream' and return bytes up to it (minus a trailing single EOL, if present).
  defp take_until_endstream(%__MODULE__{} = st) do
    # Find the next 'endstream' occurrence and consider preceding EOL not part of data
    idx = find_endstream_index(st)

    if idx == nil do
      # No endstream found; consume rest of file
      data = safe_slice(st, st.size - st.pos)
      {data, %{st | pos: st.size}}
    else
      data = :binary.part(st.bin, st.pos, idx - st.pos)
      data2 = drop_trailing_single_eol(data)
      {data2, %{st | pos: idx}}
    end
  end

  # Return the absolute index of the next 'endstream' keyword, or nil if not found.
  defp find_endstream_index(%__MODULE__{} = st) do
    bin = st.bin
    from = st.pos
    find_from(bin, from)
  end

  # Search for an 'endstream' token starting at `from`.
  defp find_from(bin, from) do
    cond do
      from >= byte_size(bin) ->
        nil

      true ->
        case :binary.match(bin, "endstream", scope: {from, byte_size(bin) - from}) do
          :nomatch ->
            nil

          {idx, 9} ->
            prev = if idx == 0, do: nil, else: :binary.at(bin, idx - 1)
            next_idx = idx + 9
            next = if next_idx == byte_size(bin), do: nil, else: :binary.at(bin, next_idx)

            if token_boundary?(prev) and token_boundary?(next) do
              idx
            else
              find_from(bin, idx + 1)
            end
        end
    end
  end

  defp token_boundary?(byte) do
    is_nil(byte) or byte in @whitespace or is_delim?(byte)
  end

  # Drop a single trailing CR, LF or CRLF from a binary, if present.
  defp drop_trailing_single_eol(bin) do
    len = byte_size(bin)

    cond do
      len >= 2 and :binary.at(bin, len - 2) == 13 and :binary.at(bin, len - 1) == 10 ->
        :binary.part(bin, 0, len - 2)

      len >= 1 and (:binary.at(bin, len - 1) == 13 or :binary.at(bin, len - 1) == 10) ->
        :binary.part(bin, 0, len - 1)

      true ->
        bin
    end
  end

  # ===== State helpers =====

  # Track nested dictionary depth and give each dictionary its own /Length state.
  defp inc_dict_depth(%__MODULE__{} = st) do
    scope = %{
      last_name: nil,
      length: nil,
      length_ref: nil,
      pending_first: nil,
      pending_second: nil
    }

    %{st | dict_depth: st.dict_depth + 1, length_scopes: [scope | st.length_scopes]}
  end

  defp dec_dict_depth(%__MODULE__{} = st) do
    %{st | dict_depth: max(st.dict_depth - 1, 0)}
  end

  # Remember the last seen name; special handling for /Length to latch following number/ref.
  defp put_last_name(%__MODULE__{} = st, name) do
    case st.length_scopes do
      [scope | scopes] ->
        scope = finalize_length_scope(scope)

        scope =
          if name == "Length" do
            %{
              scope
              | last_name: name,
                pending_first: nil,
                pending_second: nil,
                length_ref: nil
            }
          else
            %{scope | last_name: name}
          end

        %{st | length_scopes: [scope | scopes]}

      [] ->
        st
    end
  end

  # If inside a dict and after /Length, capture an immediate integer as the stream length.
  defp maybe_capture_length_int(%__MODULE__{} = st, int_val) do
    case st.length_scopes do
      [%{last_name: "Length"} = scope | scopes] ->
        scope =
          cond do
            is_nil(scope.pending_first) -> %{scope | pending_first: int_val}
            is_nil(scope.pending_second) -> %{scope | pending_second: int_val}
            true -> scope
          end

        %{st | length_scopes: [scope | scopes]}

      _ ->
        st
    end
  end

  # If we saw two ints followed by R after /Length, store it as an indirect reference hint.
  defp maybe_capture_length_ref_on_R(%__MODULE__{} = st) do
    case st.length_scopes do
      [
        %{last_name: "Length", pending_first: first, pending_second: second} = scope
        | scopes
      ]
      when is_integer(first) and is_integer(second) ->
        scope = %{
          scope
          | length_ref: {first, second},
            pending_first: nil,
            pending_second: nil
        }

        %{st | length_scopes: [scope | scopes]}

      _ ->
        st
    end
  end

  # Publish only the /Length belonging to the dictionary that just closed.
  defp close_length_scope(%__MODULE__{} = st) do
    case st.length_scopes do
      [scope | scopes] ->
        scope = finalize_length_scope(scope)

        %{
          st
          | length_scopes: scopes,
            last_length: scope.length,
            last_length_ref: scope.length_ref
        }

      [] ->
        %{st | last_length: nil, last_length_ref: nil}
    end
  end

  defp finalize_length_scope(scope) do
    if scope.last_name == "Length" and is_nil(scope.length_ref) and is_nil(scope.length) and
         is_integer(scope.pending_first) do
      %{scope | length: scope.pending_first, pending_first: nil, pending_second: nil}
    else
      scope
    end
  end
end
