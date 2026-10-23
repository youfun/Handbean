defmodule Handbean.Tool.Builtin.GitTest do
  use ExUnit.Case, async: false

  alias Handbean.Tool.Builtin.Git

  setup do
    work = Path.join(System.tmp_dir!(), "sigil_git_#{System.unique_integer([:positive])}")
    File.mkdir_p!(work)
    git_config = Path.join(work, "git.json")
    previous = Application.get_env(:handbean, :git_user_config_path)
    Application.put_env(:handbean, :git_user_config_path, git_config)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:handbean, :git_user_config_path, previous),
        else: Application.delete_env(:handbean, :git_user_config_path)

      File.rm_rf(work)
    end)

    {:ok, work: work, ctx: %{working_directory: work}}
  end

  test "rejects missing workspace and unknown action", %{ctx: ctx} do
    assert {:error, "working_directory is required"} = Git.execute(%{"action" => "status"}, %{})
    assert {:error, message} = Git.execute(%{"action" => "rebase"}, ctx)
    assert message =~ "unsupported"
  end

  test "rejects commit without a message and checkout without a target", %{ctx: ctx} do
    assert {:ok, _, _} = Git.execute(%{"action" => "init"}, ctx)
    assert {:error, message} = Git.execute(%{"action" => "commit"}, ctx)
    assert message =~ "message"
    assert {:error, target} = Git.execute(%{"action" => "checkout"}, ctx)
    assert target =~ "target"
    assert {:error, name} = Git.execute(%{"action" => "create_branch"}, ctx)
    assert name =~ "name"
  end

  test "blocks paths outside the workspace", %{ctx: ctx} do
    outside = System.tmp_dir!()

    assert {:error, message} =
             Git.execute(%{"action" => "status", "path" => outside}, ctx)

    assert message =~ "outside" or message =~ "Path traversal"
  end

  test "init, edit, status, commit, log, and checkout stay inside the workspace", %{
    work: work,
    ctx: ctx
  } do
    assert {:ok, init_out, %{action: :init}} = Git.execute(%{"action" => "init"}, ctx)
    assert init_out =~ "initialized"
    assert File.dir?(Path.join(work, ".git"))

    File.mkdir_p!(Path.join(work, "lib"))
    File.write!(Path.join(work, "lib/demo.ex"), "defmodule Demo do\nend\n")

    assert {:ok, status_out, %{entries: entries}} = Git.execute(%{"action" => "status"}, ctx)
    assert status_out =~ "lib/demo.ex"
    assert Enum.any?(entries, &(&1.path == "lib/demo.ex"))

    assert {:ok, _, _} = Git.execute(%{"action" => "add", "paths" => ["lib/demo.ex"]}, ctx)

    assert {:error, message} = Git.execute(%{"action" => "commit"}, ctx)
    assert message =~ "message"

    assert {:ok, commit_out, %{oid: oid}} =
             Git.execute(%{"action" => "commit", "message" => "add demo"}, ctx)

    assert commit_out =~ oid
    assert {:ok, log_out, %{commits: [commit | _]}} = Git.execute(%{"action" => "log"}, ctx)
    assert log_out =~ "add demo"
    assert commit.summary == "add demo"

    assert {:ok, _, _} = Git.execute(%{"action" => "create_branch", "name" => "feature"}, ctx)
    assert {:ok, _, _} = Git.execute(%{"action" => "checkout", "target" => "feature"}, ctx)
    assert {:ok, branches_out, _} = Git.execute(%{"action" => "branches"}, ctx)
    assert branches_out =~ "feature"

    File.write!(Path.join(work, "lib/demo.ex"), "defmodule Demo do\n  def ok, do: :ok\nend\n")
    assert {:ok, patch, _} = Git.execute(%{"action" => "diff"}, ctx)
    assert patch =~ "def ok"

    assert {:ok, _, _} = Git.execute(%{"action" => "add", "paths" => ["lib/demo.ex"]}, ctx)

    assert {:ok, _, _} =
             Git.execute(%{"action" => "commit", "message" => "feature work"}, ctx)

    assert {:ok, _, _} = Git.execute(%{"action" => "checkout", "target" => "main"}, ctx)
    assert File.read!(Path.join(work, "lib/demo.ex")) == "defmodule Demo do\nend\n"
  end

  test "diff compares explicit revisions instead of the current worktree", %{
    work: work,
    ctx: ctx
  } do
    assert {:ok, _, _} = Git.execute(%{"action" => "init"}, ctx)
    path = Path.join(work, "version.txt")
    File.write!(path, "base\n")
    assert {:ok, _, _} = Git.execute(%{"action" => "add"}, ctx)

    assert {:ok, _, %{oid: base}} =
             Git.execute(%{"action" => "commit", "message" => "base"}, ctx)

    File.write!(path, "committed target\n")
    assert {:ok, _, _} = Git.execute(%{"action" => "add"}, ctx)

    assert {:ok, _, %{oid: target}} =
             Git.execute(%{"action" => "commit", "message" => "target"}, ctx)

    File.write!(path, "uncommitted worktree\n")

    assert {:ok, patch, %{action: :diff}} =
             Git.execute(%{"action" => "diff", "from" => base, "to" => target}, ctx)

    assert patch =~ "+committed target"
    refute patch =~ "uncommitted worktree"
  end

  test "diff rejects unsupported target instead of silently returning the HEAD diff", %{ctx: ctx} do
    assert {:error, message} =
             Git.execute(%{"action" => "diff", "target" => "main..feature"}, ctx)

    assert message =~ "from"
    assert message =~ "to"

    assert {:error, blank_range} =
             Git.execute(%{"action" => "diff", "from" => "", "to" => ""}, ctx)

    assert blank_range =~ "non-empty"
  end

  test "add and path reset use the discovered worktree, not the discovery directory", %{
    work: work,
    ctx: ctx
  } do
    assert {:ok, _, _} = Git.execute(%{"action" => "init"}, ctx)
    File.mkdir_p!(Path.join(work, "sub"))
    File.write!(Path.join(work, "file.txt"), "root\n")
    File.write!(Path.join(work, "sub/file.txt"), "nested\n")
    assert {:ok, _, _} = Git.execute(%{"action" => "add"}, ctx)
    assert {:ok, _, _} = Git.execute(%{"action" => "commit", "message" => "baseline"}, ctx)
    File.write!(Path.join(work, "file.txt"), "changed root\n")
    File.write!(Path.join(work, "sub/file.txt"), "changed nested\n")

    input = %{"path" => "sub", "paths" => ["sub/file.txt"]}
    assert {:ok, _, _} = Git.execute(Map.put(input, "action", "add"), ctx)
    assert {:ok, _, %{entries: entries}} = Git.execute(%{"action" => "status"}, ctx)
    assert Enum.find(entries, &(&1.path == "sub/file.txt")).staged == :modified
    assert Enum.find(entries, &(&1.path == "file.txt")).staged == nil

    assert {:ok, _, _} = Git.execute(Map.put(input, "action", "reset"), ctx)
    assert {:ok, _, %{entries: entries}} = Git.execute(%{"action" => "status"}, ctx)
    assert Enum.all?(entries, &is_nil(&1.staged))
  end

  test "rejects an intermediate symlink that points outside the workspace", %{
    work: work,
    ctx: ctx
  } do
    outside =
      Path.join(System.tmp_dir!(), "sigil_git_outside_#{System.unique_integer([:positive])}")

    File.mkdir_p!(outside)
    File.ln_s!(outside, Path.join(work, "escape"))
    on_exit(fn -> File.rm_rf(outside) end)

    assert {:error, message} =
             Git.execute(%{"action" => "init", "path" => "escape/repo"}, ctx)

    assert message =~ "outside" or message =~ "Path traversal"
    refute File.dir?(Path.join(outside, "repo/.git"))
  end

  test "clone rejects ssh urls and credentials embedded in the url", %{ctx: ctx} do
    assert {:error, ssh} =
             Git.execute(%{"action" => "clone", "url" => "ssh://git@example.com/repo.git"}, ctx)

    assert ssh =~ "http"

    assert {:error, creds} =
             Git.execute(
               %{"action" => "clone", "url" => "https://user:token@github.com/youfun/ex-git.git"},
               ctx
             )

    assert creds =~ "credentials"
  end

  test "remote_add rejects ssh urls and credentials embedded in the url", %{ctx: ctx} do
    assert {:ok, _, _} = Git.execute(%{"action" => "init"}, ctx)

    assert {:error, ssh} =
             Git.execute(
               %{"action" => "remote_add", "url" => "ssh://git@example.com/repo.git"},
               ctx
             )

    assert ssh =~ "http"

    assert {:error, creds} =
             Git.execute(
               %{
                 "action" => "remote_add",
                 "url" => "https://user:token@github.com/youfun/ex-git.git"
               },
               ctx
             )

    assert creds =~ "credentials"
  end

  test "remote_add requires a url", %{ctx: ctx} do
    assert {:ok, _, _} = Git.execute(%{"action" => "init"}, ctx)
    assert {:error, message} = Git.execute(%{"action" => "remote_add"}, ctx)
    assert message =~ "url"
  end

  test "init remotes is empty; remote_add and remote_set_url only write config", %{ctx: ctx} do
    url = "https://example.com/owner/repo.git"
    other = "https://example.com/owner/other.git"

    assert {:ok, _, _} = Git.execute(%{"action" => "init"}, ctx)
    assert {:ok, empty, %{remotes: []}} = Git.execute(%{"action" => "remotes"}, ctx)
    assert empty =~ "no remotes"

    assert {:ok, added, %{name: "origin", url: ^url}} =
             Git.execute(%{"action" => "remote_add", "url" => url}, ctx)

    assert added =~ "origin"
    assert added =~ url

    assert {:ok, listed, %{remotes: [remote]}} = Git.execute(%{"action" => "remotes"}, ctx)
    assert listed =~ "origin"
    assert listed =~ url
    assert remote.name == "origin"
    assert remote.url == url

    assert {:ok, updated, %{url: ^other}} =
             Git.execute(%{"action" => "remote_set_url", "url" => other}, ctx)

    assert updated =~ other
    assert {:ok, _, %{remotes: [changed]}} = Git.execute(%{"action" => "remotes"}, ctx)
    assert changed.url == other
  end

  test "duplicate remote_add returns an exists error", %{ctx: ctx} do
    url = "https://example.com/owner/repo.git"
    assert {:ok, _, _} = Git.execute(%{"action" => "init"}, ctx)
    assert {:ok, _, _} = Git.execute(%{"action" => "remote_add", "url" => url}, ctx)

    assert {:error, message} = Git.execute(%{"action" => "remote_add", "url" => url}, ctx)
    assert message =~ "exists"
  end

  test "auth_opts keeps a password without a username" do
    assert Handbean.Git.auth_opts(password: "ghp_test") == [password: "ghp_test"]

    assert Handbean.Git.auth_opts(username: "me", password: "ghp_test") == [
             username: "me",
             password: "ghp_test"
           ]

    assert Handbean.Git.auth_opts(username: "me") == [username: "me"]
    assert Handbean.Git.auth_opts(username: "", password: "ghp_test") == [password: "ghp_test"]
  end

  test "raw credentials and unknown credential references are rejected before execution", %{
    ctx: ctx
  } do
    assert {:error, message} =
             Git.execute(%{"action" => "push", "password" => "fixture-secret"}, ctx)

    assert message =~ "raw Git credentials are not accepted"
    refute message =~ "fixture-secret"

    assert {:error, "Git credential is not configured"} =
             Git.execute(%{"action" => "push", "credential" => "missing-review-credential"}, ctx)
  end

  test "host credential lookup preserves the authentication endpoint through the Git adapter" do
    previous = Application.fetch_env(:handbean, :git_credentials)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:handbean, :git_credentials, value)
        :error -> Application.delete_env(:handbean, :git_credentials)
      end
    end)

    Application.put_env(:handbean, :git_credentials, %{
      "review" => [endpoint: "https://example.com", password: "fixture-secret"],
      "insecure" => [endpoint: "http://example.com", password: "fixture-secret"],
      "path" => [endpoint: "https://example.com/repo.git", password: "fixture-secret"]
    })

    assert {:ok, opts} = Handbean.Git.Credentials.resolve("review")
    assert opts[:credential_endpoint] == "https://example.com"
    assert opts[:password] == "fixture-secret"
    assert Handbean.Git.auth_opts(opts) == opts
    assert {:error, _} = Handbean.Git.Credentials.resolve("insecure")
    assert {:error, _} = Handbean.Git.Credentials.resolve("path")
    assert {:ok, []} = Handbean.Git.Credentials.resolve(nil)
  end

  test "schema advertises remote actions and credential references, not raw credentials" do
    schema = Git.input_schema()
    assert Map.has_key?(schema.properties, :credential)
    assert Map.has_key?(schema.properties, :from)
    assert Map.has_key?(schema.properties, :to)
    refute Map.has_key?(schema.properties, :password)
    refute Map.has_key?(schema.properties, :username)
    enum = schema.properties.action.enum
    assert "remotes" in enum
    assert "remote_add" in enum
    assert "remote_set_url" in enum
    refute "ssh" in enum
    description = Git.description()
    assert description =~ "remote_add"
    assert description =~ "PAT"
    assert description =~ "fast-forward"
    assert description =~ "host injects a Git backend"
    assert description =~ "desktop agents use the machine's Git through bash"
    refute description =~ "GitHub App"
  end

  test "empty repository status and log", %{ctx: ctx} do
    assert {:ok, _, _} = Git.execute(%{"action" => "init"}, ctx)

    assert {:ok, status, %{branch: :unborn, entries: []}} =
             Git.execute(%{"action" => "status"}, ctx)

    assert status =~ "(unborn)"
    assert status =~ "clean"
    assert {:ok, log, %{commits: []}} = Git.execute(%{"action" => "log"}, ctx)
    assert log =~ "no commits"
  end

  test "status distinguishes staged and unstaged, including special names", %{
    work: work,
    ctx: ctx
  } do
    assert {:ok, _, _} = Git.execute(%{"action" => "init"}, ctx)
    File.write!(Path.join(work, "normal.txt"), "a\n")
    File.write!(Path.join(work, "has space.txt"), "b\n")
    File.write!(Path.join(work, "-dashed.txt"), "c\n")

    assert {:ok, _, %{entries: untracked}} = Git.execute(%{"action" => "status"}, ctx)
    assert Enum.any?(untracked, &(&1.path == "has space.txt" and &1.unstaged == :new))
    assert Enum.any?(untracked, &(&1.path == "-dashed.txt" and &1.unstaged == :new))

    assert {:ok, _, _} =
             Git.execute(%{"action" => "add", "paths" => ["has space.txt", "-dashed.txt"]}, ctx)

    File.write!(Path.join(work, "has space.txt"), "b2\n")

    assert {:ok, _, %{entries: entries}} = Git.execute(%{"action" => "status"}, ctx)
    spaced = Enum.find(entries, &(&1.path == "has space.txt"))
    dashed = Enum.find(entries, &(&1.path == "-dashed.txt"))
    assert spaced.staged == :new
    assert spaced.unstaged == :modified
    assert dashed.staged == :new
    assert dashed.unstaged == nil
  end

  test "pathspecs are not treated as Git options", %{work: work, ctx: ctx} do
    assert {:ok, _, _} = Git.execute(%{"action" => "init"}, ctx)
    File.write!(Path.join(work, "--output=evil"), "nope\n")

    assert {:ok, _, _} =
             Git.execute(%{"action" => "add", "paths" => ["--output=evil"]}, ctx)

    refute File.exists?(Path.join(work, "evil"))
    assert {:ok, _, %{entries: entries}} = Git.execute(%{"action" => "status"}, ctx)
    assert Enum.any?(entries, &(&1.path == "--output=evil" and &1.staged == :new))
  end

  test "pull fast-forwards only against a local fixture remote", %{work: work} do
    git = System.find_executable("git")
    seed = Path.join(work, "seed")
    bare = Path.join(work, "origin.git")
    clone_a = Path.join(work, "a")
    clone_b = Path.join(work, "b")
    File.mkdir_p!(seed)
    {_, 0} = System.cmd(git, ["init", "-b", "main", seed], stderr_to_stdout: true)
    File.write!(Path.join(seed, "readme.txt"), "one\n")
    fixture_commit(git, seed, "one")
    {_, 0} = System.cmd(git, ["clone", "--bare", "--", seed, bare], stderr_to_stdout: true)
    {_, 0} = System.cmd(git, ["clone", "--", bare, clone_a], stderr_to_stdout: true)
    {_, 0} = System.cmd(git, ["clone", "--", bare, clone_b], stderr_to_stdout: true)

    ctx_b = %{working_directory: clone_b}
    assert {:ok, _, %{result: :up_to_date}} = Git.execute(%{"action" => "pull"}, ctx_b)

    File.write!(Path.join(clone_a, "readme.txt"), "two\n")
    fixture_commit(git, clone_a, "two")
    {_, 0} = System.cmd(git, ["push", "origin", "main"], cd: clone_a, stderr_to_stdout: true)

    assert {:ok, _, %{action: :pull, result: :fast_forward}} =
             Git.execute(%{"action" => "pull"}, ctx_b)

    assert File.read!(Path.join(clone_b, "readme.txt")) == "two\n"
    assert {:ok, _, %{result: :up_to_date}} = Git.execute(%{"action" => "pull"}, ctx_b)

    File.write!(Path.join(clone_a, "readme.txt"), "three\n")
    fixture_commit(git, clone_a, "three")
    {_, 0} = System.cmd(git, ["push", "origin", "main"], cd: clone_a, stderr_to_stdout: true)
    File.write!(Path.join(clone_b, "other.txt"), "side\n")
    fixture_commit(git, clone_b, "side")

    assert {:error, message} = Git.execute(%{"action" => "pull"}, ctx_b)
    assert message =~ "fast-forward" or message =~ "Not possible" or message =~ "diverg"
    assert File.read!(Path.join(clone_b, "readme.txt")) == "two\n"
  end

  test "a successful push sets upstream so the next pull can fast-forward", %{
    work: work,
    ctx: ctx
  } do
    git = System.find_executable("git")
    bare = Path.join(work, "origin.git")
    {_, 0} = System.cmd(git, ["init", "--bare", "-b", "main", bare], stderr_to_stdout: true)

    assert {:ok, _, _} = Git.execute(%{"action" => "init"}, ctx)
    File.write!(Path.join(work, "n.txt"), "n\n")
    assert {:ok, _, _} = Git.execute(%{"action" => "add"}, ctx)
    assert {:ok, _, _} = Git.execute(%{"action" => "commit", "message" => "n"}, ctx)
    {_, 0} = System.cmd(git, ["remote", "add", "origin", bare], cd: work, stderr_to_stdout: true)

    assert {:ok, _, %{action: :push}} = Git.execute(%{"action" => "push"}, ctx)
    other = Path.join(work, "other")
    {_, 0} = System.cmd(git, ["clone", "--", bare, other], stderr_to_stdout: true)
    File.write!(Path.join(other, "n.txt"), "n2\n")
    fixture_commit(git, other, "n2")
    {_, 0} = System.cmd(git, ["push", "origin", "main"], cd: other, stderr_to_stdout: true)

    assert {:ok, _, %{result: :fast_forward}} = Git.execute(%{"action" => "pull"}, ctx)
    assert File.read!(Path.join(work, "n.txt")) == "n2\n"
  end

  test "status reports merge-conflict paths that contain spaces and newlines", %{
    work: work,
    ctx: ctx
  } do
    git = System.find_executable("git")
    spaced = Path.join(work, "has space.txt")
    nl = Path.join(work, "a\nb.txt")
    {_, 0} = System.cmd(git, ["init", "-b", "main", work], stderr_to_stdout: true)
    File.write!(spaced, "base\n")
    File.write!(nl, "base\n")
    fixture_commit(git, work, "base")
    {_, 0} = System.cmd(git, ["checkout", "-b", "other"], cd: work, stderr_to_stdout: true)
    File.write!(spaced, "other\n")
    File.write!(nl, "other\n")
    fixture_commit(git, work, "other")
    {_, 0} = System.cmd(git, ["checkout", "main"], cd: work, stderr_to_stdout: true)
    File.write!(spaced, "main\n")
    File.write!(nl, "main\n")
    fixture_commit(git, work, "main")

    {_out, 1} =
      System.cmd(
        git,
        ["-c", "user.name=Fixture", "-c", "user.email=fix@example.com", "merge", "other"],
        cd: work,
        stderr_to_stdout: true
      )

    assert {:ok, _, %{entries: entries}} = Git.execute(%{"action" => "status"}, ctx)
    spaced_entry = Enum.find(entries, &(&1.path == "has space.txt"))
    nl_entry = Enum.find(entries, &(&1.path == "a\nb.txt"))
    assert spaced_entry
    assert nl_entry
    assert spaced_entry.staged == :conflicted
    assert spaced_entry.unstaged == :conflicted
    assert nl_entry.staged == :conflicted
    refute Enum.any?(entries, &String.contains?(&1.path, "100644"))
  end

  test "default diff on an unborn HEAD includes the staged first commit", %{
    work: work,
    ctx: ctx
  } do
    assert {:ok, _, _} = Git.execute(%{"action" => "init"}, ctx)
    File.write!(Path.join(work, "first.txt"), "staged-body\n")
    assert {:ok, _, _} = Git.execute(%{"action" => "add", "paths" => ["first.txt"]}, ctx)

    assert {:ok, head_patch, _} = Git.execute(%{"action" => "diff"}, ctx)
    assert head_patch =~ "staged-body"
    assert {:ok, staged_patch, _} = Git.execute(%{"action" => "diff", "mode" => "staged"}, ctx)
    assert staged_patch =~ "staged-body"

    assert {:ok, worktree_patch, _} =
             Git.execute(%{"action" => "diff", "mode" => "worktree"}, ctx)

    assert worktree_patch == "(no diff)" or not String.contains?(worktree_patch, "staged-body")

    File.write!(Path.join(work, "first.txt"), "worktree-body\n")
    assert {:ok, combined, _} = Git.execute(%{"action" => "diff"}, ctx)
    assert combined =~ "worktree-body"
    refute combined =~ "staged-body"
  end

  test "pull honors an explicit remote when upstream tracks a different remote", %{work: work} do
    git = System.find_executable("git")
    seed = Path.join(work, "seed")
    origin_bare = Path.join(work, "origin.git")
    extra_bare = Path.join(work, "extra.git")
    origin_push = Path.join(work, "origin-push")
    extra_push = Path.join(work, "extra-push")
    clone = Path.join(work, "clone")
    File.mkdir_p!(seed)
    {_, 0} = System.cmd(git, ["init", "-b", "main", seed], stderr_to_stdout: true)
    File.write!(Path.join(seed, "base.txt"), "base\n")
    fixture_commit(git, seed, "base")
    {_, 0} = System.cmd(git, ["clone", "--bare", "--", seed, origin_bare], stderr_to_stdout: true)
    {_, 0} = System.cmd(git, ["clone", "--bare", "--", seed, extra_bare], stderr_to_stdout: true)
    {_, 0} = System.cmd(git, ["clone", "--", origin_bare, origin_push], stderr_to_stdout: true)
    {_, 0} = System.cmd(git, ["clone", "--", extra_bare, extra_push], stderr_to_stdout: true)
    {_, 0} = System.cmd(git, ["clone", "--", origin_bare, clone], stderr_to_stdout: true)

    File.write!(Path.join(origin_push, "from-origin.txt"), "origin-only\n")
    fixture_commit(git, origin_push, "origin")
    {_, 0} = System.cmd(git, ["push", "origin", "main"], cd: origin_push, stderr_to_stdout: true)

    File.write!(Path.join(extra_push, "from-extra.txt"), "extra-only\n")
    fixture_commit(git, extra_push, "extra")
    {_, 0} = System.cmd(git, ["push", "origin", "main"], cd: extra_push, stderr_to_stdout: true)

    {_, 0} =
      System.cmd(git, ["remote", "add", "extra", extra_bare], cd: clone, stderr_to_stdout: true)

    ctx = %{working_directory: clone}

    assert {:ok, _, %{result: :fast_forward}} =
             Git.execute(%{"action" => "pull", "remote" => "extra"}, ctx)

    assert File.read!(Path.join(clone, "from-extra.txt")) == "extra-only\n"
    refute File.exists?(Path.join(clone, "from-origin.txt"))
  end

  test "insteadOf HTTP rewrite and extra push URLs fail closed without sending secrets", %{
    work: work
  } do
    git = System.find_executable("git")
    repo = Path.join(work, "rewritten")
    File.mkdir_p!(repo)
    {_, 0} = System.cmd(git, ["init", "-b", "main", repo], stderr_to_stdout: true)

    {_, 0} =
      System.cmd(git, ["remote", "add", "origin", "https://example.com/owner/repo.git"],
        cd: repo,
        stderr_to_stdout: true
      )

    {_, 0} =
      System.cmd(
        git,
        ["config", "url.http://example.com/.insteadOf", "https://example.com/"],
        cd: repo,
        stderr_to_stdout: true
      )

    secret = "fixture-insteadOf-secret"

    assert {:error, http_message} =
             Handbean.Git.perform(:fetch, repo, ".",
               password: secret,
               credential_endpoint: "https://example.com"
             )

    assert http_message =~ "endpoint"
    refute http_message =~ secret

    {_, 0} =
      System.cmd(git, ["config", "--unset-all", "url.http://example.com/.insteadOf"],
        cd: repo,
        stderr_to_stdout: true
      )

    {_, 0} =
      System.cmd(
        git,
        ["config", "url.https://evil.example/.insteadOf", "https://example.com/"],
        cd: repo,
        stderr_to_stdout: true
      )

    assert {:error, host_message} =
             Handbean.Git.perform(:fetch, repo, ".",
               password: secret,
               credential_endpoint: "https://example.com"
             )

    assert host_message =~ "endpoint"

    {_, 0} =
      System.cmd(git, ["config", "--unset-all", "url.https://evil.example/.insteadOf"],
        cd: repo,
        stderr_to_stdout: true
      )

    {_, 0} =
      System.cmd(
        git,
        ["remote", "set-url", "--add", "--push", "origin", "https://example.com/owner/repo.git"],
        cd: repo,
        stderr_to_stdout: true
      )

    {_, 0} =
      System.cmd(
        git,
        ["remote", "set-url", "--add", "--push", "origin", "https://evil.example/owner/repo.git"],
        cd: repo,
        stderr_to_stdout: true
      )

    assert {:error, push_message} =
             Handbean.Git.perform(:push, repo, ".",
               password: secret,
               credential_endpoint: "https://example.com"
             )

    assert push_message =~ "endpoint"
    refute push_message =~ secret
  end

  test "ordinary diff does not run configured external diff or textconv", %{
    work: work,
    ctx: ctx
  } do
    git = System.find_executable("git")
    assert {:ok, _, _} = Git.execute(%{"action" => "init"}, ctx)
    File.write!(Path.join(work, "tracked.txt"), "one\n")
    assert {:ok, _, _} = Git.execute(%{"action" => "add"}, ctx)
    assert {:ok, _, _} = Git.execute(%{"action" => "commit", "message" => "one"}, ctx)
    File.write!(Path.join(work, "tracked.txt"), "two\n")

    marker = Path.join(work, "external-ran")
    script = Path.join(work, "external.sh")

    File.write!(
      script,
      """
      #!/bin/sh
      printf ran > "#{marker}"
      exit 0
      """
    )

    File.chmod!(script, 0o755)

    {_, 0} =
      System.cmd(git, ["config", "diff.external", script], cd: work, stderr_to_stdout: true)

    File.write!(Path.join(work, ".gitattributes"), "*.txt diff=secret\n")

    {_, 0} =
      System.cmd(git, ["config", "diff.secret.textconv", script],
        cd: work,
        stderr_to_stdout: true
      )

    assert {:ok, patch, _} = Git.execute(%{"action" => "diff"}, ctx)
    assert patch =~ "two"
    refute File.exists?(marker)
  end

  test "does not write Handbean identity or credentials into user Git config", %{
    work: work,
    ctx: ctx
  } do
    git = System.find_executable("git")
    {before, _} = System.cmd(git, ["config", "--global", "--list"], stderr_to_stdout: true)

    assert {:ok, _, _} = Git.execute(%{"action" => "init"}, ctx)
    File.write!(Path.join(work, "f.txt"), "f\n")
    assert {:ok, _, _} = Git.execute(%{"action" => "add"}, ctx)
    assert {:ok, _, _} = Git.execute(%{"action" => "commit", "message" => "f"}, ctx)

    {after_global, _} = System.cmd(git, ["config", "--global", "--list"], stderr_to_stdout: true)
    assert after_global == before

    {local, 0} =
      System.cmd(git, ["config", "--local", "--list"], cd: work, stderr_to_stdout: true)

    refute local =~ "agent@sigil.local"
    refute local =~ "Handbean Agent"
  end

  test "collect_code_baseline captures head_sha, branch, and bounded dirty files", %{
    work: work,
    ctx: ctx
  } do
    assert Handbean.Git.collect_code_baseline(nil) == nil
    assert Handbean.Git.collect_code_baseline(Path.join(work, "nonexistent")) == nil
    assert Handbean.Git.collect_code_baseline(work) == nil

    assert {:ok, _, _} = Git.execute(%{"action" => "init"}, ctx)

    unborn = Handbean.Git.collect_code_baseline(work)
    assert unborn["head_sha"] == nil
    assert unborn["branch"] == "(unborn)"
    assert unborn["dirty_files"] == []
    assert unborn["dirty_count"] == 0
    assert unborn["dirty_files_truncated"] == false
    assert is_binary(unborn["collected_at"])

    File.write!(Path.join(work, "a.txt"), "one\n")
    assert {:ok, _, _} = Git.execute(%{"action" => "add"}, ctx)
    assert {:ok, _, %{oid: oid}} = Git.execute(%{"action" => "commit", "message" => "init"}, ctx)

    clean = Handbean.Git.collect_code_baseline(work)
    assert clean["head_sha"] == oid
    assert clean["branch"] == "main"
    assert clean["dirty_files"] == []
    assert clean["dirty_count"] == 0
    assert clean["dirty_files_truncated"] == false

    nested_workspace = Path.join(work, "nested-workspace")
    File.mkdir_p!(nested_workspace)
    assert Handbean.Git.collect_code_baseline(nested_workspace) == nil

    for idx <- 1..55 do
      name = "file_#{String.pad_leading(Integer.to_string(idx), 2, "0")}.txt"
      File.write!(Path.join(work, name), "dirty #{idx}\n")
    end

    dirty = Handbean.Git.collect_code_baseline(work)
    assert dirty["head_sha"] == oid
    assert dirty["branch"] == "main"
    assert dirty["dirty_count"] == 55
    assert length(dirty["dirty_files"]) == 50
    assert dirty["dirty_files_truncated"] == true
  end

  defp fixture_commit(git, repo, message) do
    env = [{"GIT_TERMINAL_PROMPT", "0"}]

    {_, 0} =
      System.cmd(
        git,
        ["-c", "user.name=Fixture", "-c", "user.email=fix@example.com", "add", "-A"],
        cd: repo,
        env: env,
        stderr_to_stdout: true
      )

    {_, 0} =
      System.cmd(
        git,
        ["-c", "user.name=Fixture", "-c", "user.email=fix@example.com", "commit", "-m", message],
        cd: repo,
        env: env,
        stderr_to_stdout: true
      )
  end
end
