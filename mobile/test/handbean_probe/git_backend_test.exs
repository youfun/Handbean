defmodule HandbeanProbe.GitBackendTest do
  use ExUnit.Case, async: false

  alias Handbean.Tool.Builtin.Git

  setup do
    previous = Application.get_env(:handbean, :host)
    work = Path.join(System.tmp_dir!(), "probe-git-#{System.unique_integer([:positive])}")
    File.mkdir_p!(work)
    git_config = Path.join(work, "git.json")
    previous_config = Application.get_env(:handbean, :git_user_config_path)
    Application.put_env(:handbean, :git_user_config_path, git_config)

    Handbean.Host.put!(%{
      shell: false,
      terminal: false,
      browser_backend: :webview,
      artifact_delivery_backend: Handbean.ArtifactDelivery,
      host_script: true,
      git_backend: Handbean.Git.ExGit
    })

    on_exit(fn ->
      if previous,
        do: Application.put_env(:handbean, :host, previous),
        else: Application.delete_env(:handbean, :host)

      if previous_config,
        do: Application.put_env(:handbean, :git_user_config_path, previous_config),
        else: Application.delete_env(:handbean, :git_user_config_path)

      File.rm_rf(work)
    end)

    {:ok, work: work, ctx: %{working_directory: work}}
  end

  test "phone host injects ExGit instead of the Git CLI" do
    assert Handbean.Git.backend() == Handbean.Git.ExGit
    assert Handbean.Git.backend_kind() == :ex_git_libgit2
    assert Handbean.Tool.Builtin.Git in Handbean.Tool.Registry.host_tool_modules()
    assert Code.ensure_loaded?(ExGit)
    beam = :code.which(Handbean.Git.ExGit) |> to_string()
    assert beam =~ "handbean_probe"
    refute beam =~ "/handbean/ebin/"
  end

  test "ExGit backend preserves init/status/commit/log contracts", %{work: work, ctx: ctx} do
    case Handbean.Git.ExGit.available() do
      :ok ->
        :ok

      {:error, reason} ->
        flunk("mobile Git tests need the host ExGit NIF, not libex_git_nif.so: #{reason}")
    end

    assert {:ok, init_out, %{action: :init}} = Git.execute(%{"action" => "init"}, ctx)
    assert init_out =~ "initialized"
    File.write!(Path.join(work, "demo.txt"), "ok\n")
    assert {:ok, _, _} = Git.execute(%{"action" => "add", "paths" => ["demo.txt"]}, ctx)

    assert {:ok, _, %{oid: oid}} =
             Git.execute(%{"action" => "commit", "message" => "add demo"}, ctx)

    assert {:ok, log_out, %{commits: [commit | _]}} = Git.execute(%{"action" => "log"}, ctx)
    assert log_out =~ "add demo"
    assert commit.summary == "add demo"
    assert oid == commit.oid
  end
end
