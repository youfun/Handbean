defmodule Handbean.WorkspaceTest do
  @moduledoc """
  Tests for Handbean.Workspace — workspace path management.

  Covers:
    - Default root is ~/.handbean/workspace
    - HANDBEAN_WORKSPACE env var overrides default
    - Application env overrides default
    - Env var priority > application env
    - ensure_root!/0 creates directory
    - resolve/1 resolves relative paths against root
    - Workspace outside paths are rejected
    - relative_path/1 returns relative path
  """

  use ExUnit.Case, async: false

  alias Handbean.Workspace

  @test_ws Path.join(System.tmp_dir!(), "sigil_ws_test_#{System.unique_integer([:positive])}")

  setup do
    # Save current env/application state
    saved_env = System.get_env("HANDBEAN_WORKSPACE")
    saved_app = Application.get_env(:handbean, :workspace_root)

    # Clean up for isolated tests
    System.delete_env("HANDBEAN_WORKSPACE")
    Application.delete_env(:handbean, :workspace_root)

    on_exit(fn ->
      # Restore
      if saved_env, do: System.put_env("HANDBEAN_WORKSPACE", saved_env)
      if saved_app, do: Application.put_env(:handbean, :workspace_root, saved_app)

      # Clean up test workspace directory if created
      if File.exists?(@test_ws), do: File.rm_rf!(@test_ws)
    end)

    :ok
  end

  describe "root/0" do
    test "default root is ~/.handbean/workspace" do
      assert Workspace.root() == Handbean.Home.expand("~/.handbean/workspace")
    end

    test "HANDBEAN_WORKSPACE env var overrides default" do
      System.put_env("HANDBEAN_WORKSPACE", @test_ws)
      assert Workspace.root() == Path.expand(@test_ws)
    end

    test "application env overrides default" do
      Application.put_env(:handbean, :workspace_root, @test_ws)
      assert Workspace.root() == Path.expand(@test_ws)
    end

    test "env var has priority over application env" do
      env_path = Path.join(@test_ws, "from_env")
      app_path = Path.join(@test_ws, "from_app")

      System.put_env("HANDBEAN_WORKSPACE", env_path)
      Application.put_env(:handbean, :workspace_root, app_path)

      assert Workspace.root() == Path.expand(env_path)
    end

    test "expands tilde paths" do
      System.put_env("HANDBEAN_WORKSPACE", "~/custom/ws")
      expected = Handbean.Home.expand("~/custom/ws")
      assert Workspace.root() == expected
    end
  end

  describe "ensure_root!/0" do
    test "creates directory if it doesn't exist" do
      ws = Path.join(@test_ws, "nested/path")
      System.put_env("HANDBEAN_WORKSPACE", ws)

      refute File.exists?(ws)
      ensure_root = Workspace.ensure_root!()
      assert ensure_root == Path.expand(ws)
      assert File.dir?(ensure_root)
    end

    test "works when directory already exists" do
      File.mkdir_p!(@test_ws)
      System.put_env("HANDBEAN_WORKSPACE", @test_ws)

      assert Workspace.ensure_root!() == Path.expand(@test_ws)
    end
  end

  describe "resolve/1" do
    test "relative path is resolved against workspace root" do
      File.mkdir_p!(@test_ws)
      System.put_env("HANDBEAN_WORKSPACE", @test_ws)

      {:ok, resolved} = Workspace.resolve("hello.exs")
      assert resolved == Path.expand(Path.join(@test_ws, "hello.exs"))
    end

    test "absolute path stays absolute if within workspace" do
      File.mkdir_p!(@test_ws)
      System.put_env("HANDBEAN_WORKSPACE", @test_ws)

      target = Path.join(@test_ws, "lib/foo.ex")
      File.mkdir_p!(Path.dirname(target))
      File.write!(target, "x")

      {:ok, resolved} = Workspace.resolve(target)
      assert resolved == Path.expand(target)
    end

    test "absolute path outside workspace is rejected" do
      File.mkdir_p!(@test_ws)
      System.put_env("HANDBEAN_WORKSPACE", @test_ws)

      {:error, reason} = Workspace.resolve("/etc/passwd")
      assert reason =~ "outside workspace"
    end

    test "relative path with .. traversal outside workspace is rejected" do
      File.mkdir_p!(@test_ws)
      System.put_env("HANDBEAN_WORKSPACE", @test_ws)

      {:error, reason} = Workspace.resolve("../etc/passwd")
      assert reason =~ "outside workspace"
    end
  end

  describe "relative_path/1" do
    test "returns relative path for workspace-internal file" do
      File.mkdir_p!(@test_ws)
      System.put_env("HANDBEAN_WORKSPACE", @test_ws)

      abs = Path.expand(Path.join(@test_ws, "hello.exs"))
      assert Workspace.relative_path(abs) == "hello.exs"
    end

    test "returns relative path for nested workspace file" do
      File.mkdir_p!(@test_ws)
      System.put_env("HANDBEAN_WORKSPACE", @test_ws)

      abs = Path.expand(Path.join(@test_ws, "lib/my_app.ex"))
      assert Workspace.relative_path(abs) == "lib/my_app.ex"
    end

    test "returns basename for paths outside workspace" do
      File.mkdir_p!(@test_ws)
      System.put_env("HANDBEAN_WORKSPACE", @test_ws)

      rel = Workspace.relative_path("/etc/passwd")
      assert rel == "passwd"
    end
  end

  describe "within?/1" do
    test "returns true for workspace-internal path" do
      File.mkdir_p!(@test_ws)
      System.put_env("HANDBEAN_WORKSPACE", @test_ws)

      target = Path.join(@test_ws, "file.txt")
      File.write!(target, "x")

      assert Workspace.within?(target) == true
    end

    test "returns false for workspace-external path" do
      File.mkdir_p!(@test_ws)
      System.put_env("HANDBEAN_WORKSPACE", @test_ws)

      assert Workspace.within?("/etc/passwd") == false
    end
  end

  describe "resolve/2 with overridable workspace_root" do
    test "resolves relative path against custom workspace_root" do
      custom_ws = Path.join(@test_ws, "custom_project")
      File.mkdir_p!(custom_ws)

      {:ok, resolved} = Workspace.resolve("src/main.ex", custom_ws)
      assert resolved == Path.expand(Path.join(custom_ws, "src/main.ex"))
    end

    test "allows absolute path within custom workspace_root" do
      custom_ws = Path.join(@test_ws, "custom_project")
      File.mkdir_p!(custom_ws)

      target = Path.join(custom_ws, "README.md")
      File.write!(target, "readme")

      {:ok, resolved} = Workspace.resolve(target, custom_ws)
      assert resolved == Path.expand(target)
    end

    test "blocks absolute path outside custom workspace_root" do
      custom_ws = Path.join(@test_ws, "project_a")
      other_ws = Path.join(@test_ws, "project_b")
      File.mkdir_p!(custom_ws)
      File.mkdir_p!(other_ws)

      target = Path.join(other_ws, "secret.txt")
      File.write!(target, "secret")

      {:error, reason} = Workspace.resolve(target, custom_ws)
      assert reason =~ "outside workspace"
    end

    test "resolve/1 still uses global root for backward compat" do
      File.mkdir_p!(@test_ws)
      System.put_env("HANDBEAN_WORKSPACE", @test_ws)

      target = Path.join(@test_ws, "file.txt")
      File.write!(target, "content")

      {:ok, resolved} = Workspace.resolve(target)
      assert resolved == Path.expand(target)
    end
  end

  describe "validate_within/2 with overridable workspace_root" do
    test "accepts custom workspace_root" do
      custom_ws = Path.join(@test_ws, "custom_project")
      File.mkdir_p!(custom_ws)

      target = Path.join(custom_ws, "file.ex")
      File.write!(target, "x")

      assert Workspace.validate_within(target, custom_ws) == :ok
    end

    test "rejects path outside custom workspace_root" do
      custom_ws = Path.join(@test_ws, "custom_project")
      File.mkdir_p!(custom_ws)

      {:error, reason} = Workspace.validate_within("/etc/passwd", custom_ws)
      assert reason =~ "outside workspace"
    end

    test "validate_within/1 still uses global root for backward compat" do
      File.mkdir_p!(@test_ws)
      System.put_env("HANDBEAN_WORKSPACE", @test_ws)

      assert Workspace.validate_within(Path.expand(@test_ws)) == :ok
    end
  end
end
