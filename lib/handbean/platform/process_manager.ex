defmodule Handbean.Platform.ProcessManager do
  @moduledoc """
  Cross-platform process tree termination.

  On Unix: the synchronous API kills an explicit process-tree snapshot;
  jobs use a separately verified process group.
  On Windows: uses `taskkill /F /T /PID <pid>`.
  The legacy synchronous API logs failures and returns :ok. The job API separately
  verifies group identity and reports unconfirmed cleanup instead of claiming success.
  """

  require Logger

  alias Handbean.Platform

  @doc "Job process-group verification is supported on Linux /proc and the Darwin process NIF."
  def jobs_supported? do
    case job_backend() do
      :linux -> File.dir?("/proc/self")
      :darwin -> :handbean_darwin_process.available()
      nil -> false
    end
  rescue
    _ -> false
  end

  @doc "Verifies the gated Port shell is both session and process-group leader."
  def verify_job_group(pid) when is_integer(pid) and pid > 1 do
    case job_backend() do
      :linux -> verify_linux_job_group(pid)
      :darwin -> verify_darwin_job_group(pid)
      nil -> {:error, "Job process-group verification is unavailable"}
    end
  end

  def verify_job_group(_), do: {:error, "Job shell PID unavailable"}

  @doc """
  Kills a previously verified job group, including descendants after the leader exits.
  Returns :ok only when the platform backend confirms no live members; zombies cannot execute.
  Escaped sessions/groups are not contained. Callers retain responsibility on uncertainty.
  """
  def cleanup_job_group(%{backend: :linux, pid: group, started: started})
      when is_integer(group) and group > 1 do
    cleanup_linux_job_group(group, started)
  rescue
    _ -> {:error, "Process group cleanup unavailable"}
  end

  def cleanup_job_group(%{
        backend: :darwin,
        pid: group,
        started: {start_sec, start_usec, start_abstime}
      })
      when is_integer(group) and group > 1 and is_integer(start_sec) and start_sec >= 0 and
             is_integer(start_usec) and start_usec >= 0 and is_integer(start_abstime) and
             start_abstime > 0 do
    case :handbean_darwin_process.cleanup_group(
           group,
           start_sec,
           start_usec,
           start_abstime
         ) do
      :ok -> :ok
      {:error, :identity_mismatch} -> identity_mismatch_error()
      {:error, :still_alive} -> {:error, "Process group still has live members"}
      {:error, :signal_failed} -> {:error, "Process group signal failed; cleanup unconfirmed"}
      {:error, :cannot_verify} -> {:error, "Cannot verify process group membership"}
      {:error, :enomem} -> {:error, "Process group inspection exhausted memory"}
      _ -> {:error, "Process group cleanup unavailable"}
    end
  rescue
    _ -> {:error, "Process group cleanup unavailable"}
  end

  def cleanup_job_group(_), do: {:error, "Process group identity unavailable"}

  defp job_backend do
    case :os.type() do
      {:unix, :linux} -> :linux
      {:unix, :darwin} -> :darwin
      _ -> nil
    end
  end

  defp verify_linux_job_group(pid) do
    case proc_stat(pid) do
      {:ok, %{group: ^pid, session: ^pid, started: started}} ->
        {:ok, %{backend: :linux, pid: pid, started: started}}

      _ ->
        {:error, "Job shell does not have a verified independent process group"}
    end
  end

  defp verify_darwin_job_group(pid) do
    case :handbean_darwin_process.verify_group(pid) do
      {:ok, start_sec, start_usec, start_abstime} ->
        {:ok,
         %{
           backend: :darwin,
           pid: pid,
           started: {start_sec, start_usec, start_abstime}
         }}

      _ ->
        {:error, "Job shell does not have a verified independent process group"}
    end
  end

  defp cleanup_linux_job_group(group, started) do
    with :ok <- same_group_generation(group, started),
         {:ok, members} <- group_members(group) do
      if members == [] do
        :ok
      else
        case System.cmd("kill", ["-KILL", "--", "-#{group}"], stderr_to_stdout: true) do
          {_, 0} ->
            confirm_group_empty(group)

          _ ->
            case confirm_group_empty(group) do
              :ok -> :ok
              _ -> {:error, "Process group kill failed; cleanup unconfirmed"}
            end
        end
      end
    end
  end

  defp identity_mismatch_error do
    {:error, "Process identity changed or cannot be verified; refusing to signal reused PID"}
  end

  defp same_group_generation(group, started) do
    case proc_stat(group) do
      {:ok, %{started: ^started}} ->
        :ok

      {:error, :enoent} ->
        :ok

      _ ->
        identity_mismatch_error()
    end
  end

  defp confirm_group_empty(group) do
    case group_members(group) do
      {:ok, []} -> :ok
      {:ok, _} -> {:error, "Process group still has live members"}
      error -> error
    end
  end

  defp group_members(group) do
    with {:ok, names} <- File.ls("/proc") do
      Enum.reduce_while(names, {:ok, []}, fn name, {:ok, members} ->
        case Integer.parse(name) do
          {pid, ""} ->
            case proc_stat(pid) do
              {:ok, %{group: ^group, state: state}} when state not in ["Z", "X"] ->
                {:cont, {:ok, [pid | members]}}

              {:ok, _} ->
                {:cont, {:ok, members}}

              {:error, :enoent} ->
                {:cont, {:ok, members}}

              _ ->
                {:halt, {:error, "Cannot verify process group membership"}}
            end

          _ ->
            {:cont, {:ok, members}}
        end
      end)
    end
  end

  defp proc_stat(pid) do
    with {:ok, stat} <- File.read("/proc/#{pid}/stat") do
      # comm may contain spaces and closing parentheses; fields follow its final ')'.
      fields = stat |> String.split(") ") |> List.last() |> String.split()

      case fields do
        [state, _parent, group, session | _] ->
          {:ok,
           %{
             state: state,
             group: String.to_integer(group),
             session: String.to_integer(session),
             started: Enum.at(fields, 19)
           }}

        _ ->
          {:error, :invalid_stat}
      end
    end
  end

  @doc """
  Kills a process and its entire child tree.

  Returns `:ok` in all cases. `nil` pid is a no-op.
  """
  @spec kill_process_tree(integer() | nil) :: :ok
  def kill_process_tree(nil), do: :ok

  def kill_process_tree(os_pid) when is_integer(os_pid) and os_pid > 0 do
    if Platform.windows?() do
      kill_windows(os_pid)
    else
      kill_unix(os_pid)
    end
  rescue
    e ->
      Logger.debug("[ProcessManager] kill failed pid=#{os_pid}: #{Exception.message(e)}")
      :ok
  end

  def kill_process_tree(_invalid), do: :ok

  @doc """
  Stops and kills an independent Unix process group after verifying that the
  supplied PID is still its leader. Falls back to tree cleanup on uncertainty;
  it never signals an unverified negative PID.
  """
  @spec kill_process_group(integer() | nil) :: :ok
  def kill_process_group(os_pid) when is_integer(os_pid) and os_pid > 1 do
    case unix_process_group(os_pid) do
      {:ok, ^os_pid} ->
        group = "-#{os_pid}"
        _ = System.cmd("kill", ["-STOP", "--", group], stderr_to_stdout: true)
        _ = System.cmd("kill", ["-KILL", "--", group], stderr_to_stdout: true)
        :ok

      _ ->
        kill_process_tree(os_pid)
    end
  rescue
    _ -> kill_process_tree(os_pid)
  end

  def kill_process_group(os_pid), do: kill_process_tree(os_pid)

  @doc "Kills only the named process, without process-group signalling."
  @spec kill_process(integer() | nil) :: :ok
  def kill_process(nil), do: :ok

  def kill_process(os_pid) when is_integer(os_pid) and os_pid > 0 do
    if Platform.windows?() do
      _ = System.cmd("taskkill", ["/F", "/PID", "#{os_pid}"], stderr_to_stdout: true)
    else
      _ = System.cmd("kill", ["-9", "#{os_pid}"], stderr_to_stdout: true)
    end

    :ok
  rescue
    _ -> :ok
  end

  def kill_process(_invalid), do: :ok

  # ── Platform-specific ──

  # Stop the whole snapshot before killing it: killing a leaf first lets its
  # parent observe the exit and run the next command before its own turn.
  defp kill_unix(os_pid) do
    pids = os_pid |> unix_process_tree() |> Enum.map(&Integer.to_string/1)
    _ = System.cmd("kill", ["-STOP" | pids], stderr_to_stdout: true)
    _ = System.cmd("kill", ["-9" | pids], stderr_to_stdout: true)
    :ok
  end

  defp unix_process_group(pid) do
    case System.cmd("ps", ["-o", "pgid=", "-p", Integer.to_string(pid)], stderr_to_stdout: true) do
      {output, 0} ->
        case Integer.parse(String.trim(output)) do
          {group, ""} -> {:ok, group}
          _ -> {:error, :invalid_group}
        end

      _ ->
        {:error, :not_found}
    end
  end

  # Kill an explicit descendant snapshot instead of signalling `-pid`. A Port
  # normally inherits the BEAM's process group, so a guessed group id can kill
  # the host process that owns the Port.
  defp unix_process_tree(root_pid) do
    case System.cmd("ps", ["-e", "-o", "pid=", "-o", "ppid="], stderr_to_stdout: true) do
      {output, 0} ->
        children =
          output
          |> String.split("\n", trim: true)
          |> Enum.reduce(%{}, fn line, acc ->
            case line |> String.split() |> Enum.map(&Integer.parse/1) do
              [{pid, ""}, {parent, ""}] -> Map.update(acc, parent, [pid], &[pid | &1])
              _ -> acc
            end
          end)

        descendants_postorder(root_pid, children) ++ [root_pid]

      _ ->
        [root_pid]
    end
  end

  defp descendants_postorder(pid, children) do
    children
    |> Map.get(pid, [])
    |> Enum.flat_map(fn child -> descendants_postorder(child, children) ++ [child] end)
  end

  defp kill_windows(os_pid) do
    _ = System.cmd("taskkill", ["/F", "/T", "/PID", "#{os_pid}"], stderr_to_stdout: true)
    :ok
  end
end
