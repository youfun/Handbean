defmodule Handbean.Platform.WorkspaceEnvironment do
  @moduledoc """
  Captures and caches the interactive login-shell environment for a workspace.

  The macOS desktop helper runs the user's shell in the workspace and returns a
  JSON environment over an output channel isolated from shell startup noise.
  Captured maps are passed to child commands; they never mutate the BEAM's
  process-global environment.
  """

  use GenServer

  alias Handbean.Platform.CommandEnvironment

  @helper_env "HANDBEAN_DESKTOP_ENV_HELPER"

  @type failure_reason ::
          :service_unavailable
          | :helper_unavailable
          | :workspace_unavailable
          | :invalid_environment
          | :invalid_capture_result
          | :capture_failed
          | {:helper_exit_status, non_neg_integer()}
          | {:capture_exception, module()}
          | {:capture_caught, :exit | :throw}
  @type error :: {:workspace_environment_failed, failure_reason()}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec environment(Path.t() | nil) :: {:ok, map()} | {:error, error()}
  def environment(path) when is_binary(path) and path != "" do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:environment, Path.expand(path)}, 10_000)
    else
      {:error, {:workspace_environment_failed, :service_unavailable}}
    end
  end

  def environment(_path), do: {:ok, %{}}

  @spec port_env(Path.t() | nil) ::
          {:ok, [{String.t(), String.t() | false}]} | {:error, error()}
  def port_env(path) do
    with {:ok, environment} <- environment(path) do
      {:ok, CommandEnvironment.port_env(environment)}
    end
  end

  @spec find_executable(String.t(), Path.t() | nil) ::
          {:ok, String.t()} | {:error, :not_found | error()}
  def find_executable(name, path) do
    with {:ok, environment} <- environment(path) do
      case CommandEnvironment.find_executable(name, environment) || System.find_executable(name) do
        nil -> {:error, :not_found}
        executable -> {:ok, executable}
      end
    end
  end

  @doc false
  def clear do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, :clear), else: :ok
  end

  @impl true
  def init(_opts), do: {:ok, %{environments: %{}}}

  @impl true
  def handle_call({:environment, path}, _from, state) do
    case state.environments do
      %{^path => environment} ->
        {:reply, {:ok, environment}, state}

      _ ->
        case capture(path) do
          {:ok, environment} ->
            {:reply, {:ok, environment}, put_in(state.environments[path], environment)}

          {:error, reason} ->
            {:reply, {:error, {:workspace_environment_failed, reason}}, state}
        end
    end
  end

  def handle_call(:clear, _from, state), do: {:reply, :ok, %{state | environments: %{}}}

  defp capture(path) do
    capture =
      Application.get_env(:handbean, :workspace_environment_capture, &capture_with_helper/1)

    case capture.(path) do
      {:ok, environment} when is_map(environment) ->
        {:ok, CommandEnvironment.sanitize(environment)}

      {:error, reason} ->
        {:error, sanitize_failure(reason)}

      _ ->
        {:error, :invalid_capture_result}
    end
  rescue
    exception -> {:error, {:capture_exception, exception.__struct__}}
  catch
    kind, _reason when kind in [:exit, :throw] -> {:error, {:capture_caught, kind}}
  end

  defp capture_with_helper(path) do
    helper = System.get_env(@helper_env)

    cond do
      not is_binary(helper) or helper == "" ->
        {:ok, %{}}

      not File.regular?(helper) ->
        {:error, :helper_unavailable}

      not File.dir?(path) ->
        {:error, :workspace_unavailable}

      true ->
        {output, status} =
          System.cmd(helper, ["--capture-shell-environment", path],
            cd: path,
            env: CommandEnvironment.system_cmd_unsets(),
            stderr_to_stdout: false
          )

        case {status, Handbean.JSON.decode(output)} do
          {0, {:ok, environment}} when is_map(environment) -> {:ok, environment}
          {0, _decode_result} -> {:error, :invalid_environment}
          {exit_status, _decode_result} -> {:error, {:helper_exit_status, exit_status}}
        end
    end
  end

  defp sanitize_failure(reason)
       when reason in [:helper_unavailable, :workspace_unavailable, :invalid_environment],
       do: reason

  defp sanitize_failure({:helper_exit_status, status})
       when is_integer(status) and status >= 0,
       do: {:helper_exit_status, status}

  defp sanitize_failure(_reason), do: :capture_failed
end
