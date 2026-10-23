defmodule Handbean.DocumentsTest do
  use ExUnit.Case, async: false

  alias Handbean.{DocumentFixtures, Documents}

  test "reads a production PDF writer's embedded CJK font, ToUnicode map and multiple pages" do
    assert {:ok, document} = Documents.extract(DocumentFixtures.read("multilingual.pdf"), :pdf)
    assert document.page_count == 2
    assert document.text =~ "[Page 1] Quarterly report: revenue 123.45 EUR"
    assert document.text =~ "[Page 1] 中文文档测试：你好世界"
    assert document.text =~ "[Page 2] Second page"
    assert Enum.join(document.warnings) =~ "no OCR"

    assert {:ok, first, %{next_offset: next, truncated: true}} =
             Documents.paginate(document, 0, 2)

    assert first =~ "中文文档测试"

    assert {:ok, second, %{next_offset: nil, truncated: false}} =
             Documents.paginate(document, next, 2)

    assert second =~ "[Page 2]"
    refute second =~ "[Page 1]"
  end

  test "reports image-only pages and encrypted documents without pretending to understand them" do
    assert {:ok, document} = Documents.extract(DocumentFixtures.read("image-only.pdf"), :pdf)
    assert document.text =~ "No extractable text"
    assert document.text =~ "OCR (not available)"
    assert {:error, message} = Documents.extract(DocumentFixtures.read("encrypted.pdf"), :pdf)
    assert message =~ "Encrypted PDF"
    assert {:error, message} = Documents.extract(<<0xD0, 0xCF, 0x11, 0xE0, 0>>, :docx)
    assert message =~ "Encrypted Office or legacy"
  end

  test "reads real Office files with table cells, sparse coordinates, sheets and slides" do
    assert {:ok, docx} = Documents.extract(DocumentFixtures.read("report.docx"), :docx)
    assert docx.text =~ "Quarterly report 中文段落"
    assert docx.text =~ "Item\tAmount"
    assert docx.text =~ "研发\t123.45"
    assert docx.text =~ "Final paragraph"

    assert {:ok, xlsx} = Documents.extract(DocumentFixtures.read("budget.xlsx"), :xlsx)
    assert xlsx.text =~ ~s([Sheet "预算"] [Row 1] A1="Category" | C1="研发")
    assert xlsx.text =~ "=A3*2 [no cached value]"
    assert xlsx.text =~ ~s([Sheet "Summary"] [Row 2] B2="Final total")
    assert Enum.join(xlsx.warnings) =~ "not evaluated"

    assert {:ok, pptx} = Documents.extract(DocumentFixtures.read("slides.pptx"), :pptx)
    assert pptx.text =~ "[Slide 1] Opening 中文"
    assert pptx.text =~ "[Slide 2] Second slide"
    assert {:ok, slice, _} = Documents.paginate(pptx, 4, 1)
    assert slice =~ "[Slide 2] Second slide"
  end

  test "presentation relationship order wins over ZIP filenames and unrelated assets" do
    bytes = DocumentFixtures.read("slides.pptx")

    reordered =
      DocumentFixtures.rewrite_zip(bytes, fn
        "ppt/presentation.xml" = name, content ->
          {name,
           String.replace(
             content,
             ~r/(<p:sldId[^>]*r:id="rId7"[^>]*\/>)(<p:sldId[^>]*r:id="rId8"[^>]*\/>)/,
             "\\2\\1"
           )}

        name, content ->
          {name, content}
      end)

    assert reordered != bytes
    assert {:ok, result} = Documents.extract(reordered, :pptx)
    assert result.text =~ "[Slide 1] Conclusion"
    assert result.text =~ "[Slide 2] Opening 中文"
  end

  test "refuses malformed PDF, cyclic page trees, decompression bombs and oversized input" do
    for bytes <- [
          "not PDF",
          "%PDF-1.7\ninvalid",
          DocumentFixtures.pdf("BT /F1 12 Tf (x) Tj ET")
          |> String.replace("/Kids [3 0 R]", "/Kids [2 0 R]")
        ] do
      assert {:error, _} = Documents.extract(bytes, :pdf)
    end

    bomb = DocumentFixtures.pdf(String.duplicate(" ", 9 * 1024 * 1024), compressed: true)
    assert {:error, message} = Documents.extract(bomb, :pdf)
    assert message =~ "resource limits"

    assert {:error, message} =
             Documents.extract(String.duplicate("x", Documents.max_input_bytes() + 1), :docx)

    assert message =~ "input limit"

    assert {:error, message} =
             Documents.extract(DocumentFixtures.read("multilingual.pdf"), :pdf, timeout: 0)

    assert message =~ "timeout"

    for timeout <- [nil, 1.5, "1000", -1] do
      assert {:error, "Document extraction timeout must be a positive integer"} =
               Documents.extract(DocumentFixtures.read("multilingual.pdf"), :pdf,
                 timeout: timeout
               )
    end
  end

  test "rejects false ZIP sizes, CRC corruption, ZIP traversal and duplicate members" do
    lie = DocumentFixtures.lying_zip("word/document.xml", String.duplicate("x", 1_000_000), 100)
    assert {:error, _} = Documents.extract(lie, :docx)

    for name <- [
          "../escape.xml",
          "/absolute.xml",
          "word/../../escape.xml",
          "word\\document.xml",
          "word/%2e%2e/escape.xml"
        ] do
      bytes = DocumentFixtures.lying_zip(name, "<root/>", 7)
      assert {:error, _} = Handbean.Documents.Archive.open(bytes)
      assert {:error, _} = Documents.extract(bytes, :docx)
    end

    duplicate = DocumentFixtures.docx("<w:p/>", [{"word/document.xml", "<root/>"}])
    assert {:error, _} = Documents.extract(duplicate, :docx)
    bytes = DocumentFixtures.docx("<w:p><w:r><w:t>hello</w:t></w:r></w:p>")
    # CRC is at offset 14 in the first local header; inconsistent metadata is rejected.
    <<head::binary-size(14), crc::little-32, tail::binary>> = bytes
    corrupt = <<head::binary, Bitwise.bxor(crc, 1)::little-32, tail::binary>>
    assert {:error, _} = Documents.extract(corrupt, :docx)
  end

  test "does not expand XML entities, traverse excessive nesting or follow relationship URLs" do
    for body <- [
          "<!DOCTYPE p [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><w:p>&x;</w:p>",
          "<w:p>&untrusted;</w:p>",
          String.duplicate("<w:p>", 65) <> "secret" <> String.duplicate("</w:p>", 65)
        ] do
      assert {:error, _} = Documents.extract(DocumentFixtures.docx(body), :docx)
    end

    for target <- [
          "../../outside.xml",
          "https://example.test/remote.xml",
          "file:///etc/passwd",
          "%2e%2e/outside.xml"
        ] do
      bytes = DocumentFixtures.docx("<w:p/>")

      malformed =
        DocumentFixtures.rewrite_zip(bytes, fn
          "_rels/.rels" = name, _ ->
            {name, DocumentFixtures.relationships([{"main", "officeDocument", target}])}

          name, data ->
            {name, data}
        end)

      assert {:error, _} = Documents.extract(malformed, :docx)
    end
  end

  test "bounds actual decompression even when metadata lies consistently" do
    bytes = DocumentFixtures.lying_zip("member.xml", String.duplicate("x", 1_000_000), 100)
    assert {:ok, archive} = Handbean.Documents.Archive.open(bytes)
    assert {:error, message} = Handbean.Documents.Archive.fetch(archive, "member.xml")
    assert message =~ "oversized"
  end

  test "output pagination stays bounded without losing long-line content" do
    text = Enum.map_join(1..100, "\n", &"[Page #{&1}] #{String.duplicate("中", 2_000)}")
    document = %{text: text, format: :pdf, warnings: []}
    assert {:ok, first, %{next_offset: next}} = Documents.paginate(document, 0, 2_000)
    assert byte_size(first) < 50_000
    assert next > 1
    assert {:ok, second, %{offset: ^next}} = Documents.paginate(document, next, 2_000)
    assert byte_size(second) < 50_000
    assert {:error, _} = Documents.paginate(document, 100_000, 10)

    combining = %{document | text: "[Page 7] x" <> String.duplicate("\u0301", 30_000)}
    assert {:ok, chunk, %{next_offset: next}} = Documents.paginate(combining, 0, 1)
    assert byte_size(chunk) < 2_000
    assert next == 2
    assert {:ok, chunk, _} = Documents.paginate(combining, next, 1)
    assert chunk =~ "[Page 7]"
    assert String.valid?(chunk)
  end

  test "admission is bounded and releases slots after a parser failure" do
    workers =
      for _ <- 1..2 do
        {:ok, pid} =
          Task.Supervisor.start_child(Documents.Workers, fn ->
            receive do
              :finish -> :ok
            end
          end)

        pid
      end

    try do
      assert {:error, message} =
               Documents.extract(DocumentFixtures.read("multilingual.pdf"), :pdf)

      assert message =~ "busy"
    after
      Enum.each(workers, fn pid ->
        ref = Process.monitor(pid)
        send(pid, :finish)
        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
      end)
    end

    assert {:error, _} = Documents.extract("%PDF-broken", :pdf)
    assert {:ok, _} = Documents.extract(DocumentFixtures.read("multilingual.pdf"), :pdf)
  end

  test "an elapsed extraction deadline kills and reaps the worker" do
    body =
      Enum.map_join(1..10_000, fn index ->
        "<w:p><w:r><w:t>#{index}-#{Base.encode16(:crypto.hash(:sha256, Integer.to_string(index)))}</w:t></w:r></w:p>"
      end)

    bytes = DocumentFixtures.docx(body)
    assert {:error, "Document extraction timed out"} = Documents.extract(bytes, :docx, timeout: 1)
    assert {:ok, _} = Documents.extract(DocumentFixtures.read("multilingual.pdf"), :pdf)
  end

  test "PDF budgets cover content tokens, multiple streams and normalized labels" do
    assert {:ok, _} =
             Documents.extract(DocumentFixtures.pdf(String.duplicate("0 0 m\n", 100)), :pdf)

    tokens = DocumentFixtures.pdf(String.duplicate("0 0 m\n", 90_000))
    assert {:error, message} = Documents.extract(tokens, :pdf)
    assert message =~ "resource limit"

    # Six individually valid decoded streams exceed the aggregate allowance.
    comment = "%" <> Base.encode16(:crypto.strong_rand_bytes(1_500_000)) <> "\n"
    streams = DocumentFixtures.pdf("", compressed: true, streams: List.duplicate(comment, 6))
    assert {:error, message} = Documents.extract(streams, :pdf)
    assert message =~ "resource limit"

    cmap =
      "1 begincodespacerange\n<00> <FF>\nendcodespacerange\n1 beginbfchar\n<41> <" <>
        String.duplicate("000A", 220_000) <> ">\nendbfchar"

    assert {:error, message} =
             Documents.extract(DocumentFixtures.pdf("BT /F1 12 Tf (A) Tj ET", cmap: cmap), :pdf)

    assert message =~ "2 MiB text limit"
  end

  test "repeated slide references cannot amplify retained output beyond its limit" do
    text = Base.encode16(:crypto.strong_rand_bytes(4_096))
    ids = Enum.map_join(1..300, &~s(<p:sldId id="#{&1}" r:id="slide"/>))

    bytes =
      DocumentFixtures.zip([
        {"_rels/.rels",
         DocumentFixtures.relationships([{"main", "officeDocument", "ppt/presentation.xml"}])},
        {"ppt/presentation.xml",
         ~s(<p:presentation xmlns:p="urn:p" xmlns:r="urn:r"><p:sldIdLst>#{ids}</p:sldIdLst></p:presentation>)},
        {"ppt/_rels/presentation.xml.rels",
         DocumentFixtures.relationships([{"slide", "slide", "slides/slide1.xml"}])},
        {"ppt/slides/slide1.xml", "<slide><p><t>#{text}</t></p></slide>"}
      ])

    assert {:error, message} = Documents.extract(bytes, :pptx)
    assert message =~ "2 MiB text limit"
  end

  test "long worksheet labels are charged before they are repeated across rows" do
    label = Base.encode16(:crypto.strong_rand_bytes(2_500))
    rows = Enum.map_join(1..10_000, &~s(<row r="#{&1}"/>))

    bytes =
      DocumentFixtures.zip([
        {"_rels/.rels",
         DocumentFixtures.relationships([{"main", "officeDocument", "xl/workbook.xml"}])},
        {"xl/workbook.xml",
         ~s(<workbook xmlns:r="urn:r"><sheets><sheet name="#{label}" r:id="sheet"/></sheets></workbook>)},
        {"xl/_rels/workbook.xml.rels",
         DocumentFixtures.relationships([{"sheet", "worksheet", "worksheets/sheet1.xml"}])},
        {"xl/worksheets/sheet1.xml", "<worksheet><sheetData>#{rows}</sheetData></worksheet>"}
      ])

    assert {:error, "Extracted document exceeds the 2 MiB text limit"} =
             Documents.extract(bytes, :xlsx)
  end

  test "ZIP descriptors are validated and incomplete deflate streams are rejected" do
    for descriptor <- [:signed, :unsigned] do
      bytes = DocumentFixtures.lying_zip("member.xml", "<root/>", 7, descriptor: descriptor)
      assert {:ok, archive} = Handbean.Documents.Archive.open(bytes)
      assert {:ok, "<root/>"} = Handbean.Documents.Archive.fetch(archive, "member.xml")
    end

    bytes = DocumentFixtures.lying_zip("member.xml", "<root/>", 7, truncate: true)
    assert {:ok, archive} = Handbean.Documents.Archive.open(bytes)
    assert {:error, _} = Handbean.Documents.Archive.fetch(archive, "member.xml")
  end

  test "caller cancellation terminates the parser and its admission guardian" do
    supervisor = Process.whereis(Documents.Workers)
    :erlang.trace(supervisor, true, [:procs, :set_on_spawn])
    bytes = DocumentFixtures.pdf(String.duplicate("0 0 m\n", 70_000))
    caller = spawn(fn -> Documents.extract(bytes, :pdf) end)

    try do
      assert_receive {:trace, ^supervisor, :spawn, guardian, _}
      assert_receive {:trace, ^guardian, :spawn, parser, _}
      assert :erlang.suspend_process(parser)
      assert Process.alive?(parser)
      guardian_ref = Process.monitor(guardian)
      parser_ref = Process.monitor(parser)
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^parser_ref, :process, ^parser, :killed}, 1_000
      assert_receive {:DOWN, ^guardian_ref, :process, ^guardian, _}, 1_000
    after
      Process.exit(caller, :kill)
      :erlang.trace(supervisor, false, [:procs, :set_on_spawn])
    end
  end

  test "the extraction-only dependency starts with bounded policy and preserved source provenance" do
    limits = NativeElixirPdfUtilities.Limits.effective()
    assert limits.max_pdf_input_bytes == Documents.max_input_bytes()
    assert limits.max_extracted_text_bytes == 2 * 1024 * 1024
    refute Code.ensure_loaded?(Resvg)

    manifest =
      "vendor/handbean_pdf_parser/UPSTREAM.json" |> File.read!() |> Handbean.JSON.decode!()

    for {path, expected} <- manifest["files"] do
      actual =
        Path.join("vendor/handbean_pdf_parser", path)
        |> File.read!()
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      assert actual == expected, "vendored source drift: #{path}"
    end
  end
end
