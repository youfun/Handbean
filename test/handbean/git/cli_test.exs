defmodule Handbean.Git.CLITest do
  use ExUnit.Case, async: false

  alias Handbean.Git
  alias Handbean.Git.CLI.Exec

  setup do
    work = Path.join(System.tmp_dir!(), "git-cli-#{System.unique_integer([:positive])}")
    File.mkdir_p!(work)
    git_config = Path.join(work, "git.json")
    previous_config = Application.get_env(:handbean, :git_user_config_path)
    previous_exec = Application.get_env(:handbean, :git_executor)
    Application.put_env(:handbean, :git_user_config_path, git_config)

    on_exit(fn ->
      if previous_config,
        do: Application.put_env(:handbean, :git_user_config_path, previous_config),
        else: Application.delete_env(:handbean, :git_user_config_path)

      if previous_exec,
        do: Application.put_env(:handbean, :git_executor, previous_exec),
        else: Application.delete_env(:handbean, :git_executor)

      File.rm_rf(work)
    end)

    {:ok, work: work, ctx: %{working_directory: work}}
  end

  test "credentials are passed in the environment, never argv or URL", %{work: work} do
    parent = self()
    secret = "fixture-secret-do-not-leak"
    dest = Path.join(work, "cloned")

    Application.put_env(:handbean, :git_executor, fn executable, opts ->
      send(parent, {:git_exec, executable, opts[:args], opts[:env], opts[:secrets]})

      cond do
        opts[:args] == ["--version"] ->
          {:ok, "git version 2.45.0", %{exit_code: 0, timed_out: false}}

        "ls-remote" in opts[:args] ->
          {:ok, List.last(opts[:args]) <> "\n", %{exit_code: 0, timed_out: false}}

        "rev-parse" in opts[:args] ->
          {:ok, dest <> "\n", %{exit_code: 0, timed_out: false}}

        true ->
          {:ok, "", %{exit_code: 0, timed_out: false}}
      end
    end)

    assert {:ok, _, %{action: :clone}} =
             Git.perform(:clone, work, dest,
               url: "https://example.com/owner/repo.git",
               password: secret,
               username: "me",
               credential_endpoint: "https://example.com"
             )

    {_exe, args, env, secrets} = await_git_exec(fn args -> "clone" in args end)

    refute inspect(args) =~ secret
    refute Enum.any?(List.wrap(args), &(is_binary(&1) and String.contains?(&1, secret)))
    refute Enum.any?(List.wrap(args), &String.contains?(&1, "https://me@"))
    assert {"HANDBEAN_GIT_PASSWORD", ^secret} = List.keyfind(env, "HANDBEAN_GIT_PASSWORD", 0)
    assert {"HANDBEAN_GIT_USERNAME", "me"} = List.keyfind(env, "HANDBEAN_GIT_USERNAME", 0)
    assert {"GIT_ASKPASS", askpass} = List.keyfind(env, "GIT_ASKPASS", 0)
    assert askpass =~ "git-askpass"

    assert {"HANDBEAN_GIT_CREDENTIAL_HOST", "example.com"} =
             List.keyfind(env, "HANDBEAN_GIT_CREDENTIAL_HOST", 0)

    refute List.keyfind(env, "SSH_ASKPASS", 0)
    assert secret in secrets
    assert {"GIT_TERMINAL_PROMPT", "0"} = List.keyfind(env, "GIT_TERMINAL_PROMPT", 0)
    refute Enum.any?(List.wrap(args), &String.contains?(&1, "safe.directory"))
  end

  test "executor timeout and nonzero exit become errors without leaking secrets", %{work: work} do
    secret = "fixture-timeout-secret"

    Application.put_env(:handbean, :git_executor, fn _exe, opts ->
      cond do
        opts[:args] == ["--version"] ->
          {:ok, "git version 2.45.0", %{exit_code: 0, timed_out: false}}

        "ls-remote" in opts[:args] ->
          {:ok, List.last(opts[:args]) <> "\n", %{exit_code: 0, timed_out: false}}

        true ->
          {:ok, "fatal: authentication failed for #{secret}", %{timed_out: true}}
      end
    end)

    assert {:error, message} =
             Git.perform(:clone, work, "cloned",
               url: "https://example.com/owner/repo.git",
               password: secret,
               credential_endpoint: "https://example.com"
             )

    assert message =~ "timed out"
    refute message =~ secret
  end

  test "nonzero git output is returned after redaction", %{work: work} do
    secret = "fixture-exit-secret"

    Application.put_env(:handbean, :git_executor, fn _exe, opts ->
      cond do
        opts[:args] == ["--version"] ->
          {:ok, "git version 2.45.0", %{exit_code: 0, timed_out: false}}

        "ls-remote" in opts[:args] ->
          {:ok, List.last(opts[:args]) <> "\n", %{exit_code: 0, timed_out: false}}

        true ->
          {:ok, "fatal: could not read Password for #{secret}",
           %{exit_code: 128, timed_out: false}}
      end
    end)

    assert {:error, message} =
             Git.perform(:clone, work, "cloned",
               url: "https://example.com/owner/repo.git",
               password: secret,
               credential_endpoint: "https://example.com"
             )

    refute message =~ secret
    assert message =~ "[REDACTED]" or message =~ "could not read"
  end

  test "Exec kills a hung argv process", %{work: work} do
    script = Path.join(work, "hang")
    File.write!(script, "#!/bin/sh\nexec sleep 30\n")
    File.chmod!(script, 0o755)
    started = System.monotonic_time(:millisecond)
    assert {:ok, _output, %{timed_out: true}} = Exec.run(script, [], timeout: 400, cwd: work)
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed < 5_000
  end

  test "credential endpoint mismatch does not invoke Git with the secret", %{work: work} do
    parent = self()
    secret = "fixture-secret"

    Application.put_env(:handbean, :git_executor, fn _exe, opts ->
      send(parent, {:git_exec, opts[:args], opts[:env]})

      cond do
        opts[:args] == ["--version"] ->
          {:ok, "git version 2.45.0", %{exit_code: 0, timed_out: false}}

        "ls-remote" in opts[:args] ->
          {:ok, List.last(opts[:args]) <> "\n", %{exit_code: 0, timed_out: false}}

        true ->
          {:ok, "", %{exit_code: 0, timed_out: false}}
      end
    end)

    assert {:error, message} =
             Git.perform(:clone, work, "cloned",
               url: "https://evil.example/repo.git",
               password: secret,
               credential_endpoint: "https://github.com"
             )

    assert message =~ "endpoint"
    refute_clone_with_secret(secret)
  end

  test "HTTP remotes are not given an HTTPS credential", %{work: work} do
    parent = self()
    secret = "fixture-http-secret"

    Application.put_env(:handbean, :git_executor, fn _exe, opts ->
      send(parent, {:git_exec, opts[:args], opts[:env]})

      cond do
        opts[:args] == ["--version"] ->
          {:ok, "git version 2.45.0", %{exit_code: 0, timed_out: false}}

        "ls-remote" in opts[:args] ->
          {:ok, "http://example.com/repo.git\n", %{exit_code: 0, timed_out: false}}

        true ->
          {:ok, "", %{exit_code: 0, timed_out: false}}
      end
    end)

    assert {:error, message} =
             Git.perform(:clone, work, "cloned",
               url: "http://example.com/repo.git",
               password: secret,
               credential_endpoint: "https://example.com"
             )

    assert message =~ "endpoint"
    refute_clone_with_secret(secret)
  end

  test "insteadOf rewrite to another host does not receive the secret", %{work: work} do
    parent = self()
    secret = "fixture-rewrite-secret"

    Application.put_env(:handbean, :git_executor, fn _exe, opts ->
      send(parent, {:git_exec, opts[:args], opts[:env]})

      cond do
        opts[:args] == ["--version"] ->
          {:ok, "git version 2.45.0", %{exit_code: 0, timed_out: false}}

        "ls-remote" in opts[:args] ->
          {:ok, "https://evil.example/owner/repo.git\n", %{exit_code: 0, timed_out: false}}

        true ->
          {:ok, "", %{exit_code: 0, timed_out: false}}
      end
    end)

    assert {:error, message} =
             Git.perform(:clone, work, "cloned",
               url: "https://example.com/owner/repo.git",
               password: secret,
               credential_endpoint: "https://example.com"
             )

    assert message =~ "endpoint"
    refute_clone_with_secret(secret)
  end

  test "push with a mismatched extra push URL does not receive the secret", %{work: work} do
    parent = self()
    secret = "fixture-pushurl-secret"
    git = System.find_executable("git")
    {_, 0} = System.cmd(git, ["init", "-b", "main", work], stderr_to_stdout: true)

    {_, 0} =
      System.cmd(git, ["remote", "add", "origin", "https://example.com/owner/repo.git"],
        cd: work,
        stderr_to_stdout: true
      )

    {_, 0} =
      System.cmd(
        git,
        ["remote", "set-url", "--add", "--push", "origin", "https://example.com/owner/repo.git"],
        cd: work,
        stderr_to_stdout: true
      )

    {_, 0} =
      System.cmd(
        git,
        ["remote", "set-url", "--add", "--push", "origin", "https://evil.example/owner/repo.git"],
        cd: work,
        stderr_to_stdout: true
      )

    Application.put_env(:handbean, :git_executor, fn _exe, opts ->
      send(parent, {:git_exec, opts[:args], opts[:env]})

      cond do
        opts[:args] == ["--version"] ->
          {:ok, "git version 2.45.0", %{exit_code: 0, timed_out: false}}

        "get-url" in opts[:args] ->
          {:ok, "https://example.com/owner/repo.git\nhttps://evil.example/owner/repo.git\n",
           %{exit_code: 0, timed_out: false}}

        "rev-parse" in opts[:args] ->
          {:ok, work <> "\n", %{exit_code: 0, timed_out: false}}

        true ->
          {:ok, "", %{exit_code: 0, timed_out: false}}
      end
    end)

    assert {:error, message} =
             Git.perform(:push, work, ".",
               password: secret,
               credential_endpoint: "https://example.com"
             )

    assert message =~ "endpoint"
    refute_clone_with_secret(secret)
  end

  test "askpass returns secrets only for Username/Password prompts on the expected HTTPS host" do
    script = Application.app_dir(:handbean, "priv/git-askpass.sh")
    secret = "fixture-askpass-secret"

    env = [
      {"HANDBEAN_GIT_USERNAME", "me"},
      {"HANDBEAN_GIT_PASSWORD", secret},
      {"HANDBEAN_GIT_CREDENTIAL_HOST", "example.com"},
      {"LC_ALL", "C"}
    ]

    {user, 0} = System.cmd("sh", [script, "Username for 'https://example.com':"], env: env)
    assert String.trim(user) == "me"

    {pass, 0} =
      System.cmd("sh", [script, "Password for 'https://me@example.com':"], env: env)

    assert String.trim(pass) == secret

    {evil, evil_status} =
      System.cmd("sh", [script, "Password for 'https://evil.example':"],
        env: env,
        stderr_to_stdout: true
      )

    assert evil_status != 0
    refute evil =~ secret

    {http, http_status} =
      System.cmd("sh", [script, "Password for 'http://example.com':"],
        env: env,
        stderr_to_stdout: true
      )

    assert http_status != 0
    refute http =~ secret

    {phrase, phrase_status} =
      System.cmd("sh", [script, "Enter passphrase for key '/tmp/id_rsa':"],
        env: env,
        stderr_to_stdout: true
      )

    assert phrase_status != 0
    refute phrase =~ secret
  end

  test "credentialed clone does not chmod the packaged askpass helper", %{work: work} do
    askpass = Application.app_dir(:handbean, "priv/git-askpass.sh")
    before = File.stat!(askpass)

    Application.put_env(:handbean, :git_executor, fn _exe, opts ->
      cond do
        opts[:args] == ["--version"] ->
          {:ok, "git version 2.45.0", %{exit_code: 0, timed_out: false}}

        "ls-remote" in opts[:args] ->
          {:ok, List.last(opts[:args]) <> "\n", %{exit_code: 0, timed_out: false}}

        "rev-parse" in opts[:args] ->
          {:ok, Path.join(work, "cloned") <> "\n", %{exit_code: 0, timed_out: false}}

        true ->
          {:ok, "", %{exit_code: 0, timed_out: false}}
      end
    end)

    assert {:ok, _, %{action: :clone}} =
             Git.perform(:clone, work, "cloned",
               url: "https://example.com/owner/repo.git",
               password: "fixture-secret",
               credential_endpoint: "https://example.com"
             )

    after_stat = File.stat!(askpass)
    assert after_stat.mtime == before.mtime
    assert after_stat.mode == before.mode
    refute cli_source() =~ "File.chmod"
  end

  test "Exec unsets credential-trace and GIT_CONFIG_PARAMETERS from the child", %{work: work} do
    script = Path.join(work, "print-env")

    File.write!(
      script,
      """
      #!/bin/sh
      printf 'GIT_CONFIG_PARAMETERS=%s\\n' "${GIT_CONFIG_PARAMETERS-<unset>}"
      printf 'GIT_TRACE_CURL=%s\\n' "${GIT_TRACE_CURL-<unset>}"
      printf 'GIT_CURL_VERBOSE=%s\\n' "${GIT_CURL_VERBOSE-<unset>}"
      printf 'GIT_TRACE2_EVENT=%s\\n' "${GIT_TRACE2_EVENT-<unset>}"
      printf 'GIT_TRACE2=%s\\n' "${GIT_TRACE2-<unset>}"
      """
    )

    File.chmod!(script, 0o755)

    keys = [
      "GIT_CONFIG_PARAMETERS",
      "GIT_TRACE_CURL",
      "GIT_CURL_VERBOSE",
      "GIT_TRACE2_EVENT",
      "GIT_TRACE2"
    ]

    previous = Map.new(keys, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)
    end)

    Enum.each(keys, &System.put_env(&1, "leak"))

    assert {:ok, output, %{exit_code: 0}} = Exec.run(script, [], timeout: 2_000, cwd: work)
    assert output =~ "GIT_CONFIG_PARAMETERS=<unset>"
    assert output =~ "GIT_TRACE_CURL=<unset>"
    assert output =~ "GIT_CURL_VERBOSE=<unset>"
    assert output =~ "GIT_TRACE2_EVENT=<unset>"
    assert output =~ "GIT_TRACE2=<unset>"
  end

  defp await_git_exec(pred) do
    receive do
      {:git_exec, exe, args, env, secrets} ->
        if pred.(args) do
          {exe, args, env, secrets}
        else
          await_git_exec(pred)
        end
    after
      1_000 ->
        flunk("did not observe a Git invocation matching the predicate")
    end
  end

  defp refute_clone_with_secret(secret) do
    refute_secret_invocations(secret, 8)
  end

  defp refute_secret_invocations(_secret, 0), do: :ok

  defp refute_secret_invocations(secret, remaining) do
    receive do
      {:git_exec, args, env} ->
        refute "clone" in args
        refute "push" in args
        refute "fetch" in args
        refute "pull" in args
        env = List.wrap(env)
        refute List.keyfind(env, "HANDBEAN_GIT_PASSWORD", 0)
        refute inspect(env) =~ secret
        refute_secret_invocations(secret, remaining - 1)

      {:git_exec, _exe, args, env, _secrets} ->
        refute "clone" in args
        env = List.wrap(env)
        refute inspect(env) =~ secret
        refute_secret_invocations(secret, remaining - 1)
    after
      50 ->
        :ok
    end
  end

  defp cli_source do
    Path.join([File.cwd!(), "lib/handbean/git/cli.ex"]) |> File.read!()
  end
end
