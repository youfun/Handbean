defmodule Handbean.Browser.Cli do
  @moduledoc """
  Plans and runs `agent-browser` as a direct argv subprocess.

  The wrapper injects `--json`, an optional managed `--session`, and the
  Handbean-owned Chrome relay when that transport is enabled. Tests inject
  `:runner` and `:find_executable` so Chromium is never required for unit
  coverage.
  """

  alias Handbean.Browser.Policy
  alias Handbean.Platform.{CommandEnvironment, ProcessManager, WorkspaceEnvironment}

  @default_timeout_ms 35_000
  @version_timeout_ms 5_000
  @version_cache_ttl_ms 30_000
  @minimum_chrome_relay_version Version.parse!("0.39.1")
  @binary "agent-browser"

  @doc "Argv that will be passed after the executable."
  @spec planned_argv([String.t()], keyword()) :: [String.t()]
  def planned_argv(args, opts \\ []) when is_list(args) do
    cond do
      Policy.inspection?(args) ->
        args

      true ->
        prefix = ["--json"]

        prefix =
          case Keyword.get(opts, :session_name) do
            name when is_binary(name) and name != "" -> prefix ++ ["--session", name]
            _ -> prefix
          end

        prefix =
          case Keyword.get(opts, :screenshot_dir) do
            dir when is_binary(dir) and dir != "" -> prefix ++ ["--screenshot-dir", dir]
            _ -> prefix
          end

        prefix =
          case Keyword.get(opts, :cdp_url) do
            url when is_binary(url) and url != "" -> prefix ++ ["--cdp", url]
            _ -> prefix
          end

        prefix = if Keyword.get(opts, :pin_tab, false), do: prefix ++ ["--pin-tab"], else: prefix

        prefix ++ args
    end
  end

  @doc """
  Run planned argv.

  Returns `{:ok, raw}` or `{:error, :missing_binary, binary}`.
  """
  @spec run([String.t()], keyword()) ::
          {:ok, map()} | {:error, :missing_binary, String.t()} | {:error, String.t()}
  def run(args, opts \\ []) when is_list(args) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    find =
      Keyword.get_lazy(opts, :find_executable, fn ->
        fn name ->
          WorkspaceEnvironment.find_executable(
            name,
            Keyword.get(opts, :workspace_path)
          )
        end
      end)

    runner = Keyword.get(opts, :runner)

    with {:ok, executable} <- resolve_executable(opts, find),
         :ok <- ensure_chrome_relay_compatible(executable, opts) do
      argv = planned_argv(args, opts)
      maybe_prepare_screenshot_dir(opts)
      run_opts = [timeout_ms: timeout_ms, executable: executable]

      if is_function(runner, 2) do
        runner.(argv, run_opts)
      else
        spawn_cli(executable, argv, timeout_ms, opts)
      end
    end
  end

  @doc "Reports whether agent-browser can drive the Chrome CDP relay."
  @spec chrome_relay_compatibility(keyword()) :: map()
  def chrome_relay_compatibility(opts \\ []) do
    find =
      Keyword.get_lazy(opts, :find_executable, fn ->
        fn name ->
          WorkspaceEnvironment.find_executable(name, Keyword.get(opts, :workspace_path))
        end
      end)

    case resolve_executable(opts, find) do
      {:ok, executable} ->
        relay_compatibility_for(executable, opts)

      {:error, :missing_binary, _binary} ->
        unavailable_compatibility("agent-browser is not installed")

      {:error, reason} ->
        unavailable_compatibility("Could not locate agent-browser: #{inspect(reason)}")
    end
  end

  defp maybe_prepare_screenshot_dir(opts) do
    case Keyword.get(opts, :screenshot_dir) do
      dir when is_binary(dir) and dir != "" -> File.mkdir_p(dir)
      _ -> :ok
    end
  end

  defp ensure_chrome_relay_compatible(executable, opts) do
    if relay_requested?(opts) do
      case relay_compatibility_for(executable, opts) do
        %{compatible: true} ->
          :ok

        %{available: true, version: version} ->
          {:error,
           "Chrome control requires agent-browser 0.39.1 or later; found #{version}. Upgrade agent-browser and try again."}

        %{message: message} ->
          {:error, "Chrome control could not verify agent-browser compatibility: #{message}"}
      end
    else
      :ok
    end
  end

  defp relay_requested?(opts) do
    case Keyword.get(opts, :cdp_url) do
      url when is_binary(url) and url != "" -> true
      _ -> false
    end
  end

  defp relay_compatibility_for(executable, opts) do
    case Keyword.get(opts, :agent_browser_version) do
      version when is_binary(version) -> build_compatibility(version)
      _ -> cached_compatibility(executable, opts)
    end
  end

  defp cached_compatibility(executable, opts) do
    cache_key = {__MODULE__, :chrome_relay_compatibility, executable}
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(cache_key, :missing) do
      {checked_at, compatibility} when now - checked_at < @version_cache_ttl_ms ->
        compatibility

      _ ->
        compatibility = read_compatibility(executable, opts)
        :persistent_term.put(cache_key, {now, compatibility})
        compatibility
    end
  end

  defp read_compatibility(executable, opts) do
    result =
      case Keyword.get(opts, :version_reader) do
        reader when is_function(reader, 1) -> reader.(executable)
        _ -> spawn_cli(executable, ["--version"], @version_timeout_ms, opts)
      end

    case result do
      {:ok, %{exit_code: 0, stdout: output}} when is_binary(output) ->
        build_compatibility(output)

      {:ok, %{exit_code: code}} ->
        unavailable_compatibility("agent-browser --version exited with #{code}")

      {:error, reason} ->
        unavailable_compatibility(inspect(reason))

      other ->
        unavailable_compatibility("unexpected version response: #{inspect(other)}")
    end
  end

  defp build_compatibility(output) do
    with [_, version_text] <- Regex.run(~r/(?:^|\s)v?(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)/, output),
         {:ok, version} <- Version.parse(version_text) do
      %{
        available: true,
        compatible: Version.compare(version, @minimum_chrome_relay_version) in [:eq, :gt],
        version: to_string(version),
        minimum_version: to_string(@minimum_chrome_relay_version),
        message: nil
      }
    else
      _ -> unavailable_compatibility("could not parse agent-browser version")
    end
  end

  defp unavailable_compatibility(message) do
    %{
      available: false,
      compatible: false,
      version: nil,
      minimum_version: to_string(@minimum_chrome_relay_version),
      message: message
    }
  end

  defp resolve_executable(opts, find) do
    case Keyword.get(opts, :executable) do
      bin when is_binary(bin) and bin != "" ->
        {:ok, bin}

      _ ->
        case find.(@binary) do
          {:ok, path} when is_binary(path) -> {:ok, path}
          {:error, _reason} = error -> error
          path when is_binary(path) -> {:ok, path}
          nil -> {:error, :missing_binary, @binary}
        end
    end
  end

  defp spawn_cli(executable, argv, timeout_ms, opts) do
    workspace = Keyword.get(opts, :workspace_path)

    with {:ok, env} <- WorkspaceEnvironment.port_env(workspace) do
      port_opts = [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        :hide,
        {:args, Enum.map(argv, &String.to_charlist/1)}
      ]

      port_opts =
        if is_binary(workspace), do: [{:cd, workspace} | port_opts], else: port_opts

      port_opts =
        if env == [],
          do: port_opts,
          else: [{:env, CommandEnvironment.encode_port_env(env)} | port_opts]

      port = Port.open({:spawn_executable, executable}, port_opts)

      os_pid =
        case Port.info(port, :os_pid) do
          {:os_pid, pid} -> pid
          _ -> nil
        end

      collect(port, os_pid, System.monotonic_time(:millisecond) + timeout_ms, [])
    end
  rescue
    e -> {:error, "Failed to spawn #{@binary}: #{Exception.message(e)}"}
  end

  defp collect(port, os_pid, deadline_ms, chunks) do
    remaining = deadline_ms - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      timeout_result(port, os_pid, chunks)
    else
      receive do
        {^port, {:data, data}} ->
          collect(port, os_pid, deadline_ms, [data | chunks])

        {^port, {:exit_status, exit_code}} ->
          {:ok,
           %{
             stdout: chunks |> Enum.reverse() |> IO.iodata_to_binary(),
             stderr: "",
             exit_code: exit_code,
             timed_out: false
           }}
      after
        min(remaining, 200) ->
          collect(port, os_pid, deadline_ms, chunks)
      end
    end
  end

  defp timeout_result(port, os_pid, chunks) do
    ProcessManager.kill_process_tree(os_pid)
    safe_close(port)

    {:ok,
     %{
       stdout: chunks |> Enum.reverse() |> IO.iodata_to_binary(),
       stderr: "",
       exit_code: 124,
       timed_out: true
     }}
  end

  defp safe_close(port) do
    if Port.info(port) != nil, do: Port.close(port)
  rescue
    _ -> :ok
  end
end
