# Run after installing and cold-starting the APK, with 9200/4369 adb tunnels:
# mix run --no-start script/android_git_smoke.exs
# No LLM, credentials or writes to external repositories. Uses a disposable workspace.
{:ok, _} = Node.start(:"android_git_smoke_#{System.unique_integer([:positive])}@127.0.0.1")
Node.set_cookie(MobDev.DistCookie.for_project!())
device = :"handbean_probe_android_nativechat@127.0.0.1"
:pong = Node.ping(device)
HandbeanProbe.HomeScreen = Mob.Test.screen(device)

{result, _bindings} =
  :rpc.call(
    device,
    Code,
    :eval_string,
    [
      ~S"""
      true = ExGit.nif_loaded?()
      root = Path.join(Handbean.Host.data_dir(), "git-smoke-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)

      try do
        context = %{working_directory: root}
        run = fn input ->
          {:ok, text, details} = Handbean.Tool.Builtin.Git.execute(input, context)
          {text, details}
        end

        run.(%{"action" => "init"})
        File.mkdir_p!(Path.join(root, "nested"))
        File.write!(Path.join(root, "nested/example.txt"), "android-git-smoke\n")
        run.(%{"action" => "add", "path" => "nested", "paths" => ["nested/example.txt"]})
        run.(%{"action" => "commit", "message" => "Android NIF smoke"})
        {:ok, repo} = ExGit.open(root)
        {:ok, [%{summary: "Android NIF smoke"}]} = ExGit.log(repo)
        {:ok, ""} = ExGit.diff(repo)
        File.write!(Path.join(root, "nested/example.txt"), "android-git-changed\n")
        {patch, _} = run.(%{"action" => "diff"})
        true = String.contains?(patch, "+android-git-changed")
        run.(%{"action" => "reset", "type" => "hard", "target" => "HEAD"})
        "android-git-smoke\n" = File.read!(Path.join(root, "nested/example.txt"))

        clone = Path.join(root, "public-clone")
        run.(%{"action" => "clone", "url" => "https://github.com/octocat/Hello-World.git", "path" => clone})
        true = File.read!(Path.join(clone, "README")) =~ "Hello World"
        run.(%{"action" => "fetch", "path" => clone})
        run.(%{"action" => "pull", "path" => clone})

        {:error, {_, tls_error}} =
          ExGit.clone("https://self-signed.badssl.com/repo.git", Path.join(root, "untrusted"))
        true = String.contains?(String.downcase(tls_error), "certificate")

        %{
          nif_loaded: true,
          version: Application.spec(:ex_git, :vsn),
          passed: [:init, :subdirectory_add, :commit, :log, :diff, :reset,
                   :https_clone, :fetch, :pull, :reject_untrusted_certificate]
        }
      after
        File.rm_rf!(root)
      end
      """
    ],
    120_000
  )

dbg(result)
