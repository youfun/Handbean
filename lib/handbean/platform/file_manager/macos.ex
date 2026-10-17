defmodule Handbean.Platform.FileManager.MacOS do
  @moduledoc false

  @behaviour Handbean.Platform.FileManager

  @executable "/usr/bin/open"
  @timeout 2_000

  @spec kind() :: :finder
  def kind, do: :finder

  @spec available?() :: boolean()
  def available?, do: File.exists?(@executable)

  @spec command_spec(String.t()) ::
          {:ok, {String.t(), [String.t()]}} | {:error, :invalid_path}
  def command_spec(path) when is_binary(path) do
    if Path.type(path) == :absolute and not String.contains?(path, <<0>>) do
      {:ok, {@executable, ["-R", "--", path]}}
    else
      {:error, :invalid_path}
    end
  end

  def command_spec(_path), do: {:error, :invalid_path}

  @spec reveal(String.t(), keyword()) :: :ok | {:error, term()}
  def reveal(path, opts \\ []) do
    runner = Keyword.get(opts, :runner, &run/3)
    timeout = Keyword.get(opts, :timeout, @timeout)

    with {:ok, {executable, arguments}} <- command_spec(path),
         {:ok, 0} <- runner.(executable, arguments, timeout) do
      :ok
    else
      {:ok, status} -> {:error, {:exit_status, status}}
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_runner_result, other}}
    end
  end

  defp run(executable, arguments, timeout) do
    task =
      Task.async(fn ->
        try do
          {_output, status} = System.cmd(executable, arguments, stderr_to_stdout: true)
          {:ok, status}
        rescue
          error -> {:error, Exception.message(error)}
        catch
          kind, reason -> {:error, {kind, reason}}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
      {:exit, reason} -> {:error, {:runner_exit, reason}}
    end
  end
end
