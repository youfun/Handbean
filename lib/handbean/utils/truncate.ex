defmodule Handbean.Utils.Truncate do
  @moduledoc """
  Unified text truncation for tool outputs.

  Three strategies:
  - `:head` — keep the beginning, cut the tail (max_lines + max_bytes dual limit)
  - `:tail` — keep the end, cut the beginning (max_lines + max_bytes dual limit)
  - `:head_tail` — keep head and tail, cut the middle (lines first, then bytes)

  Single-line truncation:
  - `truncate_line/2` — truncate a single line by character count

  All operations are UTF-8 boundary safe.

  Ported from `Gong.Utils.Truncate`.
  """

  defmodule Result do
    @moduledoc """
    Truncation result metadata.

    Mirrors `Gong.Utils.Truncate.Result` for drop-in compatibility.
    """

    defstruct content: "",
              truncated: false,
              truncated_by: nil,
              total_lines: 0,
              total_bytes: 0,
              output_lines: 0,
              output_bytes: 0,
              last_line_partial: false,
              first_line_exceeds_limit: false,
              max_lines: nil,
              max_bytes: nil

    @type t :: %__MODULE__{
            content: String.t(),
            truncated: boolean(),
            truncated_by: :lines | :bytes | :chars | [:lines | :bytes] | nil,
            total_lines: non_neg_integer(),
            total_bytes: non_neg_integer(),
            output_lines: non_neg_integer(),
            output_bytes: non_neg_integer(),
            last_line_partial: boolean(),
            first_line_exceeds_limit: boolean(),
            max_lines: non_neg_integer() | nil,
            max_bytes: non_neg_integer() | nil
          }
  end

  @default_max_bytes 30_000

  @type strategy :: :head | :tail

  @doc """
  Truncate text using the given strategy.

  ## Options
  - `:max_lines` — maximum number of lines to keep
  - `:max_bytes` — maximum output byte size (default: #{@default_max_bytes})
  """
  @spec truncate(String.t(), strategy(), keyword()) :: Result.t()
  def truncate(text, strategy \\ :tail, opts \\ [])

  def truncate(text, :head, opts) do
    max_lines = Keyword.get(opts, :max_lines)
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)
    truncate_head(text, max_lines, max_bytes)
  end

  def truncate(text, :tail, opts) do
    max_lines = Keyword.get(opts, :max_lines)
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)
    truncate_tail(text, max_lines, max_bytes)
  end

  @doc """
  Truncate a single line. If the line exceeds `max_chars` characters,
  it is cut and a `... [truncated]` marker is appended.
  """
  @spec truncate_line(String.t(), non_neg_integer()) :: Result.t()
  def truncate_line(text, max_chars) do
    total_bytes = byte_size(text)

    if String.length(text) <= max_chars do
      %Result{
        content: text,
        truncated: false,
        total_lines: 1,
        total_bytes: total_bytes,
        output_lines: 1,
        output_bytes: total_bytes
      }
    else
      truncated = String.slice(text, 0, max_chars)
      content = truncated <> " ... [truncated]"

      %Result{
        content: content,
        truncated: true,
        truncated_by: :chars,
        total_lines: 1,
        total_bytes: total_bytes,
        output_lines: 1,
        output_bytes: byte_size(content)
      }
    end
  end

  # ── Head+Tail truncation: keep head and tail, cut the middle ──

  @default_head_lines 50
  @default_tail_lines 50

  @doc """
  Head+tail preservation: keep the beginning and end, truncate the middle.

  Execution order:
  1. Truncate by line count first (default: head 50 + tail 50 lines)
  2. Secondary byte limit (default: 30KB)

  For a single very-long line, byte-based head/tail split (50/50) is applied.

  ## Options
  - `:head_lines` — lines to keep from the head (default: #{@default_head_lines})
  - `:tail_lines` — lines to keep from the tail (default: #{@default_tail_lines})
  - `:max_bytes` — maximum output byte size (default: #{@default_max_bytes})
  """
  @spec truncate_head_tail(String.t(), keyword()) :: Result.t()
  def truncate_head_tail(content, opts \\ []) do
    head_lines = max(Keyword.get(opts, :head_lines, @default_head_lines), 0)
    tail_lines = max(Keyword.get(opts, :tail_lines, @default_tail_lines), 0)
    max_bytes = max(Keyword.get(opts, :max_bytes, @default_max_bytes), 0)

    total_bytes = byte_size(content)

    # Handle trailing newline: strip the trailing empty element from split
    raw_lines = String.split(content, "\n")

    {lines, has_trailing_newline} =
      if content != "" and String.ends_with?(content, "\n") do
        {List.delete_at(raw_lines, -1), true}
      else
        {raw_lines, false}
      end

    total_line_count = length(lines)
    within_lines = total_line_count <= head_lines + tail_lines
    within_bytes = total_bytes <= max_bytes

    if within_lines and within_bytes do
      %Result{
        content: content,
        truncated: false,
        total_lines: total_line_count,
        total_bytes: total_bytes,
        output_lines: total_line_count,
        output_bytes: total_bytes,
        max_bytes: max_bytes
      }
    else
      do_truncate_head_tail(
        lines,
        head_lines,
        tail_lines,
        max_bytes,
        total_line_count,
        total_bytes,
        has_trailing_newline
      )
    end
  end

  defp do_truncate_head_tail(
         lines,
         head_lines,
         tail_lines,
         max_bytes,
         total_line_count,
         total_bytes,
         has_trailing_newline
       ) do
    trailing = if has_trailing_newline, do: "\n", else: ""

    cond do
      total_line_count == 1 ->
        truncate_single_line_bytes(hd(lines), max_bytes, total_bytes)

      total_line_count > head_lines + tail_lines ->
        head_part = Enum.take(lines, head_lines)
        tail_part = Enum.take(lines, -tail_lines)
        omitted_lines = total_line_count - head_lines - tail_lines

        omitted_content =
          lines |> Enum.slice(head_lines, omitted_lines) |> Enum.join("\n")

        omitted_bytes = byte_size(omitted_content)

        marker = "... [省略 #{omitted_lines} 行, 共 #{omitted_bytes} 字节] ..."

        joined =
          Enum.join(head_part, "\n") <>
            "\n" <> marker <> "\n" <> Enum.join(tail_part, "\n") <> trailing

        if byte_size(joined) > max_bytes do
          result_content = truncate_bytes_head_tail(joined, max_bytes)

          %Result{
            content: result_content,
            truncated: true,
            truncated_by: [:lines, :bytes],
            total_lines: total_line_count,
            total_bytes: total_bytes,
            output_lines: head_lines + tail_lines + 1,
            output_bytes: byte_size(result_content),
            max_bytes: max_bytes
          }
        else
          %Result{
            content: joined,
            truncated: true,
            truncated_by: :lines,
            total_lines: total_line_count,
            total_bytes: total_bytes,
            output_lines: head_lines + tail_lines + 1,
            output_bytes: byte_size(joined),
            max_bytes: max_bytes
          }
        end

      true ->
        original = Enum.join(lines, "\n") <> trailing
        result_content = truncate_bytes_head_tail(original, max_bytes)

        %Result{
          content: result_content,
          truncated: true,
          truncated_by: :bytes,
          total_lines: total_line_count,
          total_bytes: total_bytes,
          output_lines: total_line_count,
          output_bytes: byte_size(result_content),
          max_bytes: max_bytes
        }
    end
  end

  defp truncate_single_line_bytes(line, max_bytes, total_bytes) do
    result_content = do_bytes_head_tail(line, max_bytes)

    %Result{
      content: result_content,
      truncated: true,
      truncated_by: :bytes,
      total_lines: 1,
      total_bytes: total_bytes,
      output_lines: length(String.split(result_content, "\n")),
      output_bytes: byte_size(result_content),
      max_bytes: max_bytes
    }
  end

  defp truncate_bytes_head_tail(text, max_bytes) do
    do_bytes_head_tail(text, max_bytes)
  end

  defp do_bytes_head_tail(text, max_bytes) do
    total = byte_size(text)
    worst_marker = "... [省略 约#{total} 字节] ..."
    marker_overhead = byte_size(worst_marker) + 2

    if max_bytes <= marker_overhead do
      if max_bytes >= byte_size(worst_marker) do
        worst_marker
      else
        safe_binary_slice(worst_marker, 0, max(max_bytes, 0))
      end
    else
      available = max_bytes - marker_overhead
      half = div(available, 2)
      head_part = safe_binary_slice(text, 0, half)
      tail_part = safe_binary_tail(text, half)
      omitted = total - byte_size(head_part) - byte_size(tail_part)
      marker = "... [省略 约#{omitted} 字节] ..."
      head_part <> "\n" <> marker <> "\n" <> tail_part
    end
  end

  # ── Head truncation: keep the beginning ──

  defp truncate_head(text, max_lines, max_bytes) do
    total_bytes = byte_size(text)
    lines = String.split(text, "\n")
    total_line_count = length(lines)
    effective_max_lines = max_lines || total_line_count

    within_lines = total_line_count <= effective_max_lines
    within_bytes = total_bytes <= max_bytes

    if within_lines and within_bytes do
      %Result{
        content: text,
        truncated: false,
        total_lines: total_line_count,
        total_bytes: total_bytes,
        output_lines: total_line_count,
        output_bytes: total_bytes,
        max_lines: max_lines,
        max_bytes: max_bytes
      }
    else
      do_truncate_head(
        lines,
        effective_max_lines,
        max_bytes,
        total_line_count,
        total_bytes,
        max_lines
      )
    end
  end

  defp do_truncate_head(
         lines,
         effective_max_lines,
         max_bytes,
         total_line_count,
         total_bytes,
         orig_max_lines
       ) do
    {kept, count, _bytes, truncated_by} =
      acc_head(lines, effective_max_lines, max_bytes, [], 0, 0)

    content = Enum.join(kept, "\n")
    first_exceeds = count == 0 and truncated_by == :bytes

    %Result{
      content: content,
      truncated: true,
      truncated_by: truncated_by,
      total_lines: total_line_count,
      total_bytes: total_bytes,
      output_lines: count,
      output_bytes: byte_size(content),
      first_line_exceeds_limit: first_exceeds,
      max_lines: orig_max_lines,
      max_bytes: max_bytes
    }
  end

  defp acc_head([], _max_lines, _max_bytes, kept, count, bytes) do
    {Enum.reverse(kept), count, bytes, nil}
  end

  defp acc_head([line | rest], max_lines, max_bytes, kept, count, bytes) do
    if count >= max_lines do
      {Enum.reverse(kept), count, bytes, :lines}
    else
      separator = if count == 0, do: 0, else: 1
      new_bytes = bytes + separator + byte_size(line)

      if new_bytes > max_bytes do
        if count == 0 do
          {[], 0, 0, :bytes}
        else
          {Enum.reverse(kept), count, bytes, :bytes}
        end
      else
        acc_head(rest, max_lines, max_bytes, [line | kept], count + 1, new_bytes)
      end
    end
  end

  # ── Tail truncation: keep the end ──

  defp truncate_tail(text, max_lines, max_bytes) do
    total_bytes = byte_size(text)
    lines = String.split(text, "\n")
    total_line_count = length(lines)
    effective_max_lines = max_lines || total_line_count

    within_lines = total_line_count <= effective_max_lines
    within_bytes = total_bytes <= max_bytes

    if within_lines and within_bytes do
      %Result{
        content: text,
        truncated: false,
        total_lines: total_line_count,
        total_bytes: total_bytes,
        output_lines: total_line_count,
        output_bytes: total_bytes,
        max_lines: max_lines,
        max_bytes: max_bytes
      }
    else
      do_truncate_tail(
        lines,
        effective_max_lines,
        max_bytes,
        total_line_count,
        total_bytes,
        max_lines
      )
    end
  end

  defp do_truncate_tail(
         lines,
         effective_max_lines,
         max_bytes,
         total_line_count,
         total_bytes,
         orig_max_lines
       ) do
    reversed = Enum.reverse(lines)

    {kept_rev, count, _bytes, truncated_by, partial} =
      acc_tail(reversed, effective_max_lines, max_bytes, [], 0, 0)

    content = kept_rev |> Enum.join("\n")

    %Result{
      content: content,
      truncated: true,
      truncated_by: truncated_by,
      total_lines: total_line_count,
      total_bytes: total_bytes,
      output_lines: count,
      output_bytes: byte_size(content),
      last_line_partial: partial,
      max_lines: orig_max_lines,
      max_bytes: max_bytes
    }
  end

  defp acc_tail([], _max_lines, _max_bytes, kept, count, bytes) do
    {kept, count, bytes, nil, false}
  end

  defp acc_tail([line | rest], max_lines, max_bytes, kept, count, bytes) do
    if count >= max_lines do
      {kept, count, bytes, :lines, false}
    else
      separator = if count == 0, do: 0, else: 1
      line_bytes = byte_size(line)
      new_bytes = bytes + separator + line_bytes

      if new_bytes > max_bytes do
        remaining_budget = max_bytes - bytes - separator

        if remaining_budget > 0 do
          start = max(line_bytes - remaining_budget, 0)
          partial_line = safe_tail_part(line, start, line_bytes - start)

          {[partial_line | kept], count + 1, bytes + separator + byte_size(partial_line), :bytes,
           true}
        else
          {kept, count, bytes, :bytes, false}
        end
      else
        acc_tail(rest, max_lines, max_bytes, [line | kept], count + 1, new_bytes)
      end
    end
  end

  # ── UTF-8 safe helpers ──

  defp safe_binary_slice(binary, start, len) do
    raw = binary_part(binary, start, min(len, byte_size(binary) - start))
    trim_trailing_incomplete_utf8(raw)
  end

  defp safe_binary_tail(binary, len) do
    total = byte_size(binary)
    start = max(total - len, 0)
    raw = binary_part(binary, start, total - start)
    skip_leading_continuation(raw)
  end

  defp safe_tail_part(binary, start, len) do
    raw = binary_part(binary, start, min(len, byte_size(binary) - start))
    skip_leading_continuation(raw)
  end

  defp skip_leading_continuation(<<>>), do: <<>>

  defp skip_leading_continuation(binary) do
    do_skip_leading(binary, 0)
  end

  defp do_skip_leading(binary, skipped) when skipped >= 3, do: binary

  defp do_skip_leading(<<byte, rest::binary>>, skipped)
       when Bitwise.band(byte, 0xC0) == 0x80 do
    do_skip_leading(rest, skipped + 1)
  end

  defp do_skip_leading(binary, _skipped), do: binary

  defp trim_trailing_incomplete_utf8(<<>>), do: <<>>

  defp trim_trailing_incomplete_utf8(binary) do
    do_trim_trailing(binary, byte_size(binary))
  end

  defp do_trim_trailing(binary, size) when size <= 0, do: binary

  defp do_trim_trailing(binary, size) do
    if String.valid?(binary) do
      binary
    else
      binary_part(binary, 0, size - 1) |> do_trim_trailing(size - 1)
    end
  end
end
