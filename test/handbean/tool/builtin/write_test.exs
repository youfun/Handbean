defmodule Handbean.Tool.Builtin.WriteTest do
  @moduledoc """
  Tests for the write builtin tool.

  Reference: `alloy/` (Write tool behavior)
  Test pattern: hand-written

  Covers:
    - Writing to a new file
    - Creating parent directories
    - Overwriting an existing file
    - Validation (missing params)
    - Output metadata (bytes, lines)
  """

  use Handbean.DataCase, async: false

  alias Handbean.Tool.Builtin.Write

  @work_dir Path.join(System.tmp_dir!(), "sigil_write_test_#{System.unique_integer([:positive])}")

  setup do
    File.mkdir_p!(@work_dir)
    on_exit(fn -> File.rm_rf!(@work_dir) end)
  end

  describe "file creation" do
    test "writes content to a new file" do
      path = Path.join(@work_dir, "new.txt")

      {:ok, output, data} =
        Write.execute(
          %{"file_path" => path, "content" => "hello\nworld\n"},
          %{working_directory: @work_dir, conversation_id: "write-test"}
        )

      assert output =~ "Wrote"
      assert data.file_path == path
      assert data.bytes == 12
      # String.split("hello\nworld\n", "\n") => ["hello", "world", ""] => 3
      assert data.lines == 3
      assert data.change_type == "write"
      assert data.existed_before == false
      assert data.reversible == true
      assert data.revert_status == "available"
      refute Map.has_key?(data, :before_content)
      refute Map.has_key?(data, :after_content)
      assert {:ok, snapshot} = Handbean.ChangeSnapshot.load(data.change_snapshot_ref)
      assert snapshot["before_content"] == nil
      assert snapshot["after_content"] == "hello\nworld\n"
      assert File.read!(path) == "hello\nworld\n"
    end

    test "creates parent directories" do
      path = Path.join(@work_dir, "sub1/sub2/deep.txt")

      {:ok, output, data} =
        Write.execute(
          %{"file_path" => "sub1/sub2/deep.txt", "content" => "deep content\n"},
          %{working_directory: @work_dir}
        )

      assert output =~ "Wrote"
      assert data.file_path == path
      assert File.exists?(path)
      assert File.read!(path) == "deep content\n"
    end

    test "creates a missing directory tree instead of reporting EACCES" do
      path = Path.join(@work_dir, "desktop/macos/Sources/Handbean/main.swift")

      {:ok, output, _data} =
        Write.execute(
          %{
            "file_path" => "desktop/macos/Sources/Handbean/main.swift",
            "content" => "import AppKit\n"
          },
          %{working_directory: @work_dir}
        )

      assert output =~ "Wrote"
      refute output =~ "EACCES"
      assert File.read!(path) == "import AppKit\n"
    end

    @tag :"BDD-WRITE-004"
    test "writes empty content" do
      path = Path.join(@work_dir, "empty.txt")

      {:ok, output, data} =
        Write.execute(
          %{"file_path" => path, "content" => ""},
          %{working_directory: @work_dir}
        )

      assert output =~ "Wrote"
      assert data.bytes == 0
      # String.split("", "\n") => [""] => 1 (single empty line)
      assert data.lines == 1
      assert File.exists?(path)
      assert File.read!(path) == ""
    end

    @tag :"BDD-WRITE-005"
    test "writes UTF-8 multi-byte content" do
      path = Path.join(@work_dir, "utf8.txt")
      content = "你好世界"

      {:ok, _output, data} =
        Write.execute(
          %{"file_path" => path, "content" => content},
          %{working_directory: @work_dir}
        )

      assert data.bytes == 12
      assert data.lines == 1
      assert File.read!(path) == content
    end
  end

  describe "overwrite" do
    test "overwrites an existing file" do
      path = Path.join(@work_dir, "overwrite.txt")
      File.write!(path, "old content\n")

      {:ok, output, data} =
        Write.execute(
          %{"file_path" => path, "content" => "new content\n"},
          %{working_directory: @work_dir, conversation_id: "write-test"}
        )

      assert output =~ "Wrote"
      assert data.existed_before == true
      refute Map.has_key?(data, :before_content)
      refute Map.has_key?(data, :after_content)
      assert {:ok, snapshot} = Handbean.ChangeSnapshot.load(data.change_snapshot_ref)
      assert snapshot["before_content"] == "old content\n"
      assert snapshot["after_content"] == "new content\n"
      assert is_list(data.diff_lines)
      assert File.read!(path) == "new content\n"
    end
  end

  describe "validation" do
    test "requires file_path and content" do
      {:error, reason} =
        Write.execute(
          %{"content" => "data"},
          %{working_directory: @work_dir}
        )

      assert reason =~ "file_path"

      {:error, reason2} =
        Write.execute(
          %{"file_path" => "x.txt"},
          %{working_directory: @work_dir}
        )

      assert reason2 =~ "content"
    end
  end

  describe "security — error conditions" do
    @tag :"BDD-WRITE-006"
    test "rejects writing to a directory target" do
      subdir = Path.join(@work_dir, "subdir")
      File.mkdir_p!(subdir)

      {:error, reason} =
        Write.execute(
          %{"file_path" => subdir, "content" => "test"},
          %{working_directory: @work_dir}
        )

      assert reason =~ "Is a directory"
    end

    @tag :"BDD-WRITE-007"
    test "rejects writing into a read-only directory" do
      ro_dir = Path.join(@work_dir, "readonly_dir")
      File.mkdir_p!(ro_dir)
      # Create a placeholder so the dir exists, then remove write bit
      File.chmod!(ro_dir, 0o555)

      {:error, reason} =
        Write.execute(
          %{"file_path" => Path.join(ro_dir, "new_file.txt"), "content" => "test"},
          %{working_directory: @work_dir}
        )

      assert reason =~ "not writeable" or reason =~ "EACCES"
    end
  end

  describe "security — workspace boundary" do
    test "rejects writing files outside the workspace" do
      {:error, reason} =
        Write.execute(
          %{"file_path" => "/etc/should_not_exist", "content" => "data"},
          %{working_directory: @work_dir}
        )

      assert reason =~ "Path traversal" or reason =~ "outside workspace"
    end

    test "rejects relative path traversal for write" do
      {:error, reason} =
        Write.execute(
          %{"file_path" => "../../etc/hack", "content" => "data"},
          %{working_directory: @work_dir}
        )

      assert reason =~ "Path traversal" or reason =~ "outside workspace"
    end

    test "yolo writes outside the workspace" do
      outside_dir =
        Path.join(System.tmp_dir!(), "handbean-yolo-write-#{System.unique_integer([:positive])}")

      outside = Path.join(outside_dir, "nested/file.txt")
      on_exit(fn -> File.rm_rf!(outside_dir) end)

      assert {:ok, _output, %{file_path: ^outside}} =
               Write.execute(
                 %{"file_path" => outside, "content" => "outside"},
                 %{
                   working_directory: @work_dir,
                   approval_mode: :yolo,
                   conversation_id: "write-yolo-test"
                 }
               )

      assert File.read!(outside) == "outside"
    end

    @tag :"BDD-WRITE-010"
    test "writes through symlink to file inside workspace" do
      # Gong scenario: symlink overwrite writes through to real target.
      real_path = Path.join(@work_dir, "real.txt")
      link_path = Path.join(@work_dir, "link.txt")
      File.write!(real_path, "original")
      File.ln_s!(real_path, link_path)

      {:ok, _output, _data} =
        Write.execute(
          %{"file_path" => link_path, "content" => "via symlink"},
          %{working_directory: @work_dir}
        )

      assert File.read!(real_path) == "via symlink"
    end

    @tag :"BDD-WRITE-010"
    test "blocks symlink that points outside workspace" do
      # Handbean security policy: symlink escape is blocked via validate_within_workspace.
      link_path = Path.join(@work_dir, "escape_link")
      File.ln_s!("/etc/hosts", link_path)

      {:error, reason} =
        Write.execute(
          %{"file_path" => link_path, "content" => "data"},
          %{working_directory: @work_dir}
        )

      assert reason =~ "outside workspace"
    end
  end

  describe "output metadata" do
    @tag :"BDD-WRITE-009"
    test "returns correct byte count" do
      path = Path.join(@work_dir, "bytes.txt")

      {:ok, _output, data} =
        Write.execute(
          %{"file_path" => path, "content" => "12345"},
          %{working_directory: @work_dir}
        )

      assert data.bytes == 5
    end

    @tag :"BDD-WRITE-011"
    test "returns correct byte count for UTF-8 multi-byte content" do
      path = Path.join(@work_dir, "utf8_bytes.txt")

      {:ok, _output, data} =
        Write.execute(
          %{"file_path" => path, "content" => "你好"},
          %{working_directory: @work_dir}
        )

      # "你好" = 2 characters × 3 bytes each = 6 bytes
      assert data.bytes == 6
    end
  end

  describe "tilde expansion" do
    test "expands ~ in file paths" do
      tmp_name = "_sigil_tilde_test_#{System.unique_integer([:positive])}.txt"
      tmp_path = Path.join(Handbean.Home.path(), tmp_name)

      try do
        {:ok, output, _data} =
          Write.execute(
            %{"file_path" => "~/#{tmp_name}", "content" => "expanded write\n"},
            %{working_directory: Handbean.Home.path()}
          )

        assert output =~ "Wrote"
        assert File.read!(tmp_path) == "expanded write\n"
      after
        File.rm(tmp_path)
      end
    end
  end

  describe "tool metadata" do
    test "has correct name" do
      assert Write.name() == "write"
    end

    test "has input_schema with required fields" do
      schema = Write.input_schema()
      assert "file_path" in schema.required
      refute "content" in schema.required
      assert schema.properties.content.type == "string"
      assert schema.properties.retry_of.type == "string"
    end

    test "declares concurrent? as false" do
      assert Write.concurrent?() == false
    end
  end
end
