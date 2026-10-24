defmodule Handbean.WebFetch.DocumentsTest do
  use ExUnit.Case, async: false

  alias Handbean.{DocumentFixtures, WebFetch}
  alias Handbean.WebFetch.Document

  test "public fetching uses the same document extractor and preserves sources and pagination" do
    resolve = fn _, _ -> {:ok, [{8, 8, 8, 8}]} end
    bytes = DocumentFixtures.read("multilingual.pdf")

    request = fn _, _, _ ->
      {:ok, %{status: 200, headers: [{"content-type", "application/pdf"}], body: bytes}}
    end

    assert {:ok, first} =
             WebFetch.fetch("https://example.test/report.pdf", 40,
               resolve: resolve,
               request: request
             )

    assert first.content =~ "[Page 1]"
    assert first.truncated
    assert first.next_offset == 40
    assert first.page_count == 2
    assert first.final_url == "https://example.test/report.pdf"

    assert {:ok, rest} =
             WebFetch.fetch(first.final_url, 20_000,
               resolve: resolve,
               request: request,
               offset: first.next_offset
             )

    assert rest.content =~ "中文文档测试：你好世界"
    assert rest.content =~ "[Page 2]"
    refute rest.truncated
  end

  test "document signatures override or reject mislabeled text/plain responses" do
    assert {:ok, result} =
             Document.extract(
               DocumentFixtures.read("multilingual.pdf"),
               [{"content-type", "text/plain"}],
               URI.parse("https://example.test/download"),
               10_000
             )

    assert result.content =~ "Quarterly report"
    assert result.content =~ "中文文档测试：你好世界"
    assert result.page_count == 2

    assert {:ok, office} =
             Document.extract(
               DocumentFixtures.read("report.docx"),
               [{"content-type", "text/plain"}],
               URI.parse("https://example.test/report.docx"),
               10_000
             )

    assert office.content =~ "中文段落"

    assert {:error, message} =
             Document.extract(
               DocumentFixtures.read("report.docx"),
               [{"content-type", "text/plain"}],
               URI.parse("https://example.test/download"),
               10_000
             )

    assert message =~ "does not identify a supported Office format"
  end

  test "Office MIME and octet-stream filenames bypass text charset decoding" do
    types = [
      {"report.docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
       "中文段落"},
      {"budget.xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "预算"},
      {"slides.pptx", "application/vnd.openxmlformats-officedocument.presentationml.presentation",
       "[Slide 2]"}
    ]

    for {name, type, expected} <- types, mime <- [type, "application/octet-stream"] do
      assert {:ok, result} =
               Document.extract(
                 DocumentFixtures.read(name),
                 [{"content-type", mime}],
                 URI.parse("https://example.test/" <> name),
                 10_000
               )

      assert result.content =~ expected
      assert result.warnings != []
    end
  end

  test "binary payloads cannot become filesystem paths or silently fall back to text" do
    assert {:error, "Invalid PDF signature"} =
             Document.extract("/etc/passwd", [{"content-type", "application/pdf"}], nil, 100)

    assert {:error, _} =
             Document.extract(
               DocumentFixtures.read("encrypted.pdf"),
               [{"content-type", "application/pdf"}],
               nil,
               100
             )

    assert {:error, _} =
             Document.extract(
               DocumentFixtures.read("multilingual.pdf"),
               [{"content-type", "application/pdf"}],
               nil,
               100,
               timeout: 0
             )

    assert {:error, _} = WebFetch.fetch("https://example.test/report.pdf", 100, offset: -1)
  end

  test "redirected PDF fetch still rejects private network destinations before extraction" do
    resolve = fn _, _ -> {:ok, [{8, 8, 8, 8}]} end

    request = fn _, _, _ ->
      {:ok, %{status: 302, headers: [{"location", "http://127.0.0.1/private.pdf"}], body: ""}}
    end

    assert {:error, _} =
             WebFetch.fetch("https://example.test/report.pdf", 100,
               resolve: resolve,
               request: request
             )
  end
end
