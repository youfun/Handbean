defmodule Handbean.Tool.Builtin.DocumentReadTest do
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  alias Handbean.DocumentFixtures
  alias Handbean.Tool.Builtin.Read

  test "read routes supported documents before binary detection and exposes continuation", %{
    tmp_dir: root
  } do
    for {name, expected} <- [
          {"multilingual.pdf", "Quarterly report"},
          {"report.docx", "中文段落"},
          {"budget.xlsx", "预算"},
          {"slides.pptx", "Opening 中文"}
        ] do
      File.write!(Path.join(root, name), DocumentFixtures.read(name))

      assert {:ok, output, metadata} =
               Read.execute(%{"file_path" => name, "limit" => 1}, %{working_directory: root})

      assert output =~ expected
      assert metadata.extracted_document
      assert metadata.truncated
      assert metadata.next_offset == 2

      assert {:ok, later, _} =
               Read.execute(%{"file_path" => name, "offset" => metadata.next_offset}, %{
                 working_directory: root
               })

      assert later != output
    end
  end

  test "PDF signature is sufficient even without a PDF extension", %{tmp_dir: root} do
    File.write!(Path.join(root, "download"), DocumentFixtures.read("multilingual.pdf"))

    assert {:ok, output, %{format: :pdf}} =
             Read.execute(%{"file_path" => "download"}, %{working_directory: root})

    assert output =~ "中文文档测试：你好世界"
  end

  test "document routes retain read authorization and sensitive path checks", %{tmp_dir: root} do
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    outside = Path.join(root, "outside.pdf")
    File.write!(outside, DocumentFixtures.read("multilingual.pdf"))

    assert {:error, _} =
             Read.execute(%{"file_path" => "../outside.pdf"}, %{working_directory: workspace})

    File.ln_s!(outside, Path.join(workspace, "escape.pdf"))

    assert {:error, _} =
             Read.execute(%{"file_path" => "escape.pdf"}, %{working_directory: workspace})

    File.write!(Path.join(workspace, ".env"), DocumentFixtures.read("multilingual.pdf"))

    assert {:error, "sensitive path blocked"} =
             Read.execute(%{"file_path" => ".env"}, %{
               working_directory: workspace,
               approval_mode: :yolo
             })

    assert {:ok, output, _} =
             Read.execute(%{"file_path" => outside}, %{
               working_directory: workspace,
               approval_mode: :yolo
             })

    assert output =~ "[Page 2]"
  end

  test "rejects invalid pagination and fake document extensions without parser crashes", %{
    tmp_dir: root
  } do
    File.write!(Path.join(root, "fake.pdf"), "/etc/passwd")

    assert {:error, "Invalid PDF signature"} =
             Read.execute(%{"file_path" => "fake.pdf"}, %{working_directory: root})

    for input <- [%{"offset" => -1}, %{"offset" => "1"}, %{"limit" => 0}, %{"limit" => 2_001}] do
      assert {:error, _} =
               Read.execute(Map.put(input, "file_path", "fake.pdf"), %{working_directory: root})
    end
  end
end
