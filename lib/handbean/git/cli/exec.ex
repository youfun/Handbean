defmodule Handbean.Git.CLI.Exec do
  @moduledoc false

  alias Handbean.Platform.ProcessManager

  @isolate_env [
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_COMMON_DIR",
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_NAMESPACE",
    "GIT_PREFIX",
    "GIT_SSH",
    "GIT_SSH_COMMAND",
    "GIT_PROXY_COMMAND",
    "GIT_ASKPASS",
    "SSH_ASKPASS",
    "GIT_CONFIG",
    "GIT_CONFIG_COUNT",
    "GIT_CONFIG_PARAMETERS",
    "GIT_TEMPLATE_DIR",
    "GIT_TRACE",
    "GIT_TRACE2",
    "GIT_TRACE2_BRIEF",
    "GIT_TRACE2_EVENT",
    "GIT_TRACE2_EVENT_BRIEF",
    "GIT_TRACE2_EVENT_NESTING",
    "GIT_TRACE2_PERF",
    "GIT_TRACE2_PERF_BRIEF",
    "GIT_TRACE2_CONFIG_PARAMS",
    "GIT_TRACE2_ENV_VARS",
    "GIT_TRACE_PACKET",
    "GIT_TRACE_PERFORMANCE",
    "GIT_TRACE_SETUP",
    "GIT_TRACE_PACKFILE",
    "GIT_TRACE_SHALLOW",
    "GIT_TRACE_CURL",
    "GIT_TRACE_CURL_NO_DATA",
    "GIT_TRACE_REDACT",
    "GIT_CURL_VERBOSE",
    "GIT_REDIRECT_STDOUT",
    "GIT_REDIRECT_STDERR",
    "GIT_EXTERNAL_DIFF",
    "GIT_DIFF_OPTS",
    "GIT_PAGER",
    "PAGER",
    "GCM_INTERACTIVE"
  ]

  @spec run(String.t(), [String.t()], keyword()) ::
          {:ok, String.t(), map()} | {:error, String.t()}
  def run(executable, args, opts \\ []) when is_binary(executable) and is_list(args) do
    secrets = List.wrap(Keyword.get(opts, :secrets, []))

    case Keyword.get(opts, :executor) || Application.get_env(:handbean, :git_executor) do
      fun when is_function(fun, 2) ->
        wrap_executor(fun, executable, args, opts, secrets)

      _ ->
        spawn_git(executable, args, opts, secrets)
    end
  end

  @spec redact(String.t(), [String.t()]) :: String.t()
  def redact(text, secrets) when is_binary(text) do
    Enum.reduce(secrets, text, fn secret, acc ->
      if is_binary(secret) and secret != "" do
        String.replace(acc, secret, "[REDACTED]")
      else
        acc
      end
    end)
  end

  def redact(other, _secrets), do: other

  defp wrap_executor(fun, executable, args, opts, secrets) do
    result = fun.(executable, Keyword.put(opts, :args, args))

    case result do
      {:ok, output, meta} when is_map(meta) ->
        {:ok, redact(output, secrets), meta}

      {:error, reason} ->
        {:error, redact(to_string(reason), secrets)}

      other ->
        {:error, "Git executor returned #{redact(inspect(other), secrets)}"}
    end
  end

  defp spawn_git(executable, args, opts, secrets) do
    timeout = Keyword.get(opts, :timeout, 60_000)
    cwd = Keyword.get(opts, :cwd)
    extra_env = Keyword.get(opts, :env, [])

    port_opts = [
      :binary,
      :exit_status,
      :use_stdio,
      :stderr_to_stdout,
      :hide,
      {:args, args},
      {:env, port_env(extra_env)}
    ]

    port_opts =
      if is_binary(cwd) and cwd != "" do
        [{:cd, String.to_charlist(cwd)} | port_opts]
      else
        port_opts
      end

    try do
      port = Port.open({:spawn_executable, executable}, port_opts)
      os_pid = os_pid(port)
      collect(port, os_pid, timeout, secrets)
    rescue
      e ->
        {:error, redact("Failed to spawn Git: #{Exception.message(e)}", secrets)}
    end
  end

  defp port_env(extra) do
    isolated =
      Enum.map(@isolate_env, fn key ->
        {String.to_charlist(key), false}
      end)

    extra_env =
      Enum.map(extra, fn
        {key, false} -> {env_key(key), false}
        {key, value} -> {env_key(key), String.to_charlist(to_string(value))}
      end)

    isolated ++ extra_env
  end

  defp env_key(key) when is_binary(key), do: String.to_charlist(key)
  defp env_key(key) when is_list(key), do: key

  defp collect(port, os_pid, timeout, secrets) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_collect(port, os_pid, deadline, timeout, [], 0, secrets)
  end

  defp do_collect(port, os_pid, deadline, timeout, chunks, bytes, secrets) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      ProcessManager.kill_process_tree(os_pid)
      close_port(port)
      output = chunks_to_text(chunks)

      {:ok, redact(output, secrets), %{timed_out: true}}
    else
      receive do
        {^port, {:data, data}} ->
          do_collect(
            port,
            os_pid,
            deadline,
            timeout,
            [data | chunks],
            bytes + byte_size(data),
            secrets
          )

        {^port, {:exit_status, code}} ->
          output = chunks_to_text(chunks)
          {:ok, redact(output, secrets), %{exit_code: code, timed_out: false}}
      after
        min(remaining, 200) ->
          do_collect(port, os_pid, deadline, timeout, chunks, bytes, secrets)
      end
    end
  end

  defp chunks_to_text(chunks) do
    chunks |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      nil -> nil
    end
  end

  defp close_port(port) do
    if Port.info(port) != nil, do: Port.close(port)
  rescue
    _ -> :ok
  end
end
