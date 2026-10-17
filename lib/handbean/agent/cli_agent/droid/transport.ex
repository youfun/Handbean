defmodule Handbean.Agent.CliAgent.Droid.Transport do
  @moduledoc """
  Port transport for one `droid exec` stream JSON-RPC process.

  The executable path is resolved here. Tests pass `:executable` so the real
  Factory CLI is never required. `FACTORY_API_KEY`, when present, is inherited
  from the host environment and is not copied into arguments or logs.
  """

  alias Handbean.Agent.CliAgent.Droid.Codec
  alias Handbean.Platform.{CommandEnvironment, ProcessManager, WorkspaceEnvironment}

  @executable "droid"

  @doc "Open the long-lived exec process. Does not write a request."
  @spec open(keyword()) ::
          {:ok, port(), pos_integer() | nil} | {:error, :not_available | String.t()}
  def open(opts) do
    with {:ok, executable} <- resolve(opts) do
      spawn_port(executable, Codec.argv(opts), opts)
    end
  end

  @doc "Write one JSON-RPC line. A dead port is an error, not a retry."
  @spec write(port(), iodata()) :: :ok | {:error, :port_closed}
  def write(port, line) do
    if Port.info(port) == nil do
      {:error, :port_closed}
    else
      Port.command(port, line)
      :ok
    end
  rescue
    ArgumentError -> {:error, :port_closed}
  end

  @doc "Close the port and its process tree."
  @spec close(port() | nil, pos_integer() | nil) :: :ok
  def close(nil, _os_pid), do: :ok

  def close(port, os_pid) do
    ProcessManager.kill_process_tree(os_pid)
    if Port.info(port) != nil, do: Port.close(port)
    :ok
  rescue
    _ -> :ok
  end

  defp resolve(opts) do
    case Keyword.get(opts, :executable) do
      path when is_binary(path) and path != "" ->
        if File.regular?(path), do: {:ok, path}, else: {:error, :not_available}

      _ ->
        case WorkspaceEnvironment.find_executable(@executable, opts[:cwd]) do
          {:ok, path} -> {:ok, path}
          {:error, :not_found} -> {:error, :not_available}
          {:error, _reason} = error -> error
        end
    end
  end

  defp spawn_port(executable, argv, opts) do
    cwd = Keyword.get(opts, :cwd)

    with {:ok, env} <- WorkspaceEnvironment.port_env(cwd) do
      options = [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        :hide,
        {:args, Enum.map(argv, &String.to_charlist/1)},
        {:line, 65_536}
      ]

      options = if is_binary(cwd), do: [{:cd, cwd} | options], else: options

      options =
        if env == [],
          do: options,
          else: [{:env, CommandEnvironment.encode_port_env(env)} | options]

      port = Port.open({:spawn_executable, executable}, options)
      {:ok, port, os_pid(port)}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      _ -> nil
    end
  end
end
