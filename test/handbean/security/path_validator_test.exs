defmodule Handbean.Security.PathValidator.Test do
  @moduledoc """
  Tests for path security validation.

  Reference: `cortex/core/security.ex` (Cortex path validation)
  Test pattern: hand-written from Cortex security behavior

  Covers:
    - validate_readable: existent file, non-existent, directory, permissions
    - validate_writeable: writable path, parent directory when file doesn't exist
    - validate_within_workspace: inside, outside via `../`, absolute path escape, symlink escape
  """

  use ExUnit.Case, async: false

  alias Handbean.Security.PathValidator

  @fixtures_dir Path.join(File.cwd!(), "test/fixtures")
  @sandbox_dir Path.join(
                 System.tmp_dir!(),
                 "sigil_sec_test_#{System.unique_integer([:positive])}"
               )

  setup do
    File.mkdir_p!(@sandbox_dir)
    File.mkdir_p!(Path.join(@sandbox_dir, "subdir"))
    File.write!(Path.join(@sandbox_dir, "readable.txt"), "content")
    File.chmod!(Path.join(@sandbox_dir, "readable.txt"), 0o644)

    on_exit(fn -> File.rm_rf!(@sandbox_dir) end)
  end

  describe "validate_readable/1" do
    test "returns :ok for readable file" do
      path = Path.join(@fixtures_dir, "sample.txt")
      assert PathValidator.validate_readable(path) == :ok
    end

    test "returns error for non-existent file" do
      {:error, reason} = PathValidator.validate_readable("/nonexistent/path.txt")
      assert reason =~ "No such file"
    end

    test "returns error for directory" do
      {:error, reason} = PathValidator.validate_readable(@fixtures_dir)
      assert reason =~ "Is a directory"
    end
  end

  describe "validate_writeable/1" do
    test "returns :ok for writable file" do
      path = Path.join(@sandbox_dir, "readable.txt")
      assert PathValidator.validate_writeable(path) == :ok
    end

    test "validates parent directory when file doesn't exist" do
      subdir = Path.join(@sandbox_dir, "subdir")
      path = Path.join(subdir, "new.txt")
      assert PathValidator.validate_writeable(path) == :ok
    end

    test "checks the nearest existing ancestor when parents are missing" do
      path = Path.join(@sandbox_dir, "desktop/macos/Sources/main.swift")
      assert PathValidator.validate_writeable(path) == :ok
    end

    test "rejects a missing tree under a read-only ancestor" do
      ro_dir = Path.join(@sandbox_dir, "readonly_dir")
      File.mkdir_p!(ro_dir)
      File.chmod!(ro_dir, 0o555)

      path = Path.join(ro_dir, "nested/new.txt")
      {:error, reason} = PathValidator.validate_writeable(path)
      assert reason =~ "not writeable"
    end
  end

  describe "validate_within_workspace/2 — workspace boundary" do
    test "allows paths inside workspace" do
      file = Path.join(@sandbox_dir, "readable.txt")
      assert PathValidator.validate_within_workspace(file, @sandbox_dir) == :ok
    end

    test "allows the workspace root itself" do
      assert PathValidator.validate_within_workspace(@sandbox_dir, @sandbox_dir) == :ok
    end

    # ── ../ traversal escape ──
    # Reference: cortex/core/security.ex — path traversal blocking

    test "blocks ../ traversal escape" do
      # Resolve `..` to go outside the workspace
      escape_path = Path.join(@sandbox_dir, "../secret.txt")

      {:error, reason} = PathValidator.validate_within_workspace(escape_path, @sandbox_dir)
      assert reason =~ "Path traversal blocked"
      assert reason =~ "outside workspace"
    end

    test "blocks ../ chain traversal" do
      escape_path = Path.join(@sandbox_dir, "../../etc/passwd")

      {:error, reason} = PathValidator.validate_within_workspace(escape_path, @sandbox_dir)
      assert reason =~ "outside workspace"
    end

    # ── Absolute path escape ──

    test "blocks absolute path that points outside workspace" do
      {:error, reason} = PathValidator.validate_within_workspace("/etc/passwd", @sandbox_dir)
      assert reason =~ "outside workspace"
    end

    test "allows absolute path that is within workspace" do
      abs = Path.expand(@sandbox_dir)
      assert PathValidator.validate_within_workspace(abs, abs) == :ok
    end

    # ── Symlink traversal escape ──

    test "blocks symlink pointing outside workspace" do
      link = Path.join(@sandbox_dir, "escape_link")
      File.ln_s!("/etc/hosts", link)

      {:error, reason} = PathValidator.validate_within_workspace(link, @sandbox_dir)
      assert reason =~ "outside workspace"
    end

    test "blocks intermediate directory symlink that points outside workspace" do
      outside =
        Path.join(System.tmp_dir!(), "sigil_sec_outside_#{System.unique_integer([:positive])}")

      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "secret.txt"), "nope")
      File.ln_s!(outside, Path.join(@sandbox_dir, "escape"))
      on_exit(fn -> File.rm_rf!(outside) end)

      escaped = Path.join(@sandbox_dir, "escape/secret.txt")
      {:error, reason} = PathValidator.validate_within_workspace(escaped, @sandbox_dir)
      assert reason =~ "outside workspace"

      missing = Path.join(@sandbox_dir, "escape/new-repo")
      {:error, missing_reason} = PathValidator.validate_within_workspace(missing, @sandbox_dir)
      assert missing_reason =~ "outside workspace"
    end

    test "handles symlink loop without infinite recursion" do
      a = Path.join(@sandbox_dir, "loop_a")
      b = Path.join(@sandbox_dir, "loop_b")
      File.ln_s!(b, a)
      File.ln_s!(a, b)

      assert {:error, "Path traversal blocked: " <> _} =
               PathValidator.validate_within_workspace(a, @sandbox_dir)
    end
  end

  describe "validate_under_root/2 — session store / event dir guard" do
    @allowed_root Path.join(
                    System.tmp_dir!(),
                    "sigil_sec_under_root_#{System.unique_integer([:positive])}"
                  )

    setup do
      File.mkdir_p!(@allowed_root)
      on_exit(fn -> File.rm_rf!(@allowed_root) end)
    end

    test "allows path inside the allowed root" do
      sub = Path.join(@allowed_root, "subdir")
      assert PathValidator.validate_under_root(sub, @allowed_root) == :ok
    end

    test "allows the allowed root itself" do
      assert PathValidator.validate_under_root(@allowed_root, @allowed_root) == :ok
    end

    test "blocks path outside the allowed root" do
      outside =
        Path.join(System.tmp_dir!(), "definitely_outside_#{System.unique_integer([:positive])}")

      {:error, reason} = PathValidator.validate_under_root(outside, @allowed_root)
      assert reason =~ "Path traversal blocked"
    end

    test "blocks ../ traversal escape" do
      escape = Path.join(@allowed_root, "../escape_#{System.unique_integer([:positive])}")
      {:error, reason} = PathValidator.validate_under_root(escape, @allowed_root)
      assert reason =~ "Path traversal blocked"
    end

    test "allows new path under root when root does not exist yet" do
      new_root =
        Path.join(System.tmp_dir!(), "sigil_sec_new_root_#{System.unique_integer([:positive])}")

      # Root does not exist — prefix check should still allow paths under it
      sub = Path.join(new_root, "child")
      assert PathValidator.validate_under_root(sub, new_root) == :ok
    end

    test "blocks new path outside a non-existent root" do
      new_root =
        Path.join(System.tmp_dir!(), "sigil_sec_new_root2_#{System.unique_integer([:positive])}")

      outside = Path.join(System.tmp_dir!(), "other_#{System.unique_integer([:positive])}")
      {:error, reason} = PathValidator.validate_under_root(outside, new_root)
      assert reason =~ "Path traversal blocked"
    end

    test "blocks a nonexistent tail through an existing symlink ancestor" do
      outside =
        Path.join(System.tmp_dir!(), "sigil_sec_target_#{System.unique_integer([:positive])}")

      File.mkdir_p!(outside)
      File.ln_s!(outside, Path.join(@allowed_root, "escape"))
      on_exit(fn -> File.rm_rf!(outside) end)

      target = Path.join(@allowed_root, "escape/not-created/yet")
      assert {:error, reason} = PathValidator.validate_under_root(target, @allowed_root)
      assert reason =~ "Path traversal blocked"
    end

    test "resolves a symlink root and permits nonexistent descendants" do
      real_root = Path.join(@allowed_root, "real")
      linked_root = Path.join(@allowed_root, "linked")
      File.mkdir_p!(real_root)
      File.ln_s!(real_root, linked_root)

      assert PathValidator.validate_under_root(Path.join(linked_root, "new/tail"), linked_root) ==
               :ok
    end

    test "rejects symlink loops for either target or root" do
      a = Path.join(@allowed_root, "loop-a")
      b = Path.join(@allowed_root, "loop-b")
      File.ln_s!(b, a)
      File.ln_s!(a, b)

      assert {:error, "Path traversal blocked: " <> _} =
               PathValidator.validate_under_root(Path.join(a, "tail"), @allowed_root)

      assert {:error, :symlink_loop} = PathValidator.canonicalize(a)
    end
  end

  # Failure list for the fixed credential denylist:
  #   - ~/.ssh/id_rsa, workspace .env, and a workspace symlink to an outside key are rejected
  #     with "sensitive path blocked" and without the file contents or the full path
  #   - workspace lib/app.ex and README.md are allowed
  #   - .env.local is rejected; .environment and not_id_rsa_notes.md are not
  #   - .gitconfig, .bashrc, .profile, .cer, .crt, and config/*.exs are not rejected
  #   - .config alone is allowed; .config/gcloud is rejected
  #   - cat ~/.ssh/id_rsa is rejected before a process starts; ls of a normal subdirectory is not
  describe "reject_sensitive/1" do
    test "rejects home ssh keys, workspace env files, and symlink escapes" do
      home_key = Path.join(Handbean.Home.path(), ".ssh/id_rsa")
      assert PathValidator.reject_sensitive(home_key) == {:error, "sensitive path blocked"}
      assert PathValidator.reject_resolved("~/.ssh/id_rsa") == {:error, "sensitive path blocked"}

      env = Path.join(@sandbox_dir, ".env")
      File.write!(env, "SECRET_MARKER_DO_NOT_LEAK")
      assert PathValidator.reject_resolved(env) == {:error, "sensitive path blocked"}

      outside =
        Path.join(System.tmp_dir!(), "sigil_sec_key_#{System.unique_integer([:positive])}/.ssh")

      File.mkdir_p!(outside)
      key = Path.join(outside, "id_rsa")
      File.write!(key, "SECRET_KEY_DO_NOT_LEAK")
      link = Path.join(@sandbox_dir, "link")
      File.ln_s!(key, link)
      on_exit(fn -> File.rm_rf!(Path.dirname(outside)) end)

      assert PathValidator.reject_resolved(link) == {:error, "sensitive path blocked"}

      assert {:error, "sensitive path blocked"} =
               Handbean.Agent.Tool.resolve_path(
                 "link",
                 %{working_directory: @sandbox_dir},
                 :read
               )

      assert {:error, "sensitive path blocked"} =
               Handbean.Agent.Tool.resolve_path(
                 ".env",
                 %{working_directory: @sandbox_dir},
                 :read
               )

      assert {:error, reason} =
               Handbean.Agent.Tool.resolve_path(
                 "~/.ssh/id_rsa",
                 %{
                   working_directory: @sandbox_dir
                 },
                 :read
               )

      assert reason == "sensitive path blocked"
      refute reason =~ "SECRET"
      refute reason =~ home_key
    end

    test "blocks MCP OAuth credentials through file and command access" do
      root = Path.join(@sandbox_dir, ".handbean/mcp-oauth")
      File.mkdir_p!(root)
      token = Path.join(root, "tokens.enc")
      File.write!(token, "fake-encrypted-token")
      link = Path.join(@sandbox_dir, "ordinary-looking-file")
      File.ln_s!(token, link)

      for path <- [root, token, link, Path.join(root, "key")] do
        assert PathValidator.reject_resolved(path) == {:error, "sensitive path blocked"}
      end

      assert {:error, "sensitive path blocked"} =
               Handbean.Agent.Tool.resolve_path(link, %{working_directory: @sandbox_dir}, :read)

      assert PathValidator.reject_sensitive_command("cat #{link}", @sandbox_dir) ==
               {:error, "sensitive path blocked"}

      assert PathValidator.reject_sensitive("/project/.HANDBEAN/MCP-OAUTH/tokens.enc") ==
               {:error, "sensitive path blocked"}

      assert PathValidator.reject_sensitive("/project/lib/handbean/mcp/oauth.ex") == :ok
      assert PathValidator.reject_sensitive("/project/.handbean/mcp.json") == :ok
    end

    test "allows ordinary workspace sources and the narrowed config names" do
      app = Path.join(@sandbox_dir, "lib/app.ex")
      readme = Path.join(@sandbox_dir, "README.md")
      File.mkdir_p!(Path.dirname(app))
      File.write!(app, "defmodule App do\nend\n")
      File.write!(readme, "docs")

      assert PathValidator.reject_resolved(app) == :ok
      assert PathValidator.reject_resolved(readme) == :ok

      assert {:ok, _} =
               Handbean.Agent.Tool.resolve_path(
                 "lib/app.ex",
                 %{working_directory: @sandbox_dir},
                 :read
               )

      assert {:ok, _} =
               Handbean.Agent.Tool.resolve_path(
                 "README.md",
                 %{working_directory: @sandbox_dir},
                 :read
               )

      for name <-
            ~w(.environment not_id_rsa_notes.md .gitconfig .bashrc .profile server.cer server.crt models.example.json) do
        path = Path.join(@sandbox_dir, name)
        assert PathValidator.reject_sensitive(path) == :ok
        assert PathValidator.reject_resolved(path) == :ok
      end

      config = Path.join(@sandbox_dir, "config/dev.exs")
      assert PathValidator.reject_sensitive(config) == :ok
      assert PathValidator.reject_sensitive(Path.join(@sandbox_dir, ".config/other.json")) == :ok

      assert PathValidator.reject_sensitive(Path.join(@sandbox_dir, ".config/gcloud/adc.json")) ==
               {:error, "sensitive path blocked"}
    end

    test "matches env prefixes, extensions, and names exactly and case-insensitively" do
      assert PathValidator.reject_sensitive(Path.join(@sandbox_dir, ".env.local")) ==
               {:error, "sensitive path blocked"}

      assert PathValidator.reject_sensitive(Path.join(@sandbox_dir, ".ENV.production")) ==
               {:error, "sensitive path blocked"}

      assert PathValidator.reject_sensitive(Path.join(@sandbox_dir, ".environment")) == :ok
      assert PathValidator.reject_sensitive(Path.join(@sandbox_dir, "not_id_rsa_notes.md")) == :ok

      assert PathValidator.reject_sensitive(Path.join(@sandbox_dir, ".SSH/ID_RSA")) ==
               {:error, "sensitive path blocked"}

      assert PathValidator.reject_sensitive(Path.join(@sandbox_dir, "certs/server.pem")) ==
               {:error, "sensitive path blocked"}
    end
  end

  describe "reject_sensitive_command/2" do
    test "rejects cat ~/.ssh/id_rsa before execution and allows ls of a normal subdirectory" do
      sub = Path.join(@sandbox_dir, "subdir")
      File.mkdir_p!(sub)

      assert PathValidator.reject_sensitive_command("cat ~/.ssh/id_rsa", @sandbox_dir) ==
               {:error, "sensitive path blocked"}

      assert PathValidator.reject_sensitive_command("ls #{sub}", @sandbox_dir) == :ok
      assert PathValidator.reject_sensitive_command("ls subdir", @sandbox_dir) == :ok
    end

    test "does not raise on non-path tokens that Windows Path.expand/2 rejects" do
      win_cwd = "f:/Fcode/saletool-webui"

      assert PathValidator.reject_sensitive_command("echo [:0]", @sandbox_dir) == :ok
      assert PathValidator.reject_sensitive_command("echo [:0]", win_cwd) == :ok
      assert PathValidator.reject_sensitive_command("echo ./[:0]", @sandbox_dir) == :ok
      assert PathValidator.reject_sensitive_command("echo ./[:0]", win_cwd) == :ok
      assert PathValidator.reject_sensitive_command("echo /[:0]", @sandbox_dir) == :ok
      assert PathValidator.reject_sensitive_command("echo /[:0]", win_cwd) == :ok

      assert PathValidator.reject_sensitive_command(
               "python -c \"print(s[:0])\"",
               win_cwd
             ) == :ok
    end

    test "volume-relative tokens follow the cwd drive on Windows" do
      if match?({:win32, _}, :os.type()) do
        key_root =
          Path.join(System.tmp_dir!(), "sigil_sec_volrel_#{System.unique_integer([:positive])}")

        File.mkdir_p!(key_root)
        key = Path.join(key_root, "id_rsa")
        File.write!(key, "SECRET_KEY_DO_NOT_LEAK")
        on_exit(fn -> File.rm_rf!(key_root) end)

        link = Path.join(@sandbox_dir, "innocent")

        case File.ln_s(key, link) do
          :ok ->
            volrel =
              link
              |> Path.expand()
              |> String.replace(~r/^[a-zA-Z]:/, "")

            assert Path.type(volrel) == :volumerelative

            assert PathValidator.reject_sensitive_command("cat #{volrel}", @sandbox_dir) ==
                     {:error, "sensitive path blocked"}

          {:error, reason} when reason in [:eperm, :eacces, :enotsup] ->
            # This host cannot create symlinks, so the sensitive-target assertion
            # is unverified here. Still require volume-relative expand not to raise.
            volrel =
              @sandbox_dir
              |> Path.expand()
              |> String.replace(~r/^[a-zA-Z]:/, "")

            assert Path.type(volrel) == :volumerelative
            assert PathValidator.reject_sensitive_command("ls #{volrel}", @sandbox_dir) == :ok

          {:error, reason} ->
            flunk("unexpected symlink failure: #{inspect(reason)}")
        end
      else
        assert Path.type("/usr") == :absolute
      end
    end
  end
end
