defmodule Handbean.Workspace.MixProject do
  @moduledoc """
  Mix/Hex operations for a workspace Elixir project.

  Always goes through `Handbean.Workspace.MixOwner`. Ordinary supported
  projects use real Mix tasks and Hex resolution — this module does not
  hand-parse Hex packages.
  """

  alias Handbean.Tool.Builtin.ElixirScriptIO
  alias Handbean.Workspace.{MixCompat, MixOwner, MixShell, MixToolchain}

  @max_stdout_bytes 32_768
  @max_value_bytes 8_192
  @default_timeout_ms 60_000
  @max_timeout_ms 60_000
  @compile_args ["--no-protocol-consolidation", "--no-phandbean-code-paths", "--return-errors"]
  # Mix.Tasks.Test does not accept compile's protocol/prune switches.
  # Keep --no-compile so test cannot spawn an external elixir compiler.
  # Pass an explicit test file so Mix does not rely on File.dir?("test")
  # after Mix.Project.in_project has already changed cwd.
  @test_task_args ["--no-start", "--raise", "--no-compile"]

  @type action :: :deps_get | :compile | :test | :run

  @spec max_timeout_ms() :: pos_integer()
  def max_timeout_ms, do: @max_timeout_ms

  @spec default_timeout_ms() :: pos_integer()
  def default_timeout_ms, do: @default_timeout_ms

  @spec compile_args() :: [String.t()]
  def compile_args, do: @compile_args

  @spec test_args() :: [String.t()]
  def test_args, do: @test_task_args

  @spec perform(action(), Path.t(), keyword()) ::
          {:ok, String.t(), map()} | {:error, String.t(), map()}
  def perform(action, project_path, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    capture = ElixirScriptIO.start_link(@max_stdout_bytes, opts[:on_output])

    try do
      result =
        MixOwner.run(
          fn ->
            Process.group_leader(self(), capture)

            case MixToolchain.ensure_loaded() do
              {:ok, toolchain} -> run_action(action, project_path, opts, toolchain)
              {:error, reason} -> {:error, reason, %{}}
            end
          end,
          timeout_ms: timeout_ms,
          project_path: project_path
        )

      format_owner_result(result, ElixirScriptIO.snapshot(capture))
    after
      ElixirScriptIO.stop(capture)
    end
  end

  defp run_action(action, project_path, opts, toolchain) do
    with :ok <- require_mix_exs(project_path),
         :ok <- prepare_env(project_path, Keyword.put(opts, :action, action), toolchain),
         :ok <- start_mix(action),
         :ok <- refresh_hex_state(),
         host = MixOwner.host_snapshot(),
         :ok <- MixCompat.check_project_sources(project_path, host) do
      app = project_app(project_path)
      inets_before = inets_running?()

      Mix.Project.in_project(app, project_path, project_post_config(project_path), fn _module ->
        config = Mix.Project.config()

        with :ok <- MixCompat.check_project(config, host),
             :ok <- maybe_stamp(project_path, toolchain) do
          action
          |> dispatch(opts, host)
          |> put_detail(:project, project_path)
          |> put_detail(:app, config[:app])
          |> put_detail(:toolchain, toolchain.source)
          |> put_detail(:inets_changed, inets_running?() != inets_before)
        end
      end)
    end
  end

  defp dispatch(:deps_get, _opts, host) do
    Mix.Task.reenable("deps.get")
    Mix.Task.reenable("deps.loadpaths")
    value = Mix.Task.run("deps.get", ["--no-archives-check"])
    deps = load_deps()
    packages = dep_names(deps)

    case MixCompat.check(deps, host) do
      :ok ->
        with :ok <- reuse_host_dependencies(deps, host) do
          ok(%{
            deps: inspect_result(value),
            lock?: File.exists?("mix.lock"),
            packages: packages
          })
        end

      {:error, reason} ->
        err(reason, %{packages: packages})
    end
  end

  defp dispatch(:compile, _opts, host) do
    with :ok <- ensure_lock(),
         :ok <- prepare_deps(host) do
      reenable_compile()
      Mix.Task.reenable("deps.loadpaths")
      Mix.Task.run("deps.loadpaths")

      case Mix.Task.run("compile", compile_args()) do
        {:error, diagnostics} ->
          err("project compilation failed", %{diagnostics: inspect_result(diagnostics)})

        value ->
          ok(%{compile: inspect_result(value)})
      end
    end
  end

  defp dispatch(:test, opts, host) do
    with {:ok, compile} <- dispatch(:compile, opts, host),
         {:ok, test_files} <- test_files(),
         :ok <- prepare_ex_unit() do
      unrequire_test_files(test_files)
      Mix.Task.reenable("test")
      args = test_args() ++ test_files

      case Mix.Task.run("test", args) do
        :ok ->
          ok(Map.merge(compile, %{test: :ok, test_files: test_files}))

        value ->
          ok(Map.merge(compile, %{test: inspect_result(value), test_files: test_files}))
      end
    end
  end

  defp dispatch(:run, opts, host) do
    with {:ok, compile} <- dispatch(:compile, opts, host),
         :ok <- load_code_paths(),
         {:ok, module} <- fetch_module(opts[:module]),
         :ok <- MixCompat.check_run_module(module, File.cwd!(), host),
         {:ok, function} <- fetch_function(opts[:function]),
         {:ok, args} <- fetch_args(opts[:args]) do
      {:module, ^module} = Code.ensure_loaded(module)
      value = apply(module, function, args)

      ok(
        Map.merge(compile, %{
          return: inspect_result(value),
          module: inspect(module),
          function: function
        })
      )
    end
  end

  defp start_mix(action) do
    Mix.start()
    Mix.env(mix_env(action))
    keep_mix_shell_loaded!()
    Mix.shell(MixShell)
    Mix.Task.clear()

    if function_exported?(Mix, :ensure_application!, 1) do
      Mix.ensure_application!(:hex)
      unconsolidate_hex_protocols()
    end

    :ok
  rescue
    exception ->
      err("cannot start Mix/Hex: #{Exception.message(exception)}")
  end

  # Desktop Mix consolidates String.Chars before Hex is started. Hex lock
  # writing needs Hex.Solver.Constraints.* implementations; drop the stale
  # consolidated modules for this Mix job. MixOwner restores them after.
  defp unconsolidate_hex_protocols do
    Enum.each([String.Chars, Inspect], fn protocol ->
      if function_exported?(Protocol, :consolidated?, 1) and Protocol.consolidated?(protocol) do
        :code.purge(protocol)
        :code.delete(protocol)
      end
    end)
  end

  defp mix_env(:test), do: :test
  defp mix_env(_), do: :dev

  defp keep_mix_shell_loaded! do
    case Code.ensure_loaded(MixShell) do
      {:module, MixShell} ->
        _ = :code.stick_mod(MixShell)
        :ok

      _ ->
        raise "Handbean.Workspace.MixShell is not available"
    end
  end

  defp mix_env_name(:test), do: "test"
  defp mix_env_name(_), do: "dev"

  defp prepare_env(project_path, opts, toolchain) do
    home = Path.join(project_path, ".handbean")
    File.mkdir_p!(home)

    if toolchain.source == :packaged do
      mix_home = Path.join(home, "mix_home")
      hex_home = Path.join(home, "hex_home")
      File.mkdir_p!(mix_home)
      File.mkdir_p!(hex_home)
      System.put_env("MIX_HOME", mix_home)
      System.put_env("HEX_HOME", hex_home)
    end

    System.delete_env("MIX_BUILD_PATH")
    System.delete_env("MIX_DEPS_PATH")
    System.put_env("MIX_ENV", mix_env_name(opts[:action] || :dev))
    System.put_env("MIX_OS_DEPS_COMPILE_PARTITION_COUNT", "1")
    System.put_env("MIX_OS_CONCURRENCY_LOCK", "0")
    System.put_env("MIX_QUIET", "1")

    if Keyword.get(opts, :offline, false) do
      System.put_env("HEX_OFFLINE", "1")
    else
      System.delete_env("HEX_OFFLINE")
    end

    :ok
  end

  defp require_mix_exs(project_path) do
    mix_exs = Path.join(project_path, "mix.exs")

    cond do
      not File.dir?(project_path) ->
        err("project directory not found: #{project_path}")

      not File.regular?(mix_exs) ->
        err("mix.exs not found in #{project_path}")

      true ->
        :ok
    end
  end

  defp project_post_config(project_path) do
    [
      build_path: Path.join(project_path, "_build"),
      deps_path: Path.join(project_path, "deps"),
      lockfile: Path.join(project_path, "mix.lock")
    ]
  end

  defp project_app(project_path) do
    mix_exs = Path.join(project_path, "mix.exs")

    case File.read(mix_exs) do
      {:ok, source} ->
        case Regex.run(~r/app:\s*:([a-zA-Z0-9_]+)/, source) do
          [_, name] -> String.to_atom(name)
          _ -> :workspace_mix_project
        end

      _ ->
        :workspace_mix_project
    end
  end

  defp load_deps do
    Mix.Dep.Converger.converge(env: Mix.env(), target: Mix.target())
  end

  defp prepare_deps(host) do
    deps = load_deps()

    case MixCompat.check(deps, host) do
      :ok -> reuse_host_dependencies(deps, host)
      {:error, reason} -> err(reason)
    end
  end

  defp reuse_host_dependencies(deps, host) do
    with {:ok, host_deps} <- MixCompat.host_dependencies(deps, host) do
      Enum.each(host_deps, fn {dep, source} ->
        build_path = dep.opts[:build]

        if is_binary(build_path) do
          File.rm_rf!(build_path)
          reuse_host_application!(dep.app, build_path, source)
          Mix.Dep.ElixirSCM.update(Path.join(build_path, ".mix"), dep.scm, dep.opts[:lock])
        end
      end)

      if host_deps != [], do: Mix.Dep.clear_cached()
      :ok
    end
  rescue
    exception -> err("cannot reuse host dependency: #{Exception.message(exception)}")
  end

  defp reuse_host_application!(_app, build_path, host_path) when is_binary(host_path) do
    File.mkdir_p!(Path.dirname(build_path))
    File.ln_s!(host_path, build_path)
  end

  defp reuse_host_application!(app, build_path, {:beams, beams, spec}) do
    ebin = Path.join(build_path, "ebin")
    File.mkdir_p!(ebin)

    Enum.each(beams, fn {_module, source} ->
      File.ln_s!(source, Path.join(ebin, Path.basename(source)))
    end)

    app_file = Path.join(ebin, "#{app}.app")
    File.write!(app_file, :io_lib.format(~c"~tp.~n", [{:application, app, spec}]))
  end

  defp dep_names(deps) do
    names =
      Enum.flat_map(deps, fn
        %Mix.Dep{app: app} -> [app]
        _ -> []
      end)

    if names == [], do: lock_apps(), else: names
  end

  defp lock_apps do
    if function_exported?(Mix.Dep.Lock, :read, 0) do
      Mix.Dep.Lock.read() |> Map.keys()
    else
      []
    end
  end

  defp ensure_lock do
    if File.exists?("mix.lock") or load_deps() == [] do
      :ok
    else
      err("mix.lock is missing; run mix_project action deps.get first")
    end
  end

  defp reenable_compile do
    Enum.each(
      ["compile", "compile.all", "compile.elixir", "deps.loadpaths", "deps.compile", "loadpaths"],
      &Mix.Task.reenable/1
    )
  end

  # Mix.Tasks.Test / ExUnit.Server refuse new cases once a suite has
  # already started (`loaded: :done`). On the packaged mobile toolchain the
  # host does not run ExUnit; reset the server so a previous Mix test or
  # probe cannot leave it in :done. Never restart the desktop host's
  # running ExUnit suite.
  defp prepare_ex_unit do
    Application.ensure_all_started(:ex_unit)
    Application.put_env(:ex_unit, :autorun, false)

    if reset_ex_unit_server?() do
      _ = Supervisor.terminate_child(ExUnit.Supervisor, ExUnit.Server)
      _ = Supervisor.restart_child(ExUnit.Supervisor, ExUnit.Server)
    end

    :ok
  rescue
    exception ->
      err("cannot prepare ExUnit: #{Exception.message(exception)}")
  end

  defp reset_ex_unit_server? do
    Process.whereis(ExUnit.Supervisor) != nil and
      Process.whereis(ExUnit.Server) != nil and
      match?({:ok, %{source: :packaged}}, MixToolchain.info())
  end

  defp test_files do
    files =
      Path.wildcard("test/**/*_test.exs")
      |> Enum.filter(&File.regular?/1)

    cond do
      files != [] ->
        {:ok, files}

      File.dir?("test") ->
        err("no *_test.exs files found under test/")

      true ->
        err("test/ directory not found; cannot run mix test")
    end
  end

  defp unrequire_test_files(test_files) do
    helpers = Path.wildcard("test/**/test_helper.exs")
    Code.unrequire_files(Enum.map(test_files ++ helpers, &Path.expand/1))
  end

  defp load_code_paths do
    compile_path = Mix.Project.compile_path()
    Code.prepend_path(compile_path)

    build = Mix.Project.build_path()
    ebins = Path.wildcard(Path.join(build, "lib/*/ebin"))
    Enum.each(ebins, &Code.prepend_path/1)

    if ebins == [] and File.dir?(build) == false do
      err("compiled artifacts missing at #{build}")
    else
      :ok
    end
  end

  defp maybe_stamp(project_path, toolchain) do
    stamp = %{
      "elixir" => toolchain.elixir,
      "otp" => toolchain.otp,
      "hex" => toolchain.hex_version
    }

    path = Path.join([project_path, ".handbean", "mix_toolchain.json"])
    File.mkdir_p!(Path.dirname(path))

    case File.read(path) do
      {:ok, bytes} ->
        case Handbean.JSON.decode(bytes) do
          {:ok, ^stamp} ->
            :ok

          {:ok, _previous} ->
            File.write!(path, Handbean.JSON.encode!(stamp))
            :ok

          _ ->
            File.write!(path, Handbean.JSON.encode!(stamp))
            :ok
        end

      {:error, :enoent} ->
        File.write!(path, Handbean.JSON.encode!(stamp))
        :ok

      {:error, reason} ->
        err("cannot record Mix toolchain stamp: #{inspect(reason)}")
    end
  end

  defp fetch_module(module) when is_atom(module) and not is_nil(module), do: {:ok, module}

  defp fetch_module(module) when is_binary(module) do
    if Regex.match?(~r/^[A-Z][A-Za-z0-9_.]*$/, module) do
      {:ok, Module.concat([module])}
    else
      err("run module must be an existing Elixir module name")
    end
  end

  defp fetch_module(_), do: err("run requires module")

  defp fetch_function(function) when is_atom(function), do: {:ok, function}

  defp fetch_function(function) when is_binary(function) do
    {:ok, String.to_existing_atom(function)}
  rescue
    ArgumentError -> err("run function is not loaded: #{function}")
  end

  defp fetch_function(_), do: err("run requires function")

  defp fetch_args(nil), do: {:ok, []}
  defp fetch_args(args) when is_list(args), do: {:ok, args}
  defp fetch_args(_), do: err("run args must be a list")

  defp format_owner_result({:ok, {:ok, details}}, stdout) when is_map(details) do
    case reject_empty_test_run(details, stdout.text) do
      {:ok, details} ->
        {text, truncated?} = bound_inspect(details)

        {:ok, format_output(stdout.text, text, stdout.truncated?, truncated?),
         details
         |> Map.put(:stdout, stdout.text)
         |> Map.put(:stdout_truncated?, stdout.truncated?)}

      {:error, reason, details} ->
        format_owner_result({:ok, {:error, reason, details}}, stdout)
    end
  end

  defp format_owner_result({:ok, {:error, reason, details}}, stdout) when is_map(details) do
    {:error, to_string(reason),
     details
     |> Map.put(:stdout, stdout.text)
     |> Map.put(:stdout_truncated?, stdout.truncated?)}
  end

  defp format_owner_result({:ok, {:error, reason}}, stdout) do
    {:error, to_string(reason), %{stdout: stdout.text, stdout_truncated?: stdout.truncated?}}
  end

  defp format_owner_result({:ok, other}, stdout) do
    {text, truncated?} = bound_inspect(other)

    {:ok, format_output(stdout.text, text, stdout.truncated?, truncated?),
     %{stdout: stdout.text, stdout_truncated?: stdout.truncated?, return: text}}
  end

  defp format_owner_result({:error, reason, details}, stdout) do
    {:error, reason,
     Map.merge(%{stdout: stdout.text, stdout_truncated?: stdout.truncated?}, details)}
  end

  defp format_output(stdout, inspected, stdout_truncated?, value_truncated?) do
    notes =
      Enum.reject(
        [stdout_truncated? && "stdout truncated", value_truncated? && "result truncated"],
        &(!&1)
      )

    body = Enum.join(["stdout:", stdout, "", "result:", inspected], "\n")
    if notes == [], do: body, else: body <> "\n\n(" <> Enum.join(notes, "; ") <> ")"
  end

  defp bound_inspect(value) do
    value
    |> inspect(limit: 50, printable_limit: 2_048)
    |> ElixirScriptIO.take_utf8(@max_value_bytes)
  end

  defp inspect_result(value), do: inspect(value, limit: 20, printable_limit: 512)

  defp ok(details), do: {:ok, details}
  defp err(reason, details \\ %{}), do: {:error, reason, details}

  defp reject_empty_test_run(%{test: _} = details, stdout) when is_binary(stdout) do
    if stdout =~ "Result: 0 tests" or stdout =~ "There are no tests to run" do
      {:error, "mix test ran 0 tests; expected *_test.exs under test/", details}
    else
      {:ok, details}
    end
  end

  defp reject_empty_test_run(details, _stdout), do: {:ok, details}

  defp put_detail({:ok, details}, key, value), do: {:ok, Map.put(details, key, value)}

  defp put_detail({:error, reason, details}, key, value),
    do: {:error, reason, Map.put(details, key, value)}

  defp put_detail({:error, reason}, key, value), do: {:error, reason, %{key => value}}
  defp put_detail(other, _key, _value), do: other

  defp inets_running? do
    Enum.any?(Application.started_applications(), fn {app, _, _} -> app == :inets end)
  end

  defp refresh_hex_state do
    if Process.whereis(Hex.State) && function_exported?(Hex.State, :refresh, 0) do
      Hex.State.refresh()
    else
      :ok
    end
  end
end
