defmodule Handbean.Tool.Builtin.BashTest do
  @moduledoc """
  Tests for the bash builtin tool.

  Reference: `gong/tools/bash.ex` (Gong Bash tool behavior)
  Test pattern: hand-written from Gong Bash source behavior

  Covers:
    - Successful command execution
    - Command with non-zero exit code
    - cwd override
    - Timeout handling
    - Empty command rejection
    - Output truncation for large output
    - Process tree killing on timeout
  """

  use ExUnit.Case, async: false

  alias Handbean.Tool.Builtin.Bash

  describe "basic command execution" do
    @describetag :os_sandbox
    test "executes a simple command and returns output" do
      {:ok, output, data} =
        Bash.execute(
          %{"command" => "echo hello"},
          %{working_directory: File.cwd!()}
        )

      assert output =~ "hello"
      assert data.exit_code == 0
    end

    test "captures multi-line output" do
      {:ok, output, data} =
        Bash.execute(
          %{"command" => "printf 'a\\nb\\nc'"},
          %{working_directory: File.cwd!()}
        )

      assert output =~ "a"
      assert output =~ "b"
      assert output =~ "c"
      assert data.exit_code == 0
    end
  end

  describe "non-zero exit code" do
    @describetag :os_sandbox
    test "reports non-zero exit code in output" do
      {:ok, output, data} =
        Bash.execute(
          %{"command" => "exit 1"},
          %{working_directory: File.cwd!()}
        )

      assert output =~ "exited with code 1"
      assert data.exit_code == 1
    end
  end

  describe "cwd override" do
    @describetag :os_sandbox
    test "executes command in specified directory" do
      # Use a subdirectory of the current working directory to stay within workspace
      tmp_dir = Path.join(File.cwd!(), "tmp_bash_cwd_test")
      File.mkdir_p!(tmp_dir)

      try do
        {:ok, output, _data} =
          Bash.execute(
            %{"command" => "pwd", "cwd" => tmp_dir},
            %{working_directory: File.cwd!()}
          )

        # pwd should output the specified directory
        assert String.trim(output) == tmp_dir
      after
        File.rm_rf(tmp_dir)
      end
    end

    test "returns error for non-existent cwd" do
      result =
        Bash.execute(
          %{"command" => "echo x", "cwd" => "/nonexistent/path"},
          %{working_directory: "/nonexistent/path"}
        )

      assert {:error, "cwd /nonexistent/path is not a directory"} = result
    end

    test "rejects file as cwd" do
      tmp_file =
        Path.join(System.tmp_dir!(), "bash_cwd_test_#{System.unique_integer([:positive])}")

      File.write!(tmp_file, "data")

      try do
        result =
          Bash.execute(
            %{"command" => "echo x", "cwd" => tmp_file},
            %{working_directory: System.tmp_dir!()}
          )

        assert {:error, "cwd " <> _} = result
      after
        File.rm(tmp_file)
      end
    end
  end

  describe "validation" do
    test "rejects empty command" do
      {:error, reason} =
        Bash.execute(
          %{"command" => "", "timeout" => 10},
          %{working_directory: File.cwd!()}
        )

      assert reason =~ "non-empty"
    end

    test "requires command key" do
      {:error, reason} =
        Bash.execute(
          %{"timeout" => 10},
          %{working_directory: File.cwd!()}
        )

      assert reason =~ "required"
    end
  end

  describe "timeout handling" do
    @describetag :os_sandbox
    test "kills command that exceeds timeout" do
      {:ok, output, data} =
        Bash.execute(
          %{"command" => "sleep 10", "timeout" => 1},
          %{working_directory: File.cwd!()}
        )

      assert output =~ "timed out"
      assert data.timed_out == true
    end
  end

  describe "output truncation" do
    @describetag :os_sandbox
    test "handles large output gracefully" do
      # Generate enough output to potentially trigger truncation
      {:ok, output, _data} =
        Bash.execute(
          %{"command" => "yes head | head -1000"},
          %{working_directory: File.cwd!()}
        )

      assert output =~ "head"
    end
  end

  describe "security — workspace boundary" do
    @tag :os_sandbox
    test "runtime-computed paths cannot modify the host outside the workspace" do
      # Requires the OS workspace sandbox; path-validation-only cases below remain portable.
      workspace =
        Path.join(System.tmp_dir!(), "bash_sandbox_ws_#{System.unique_integer([:positive])}")

      outside =
        Path.join(System.tmp_dir!(), "bash_sandbox_escape_#{System.unique_integer([:positive])}")

      File.mkdir_p!(workspace)

      try do
        {:ok, output, _data} =
          Bash.execute(
            %{
              "command" =>
                "target=$(printf '%s' '#{outside}'); printf escaped > \"$target\"; cat \"$target\""
            },
            %{working_directory: workspace}
          )

        # Linux absorbs the write into a private tmpfs; macOS denies it outright.
        assert output =~ "escaped" or output =~ "Operation not permitted"
        refute File.exists?(outside)
      after
        File.rm_rf(workspace)
        File.rm(outside)
      end
    end

    @tag :os_sandbox
    test "workspace writes persist through the sandbox" do
      workspace =
        Path.join(System.tmp_dir!(), "bash_sandbox_write_#{System.unique_integer([:positive])}")

      File.mkdir_p!(workspace)

      try do
        {:ok, _output, data} =
          Bash.execute(
            %{"command" => "printf inside > result.txt"},
            %{working_directory: workspace}
          )

        assert data.exit_code == 0
        assert File.read!(Path.join(workspace, "result.txt")) == "inside"
      after
        File.rm_rf(workspace)
      end
    end

    test "rejects cwd outside the workspace" do
      {:error, reason} =
        Bash.execute(
          %{"command" => "ls", "cwd" => "/etc"},
          %{working_directory: File.cwd!()}
        )

      assert reason =~ "Path traversal" or reason =~ "outside workspace"
    end

    test "rejects relative cwd traversal outside workspace" do
      {:error, reason} =
        Bash.execute(
          %{"command" => "ls", "cwd" => "../../etc"},
          %{working_directory: File.cwd!()}
        )

      assert reason =~ "Path traversal" or reason =~ "outside workspace"
    end

    test "yolo runs with a cwd outside the workspace" do
      outside =
        Path.join(System.tmp_dir!(), "handbean-yolo-cwd-#{System.unique_integer([:positive])}")

      File.mkdir_p!(outside)
      on_exit(fn -> File.rm_rf!(outside) end)

      assert {:ok, output, %{exit_code: 0}} =
               Bash.execute(
                 %{"command" => "pwd", "cwd" => outside},
                 %{working_directory: File.cwd!(), approval_mode: :yolo}
               )

      # macOS resolves /var to /private/var; normalize both sides before comparing.
      normalize = &String.replace(&1, ~r{^/private}, "")
      assert normalize.(String.trim(output)) == normalize.(outside)
    end

    @tag :os_sandbox
    test "allows reading host paths outside the workspace" do
      {:ok, output, data} =
        Bash.execute(
          %{"command" => "test -f /etc/hosts 2>/dev/null && echo host-readable"},
          %{working_directory: File.cwd!()}
        )

      assert output =~ "host-readable"
      assert data.exit_code == 0
    end

    @tag :os_sandbox
    test "allows /dev/null as a shell redirection target" do
      {:ok, output, data} =
        Bash.execute(
          %{"command" => "echo hidden >/dev/null && echo visible 2>/dev/null"},
          %{working_directory: File.cwd!()}
        )

      assert String.trim(output) == "visible"
      assert data.exit_code == 0
    end

    @tag :os_sandbox
    test "allows commands that reference paths within the workspace" do
      tmp_dir = Path.join(File.cwd!(), "tmp_bash_guard_test")
      File.mkdir_p!(tmp_dir)

      try do
        {:ok, output, _data} =
          Bash.execute(
            %{"command" => "echo #{tmp_dir}/file"},
            %{working_directory: File.cwd!()}
          )

        assert output =~ "tmp_bash_guard_test"
      after
        File.rm_rf(tmp_dir)
      end
    end

    @tag :os_sandbox
    test "allows reading a workspace symlink that points to a host file" do
      escaped_link = Path.join(File.cwd!(), "tmp_bash_symlink_escape")

      # Linux mounts a private /tmp. A host-read fixture must live outside it.
      outside =
        Path.join(
          Path.dirname(File.cwd!()),
          "bash-readable-host-#{System.unique_integer([:positive])}"
        )

      File.write!(outside, "host-readable")
      File.ln_s!(outside, escaped_link)

      try do
        {:ok, output, data} =
          Bash.execute(
            %{"command" => "cat #{escaped_link}"},
            %{working_directory: File.cwd!()}
          )

        assert output =~ "host-readable"
        assert data.exit_code == 0
      after
        File.rm(escaped_link)
        File.rm(outside)
      end
    end
  end

  describe "tool metadata" do
    test "has correct name" do
      assert Bash.name() == "bash"
    end

    test "has input_schema with command required" do
      schema = Bash.input_schema()
      assert "command" in schema.required
    end

    test "documents cwd as a workspace-relative override instead of a cd prefix" do
      schema = Bash.input_schema()

      assert schema.properties.command.description =~ "Bash"
      assert schema.properties.command.description =~ "Unix-style"
      assert schema.properties.cwd.description =~ "subdirectory"

      assert schema.properties.cwd.description =~
               "inside the current workspace"
    end

    test "description contains Windows compatibility guidance" do
      desc = Bash.description()

      # Must name itself as bash (not shell/terminal)
      assert desc =~ "bash command"

      # Must guide LLM to use Unix-style commands
      assert desc =~ "Unix-style commands"

      # Must guide LLM to use forward-slash paths
      assert desc =~ "forward-slash paths"

      # Must mention Windows so LLM knows the abstraction is intentional
      assert desc =~ "even on Windows"
      assert desc =~ "bash environment"
    end

    test "input_schema command description guides LLM to Unix-style commands" do
      schema = Bash.input_schema()
      cmd_desc = schema.properties.command.description

      assert cmd_desc =~ "Bash"
      assert cmd_desc =~ "Unix-style"
      assert cmd_desc =~ "forward-slash paths"
    end

    test "declares concurrent? as false" do
      assert Bash.concurrent?() == false
    end
  end

  # ── BDD scenarios translated from gong/docs/bdd/bash_action.dsl ──

  describe "BDD-BASH-008 stderr 和 stdout 合并" do
    @describetag :os_sandbox
    test "captures both stdout and stderr in output" do
      {:ok, output, data} =
        Bash.execute(
          %{"command" => "echo out; echo err >&2"},
          %{working_directory: File.cwd!()}
        )

      assert output =~ "out"
      assert output =~ "err"
      assert data.exit_code == 0
    end
  end

  describe "BDD-BASH-012 env inheritance" do
    @describetag :os_sandbox
    test "inherits environment variables from parent process" do
      env_key = "HANDBEAN_BDD_ENV_TEST"
      env_val = "gong_env_value_#{System.unique_integer([:positive])}"
      System.put_env(env_key, env_val)

      on_exit(fn -> System.delete_env(env_key) end)

      {:ok, output, data} =
        Bash.execute(
          %{"command" => "echo $#{env_key}"},
          %{working_directory: File.cwd!()}
        )

      assert String.trim(output) == env_val
      assert data.exit_code == 0
    end
  end

  describe "BDD-BASH-013 command not found exit 127" do
    @describetag :os_sandbox
    test "returns exit code 127 for nonexistent command" do
      {:ok, output, data} =
        Bash.execute(
          %{"command" => "nonexistent_command_xyz_123"},
          %{working_directory: File.cwd!()}
        )

      assert data.exit_code == 127
      assert output =~ "Command exited with code 127"
    end
  end

  describe "BDD-BASH-014 返回值含 timed_out=false" do
    @describetag :os_sandbox
    test "returns timed_out: false for successful command" do
      {:ok, _output, data} =
        Bash.execute(
          %{"command" => "echo quick"},
          %{working_directory: File.cwd!()}
        )

      assert data.timed_out == false
    end
  end

  describe "BDD-BASH-017 UTF-8 多字节跨 chunk 边界" do
    @describetag :os_sandbox
    test "handles multi-byte UTF-8 characters across chunk boundaries" do
      # Generate enough UTF-8 content to cross Port chunk boundaries
      # using POSIX shell + printf only (no python3 dependency)
      {:ok, output, data} =
        Bash.execute(
          %{"command" => "for i in $(seq 1 200); do printf '你好世界测试中文多字节内容\\n'; done"},
          %{working_directory: File.cwd!()}
        )

      assert output =~ "你好世界"
      assert String.valid?(output)
      assert data.exit_code == 0
    end
  end

  describe "BDD-BASH-020 管道 SIGPIPE 不报错" do
    @describetag :os_sandbox
    test "handles SIGPIPE in pipeline without error" do
      {:ok, output, data} =
        Bash.execute(
          %{"command" => "yes | head -5"},
          %{working_directory: File.cwd!()}
        )

      assert output =~ "y"
      assert data.exit_code == 0
    end
  end

  describe "BDD-BASH-021 exact omitted line count" do
    @describetag :os_sandbox
    test "reports exact count of omitted lines on truncation" do
      {:ok, output, data} =
        Bash.execute(
          %{"command" => "seq 1 2500"},
          %{working_directory: File.cwd!()}
        )

      # Bash tail-truncation: 2500 lines > @max_output_lines (2000)
      # → 500 lines omitted from front, last 2000 lines kept
      assert output =~ "500 lines omitted"
      assert output =~ "2500"

      # Tail content preserved: first kept line and last line
      assert output =~ "501"

      # Original head sequence must NOT appear intact
      refute output =~ "1\n2\n3\n4\n5"

      assert data.exit_code == 0
    end
  end

  describe "BDD-BASH-022 special chars command" do
    @describetag :os_sandbox
    test "executes command with special characters in quotes" do
      {:ok, output, data} =
        Bash.execute(
          %{"command" => "printf '%s\\n' 'hello \"world\" with \$dollar and spaces'"},
          %{working_directory: File.cwd!()}
        )

      # Must contain the full literal text including quotes, $, spaces
      assert output =~ "hello \"world\" with \$dollar and spaces"
      assert data.exit_code == 0
    end
  end

  describe "BDD-BASH-023 cwd defaults to workspace/temp dir" do
    @describetag :os_sandbox
    test "defaults to working directory when cwd is empty string" do
      tmp_dir = Path.join(File.cwd!(), "tmp_bash_default_cwd")
      File.mkdir_p!(tmp_dir)
      File.write!(Path.join(tmp_dir, "marker.txt"), "found it")

      try do
        {:ok, output, data} =
          Bash.execute(
            %{"command" => "cat marker.txt", "cwd" => ""},
            %{working_directory: tmp_dir}
          )

        assert output =~ "found it"
        assert data.exit_code == 0
      after
        File.rm_rf(tmp_dir)
      end
    end
  end
end
