defmodule Handbean.Documents do
  @moduledoc """
  Bounded document extraction from already-authorized bytes.

  Callers own filesystem and network authorization. Parsers receive no host paths,
  execute no scripts, follow no external links, and never perform OCR.
  """

  alias Handbean.Documents.Office

  @max_input 16 * 1024 * 1024
  @timeout 15_000
  @formats %{
    ".pdf" => :pdf,
    ".docx" => :docx,
    ".xlsx" => :xlsx,
    ".pptx" => :pptx,
    "application/pdf" => :pdf,
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document" => :docx,
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" => :xlsx,
    "application/vnd.openxmlformats-officedocument.presentationml.presentation" => :pptx
  }

  def child_spec(_opts) do
    Supervisor.child_spec({Task.Supervisor, name: __MODULE__.Workers, max_children: 2},
      id: __MODULE__
    )
  end

  def max_input_bytes, do: @max_input

  def format(name) when is_binary(name),
    do:
      Map.get(@formats, String.downcase(name)) ||
        Map.get(@formats, name |> Path.extname() |> String.downcase())

  def format(_), do: nil

  def extract(bytes, format, opts \\ [])

  def extract(bytes, format, opts)
      when is_binary(bytes) and format in [:pdf, :docx, :xlsx, :pptx] do
    case Keyword.get(opts, :timeout, @timeout) do
      timeout when is_integer(timeout) and timeout > 0 ->
        if byte_size(bytes) > @max_input,
          do: {:error, "Document exceeds the 16 MiB input limit"},
          else: run(bytes, format, min(@timeout, timeout))

      _ ->
        {:error, "Document extraction timeout must be a positive integer"}
    end
  end

  def extract(_, _, _), do: {:error, "Unsupported document format"}

  def paginate(%{text: text} = document, offset, limit, max_bytes \\ 48_000) do
    lines = text |> String.split("\n") |> Enum.flat_map(&wrap_line/1)
    start = max(offset, 1)
    total = length(lines)

    if start > total do
      {:error, "Offset #{start} beyond extracted document end (#{total} lines)"}
    else
      {selected, _used} =
        lines
        |> Enum.drop(start - 1)
        |> Enum.take(limit)
        |> Enum.with_index(start)
        |> Enum.reduce_while({[], 0}, fn {line, index}, {kept, used} ->
          formatted = "#{String.pad_leading(Integer.to_string(index), 6)}\t#{line}"
          size = byte_size(formatted) + 1

          if used + size <= max_bytes,
            do: {:cont, {[formatted | kept], used + size}},
            else: {:halt, {kept, used}}
        end)

      next = start + length(selected)
      more = next <= total
      hint = if more, do: "\n\n[More extracted lines. Use offset=#{next} to continue.]", else: ""
      output = selected |> Enum.reverse() |> Enum.join("\n")

      metadata =
        document
        |> Map.delete(:text)
        |> Map.merge(%{
          total_lines: total,
          offset: start,
          next_offset: if(more, do: next),
          truncated: more
        })

      {:ok, output <> hint, metadata}
    end
  end

  defp wrap_line(line) do
    if byte_size(line) <= 1_500 do
      [line]
    else
      # These labels are produced by our adapters, not parsed from PDF syntax.
      prefix =
        case Regex.run(
               ~r/^(\[(?:Page \d+|Slide \d+|Paragraph \d+|Sheet "(?:[^"\\]|\\.)*")\] )/u,
               line
             ) do
          [_, label] when byte_size(label) < 512 -> label
          _ -> ""
        end

      text = String.replace_prefix(line, prefix, "")
      do_wrap(text, prefix, 1_500 - byte_size(prefix), [])
    end
  end

  defp do_wrap("", _prefix, _width, acc), do: Enum.reverse(acc)

  defp do_wrap(line, prefix, width, acc) do
    candidate = binary_part(line, 0, min(byte_size(line), width))

    head =
      case :unicode.characters_to_binary(candidate, :utf8, :utf8) do
        valid when is_binary(valid) -> valid
        {:incomplete, valid, _} -> valid
      end

    rest = binary_part(line, byte_size(head), byte_size(line) - byte_size(head))
    do_wrap(rest, prefix, width, [prefix <> head | acc])
  end

  defp run(bytes, format, timeout) do
    # BEAM heap accounting supplements parser work/decoded-byte budgets. It is
    # not a replacement for bounded inflation or a global native-memory limit.
    caller = self()
    deadline = System.monotonic_time(:millisecond) + timeout

    task =
      Task.Supervisor.async_nolink(__MODULE__.Workers, fn ->
        guard(caller, bytes, format, deadline)
      end)

    # The guardian owns the actual deadline and survives caller cancellation.
    # This outer wait includes a bounded allowance for reaping a killed worker.
    case Task.yield(task, timeout + 1_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, _} -> {:error, "Document parsing failed or exceeded its resource limit"}
      nil -> {:error, "Document extraction timed out"}
    end
  rescue
    RuntimeError ->
      {:error, "Document extractor is busy; retry after another extraction completes"}
  end

  defp guard(caller, bytes, format, deadline) do
    Process.flag(:trap_exit, true)
    caller_ref = Process.monitor(caller)
    guardian = self()
    token = make_ref()

    {worker, worker_ref} =
      :erlang.spawn_opt(
        fn ->
          Process.flag(:max_heap_size, %{
            size: 16_000_000,
            kill: true,
            error_logger: false,
            include_shared_binaries: true
          })

          result = bytes |> parse(format) |> validate_output()
          send(guardian, {token, result})
        end,
        [:link, :monitor]
      )

    try do
      receive do
        {^token, result} ->
          receive do
            {:DOWN, ^worker_ref, :process, ^worker, _} -> result
          end

        {:DOWN, ^caller_ref, :process, ^caller, _} ->
          stop_worker(worker, worker_ref)
          {:error, "Document extraction cancelled"}

        {:DOWN, ^worker_ref, :process, ^worker, _} ->
          {:error, "Document parsing failed or exceeded its resource limit"}

        {:EXIT, _supervisor, :shutdown} ->
          stop_worker(worker, worker_ref)
          {:error, "Document extraction cancelled"}
      after
        max(0, deadline - System.monotonic_time(:millisecond)) ->
          stop_worker(worker, worker_ref)
          {:error, "Document extraction timed out"}
      end
    after
      Process.demonitor(caller_ref, [:flush])
    end
  end

  defp stop_worker(worker, ref) do
    Process.exit(worker, :kill)

    receive do
      {:DOWN, ^ref, :process, ^worker, _} -> :ok
    end
  end

  defp validate_output({:ok, %{text: text}}) when byte_size(text) > 2 * 1024 * 1024,
    do: {:error, "Extracted document exceeds the 2 MiB text limit"}

  defp validate_output({:error, :missing_relationship}),
    do: {:error, "Missing required Office relationship"}

  defp validate_output(result), do: result

  defp parse(<<"%PDF-", _::binary>> = bytes, :pdf) do
    result =
      NativeElixirPdfUtilities.Validators.PdfValidator.with_reader_budget(fn ->
        NativeElixirPdfUtilities.Text.extract_spans(bytes, order: :visual)
      end)

    case result do
      {:ok, %{pages: pages, page_count: count}} ->
        with {:ok, text} <- pdf_pages(pages) do
          {:ok,
           %{
             format: :pdf,
             text: text,
             page_count: count,
             warnings: [
               "Embedded PDF text only; no OCR. Text order and layout are approximate; images and charts are not interpreted."
             ]
           }}
        end

      {:error, {:encrypted_pdf, _}} ->
        {:error, "Encrypted PDF is unsupported; provide a decrypted copy"}

      {:error, {:resource_limit_exceeded, _}} ->
        {:error, "PDF exceeds extraction resource limits"}

      {:error, {reason, _}} ->
        {:error, "PDF extraction failed: #{reason}"}
    end
  end

  defp parse(_bytes, :pdf), do: {:error, "Invalid PDF signature"}
  defp parse(<<0x50, 0x4B, _::binary>> = bytes, format), do: Office.extract(bytes, format)

  defp parse(<<0xD0, 0xCF, 0x11, 0xE0, _::binary>>, _format),
    do:
      {:error,
       "Encrypted Office or legacy binary Office files are unsupported; provide an unencrypted DOCX/XLSX/PPTX copy"}

  defp parse(_, _), do: {:error, "Invalid Office ZIP signature"}

  defp pdf_pages(pages) do
    Enum.reduce_while(pages, {:ok, [], 2 * 1024 * 1024}, fn page, {:ok, sections, remaining} ->
      case pdf_page(page, remaining) do
        {:ok, section} -> {:cont, {:ok, [section | sections], remaining - byte_size(section) - 1}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, sections, _} -> {:ok, sections |> Enum.reverse() |> Enum.join("\n")}
      error -> error
    end
  end

  defp pdf_page(%{number: page, spans: []}, remaining),
    do:
      label_pdf_page(
        "No extractable text; this page may need OCR (not available).",
        page,
        remaining
      )

  defp pdf_page(%{number: page, spans: spans}, remaining) do
    {parts, _} =
      Enum.reduce(spans, {[], nil}, fn span, {parts, previous} ->
        separator =
          cond do
            is_nil(previous) -> ""
            abs(span.y - previous.y) > 2 -> "\n"
            span.joins_previous? -> ""
            true -> " "
          end

        {[span.text, separator | parts], span}
      end)

    text = parts |> Enum.reverse() |> IO.iodata_to_binary()
    label_pdf_page(text, page, remaining)
  end

  defp label_pdf_page(text, page, remaining) do
    lines = String.split(text, "\n")
    label = "[Page #{page}] "
    size = byte_size(text) + length(lines) * byte_size(label)

    if size <= remaining,
      do: {:ok, Enum.map_join(lines, "\n", &(label <> &1))},
      else: {:error, "Extracted document exceeds the 2 MiB text limit"}
  end
end
