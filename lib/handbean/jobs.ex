defmodule Handbean.Jobs do
  @moduledoc """
  Run-scoped Bash and BEAM jobs. Start Cleaner before Server in the application supervision tree,
  outside RunSupervisor. Runner must open a scope before executing tools and close it on
  every real terminal path; its monitor also closes the scope on abnormal exit.
  This is not OS containment and does not resume jobs after a VM restart.

  Context requires trusted :conversation_id, :run_id and :working_directory; tool
  calls additionally require :tool_timeout (milliseconds), and launches :tool_call_id.
  Limits: 4 running jobs/run, 16 globally, the most recent 32 retained jobs per
  conversation/workspace, 256 retained globally, 50KB output/job, and a 15-minute
  terminal TTL after its run closes. Retention limits evict the oldest terminal jobs instead of
  blocking launches.
  """
  alias Handbean.Jobs.Server

  def child_specs,
    do: [
      Handbean.Jobs.Cleaner,
      {DynamicSupervisor, name: Handbean.Jobs.BeamSupervisor, strategy: :one_for_one},
      Server
    ]

  def open_run(context, runner) when is_pid(runner) do
    with {:ok, owner} <- owner(context), do: call({:open, owner, runner}, 5_000)
  end

  def close_run(_context, status)
      when status in [:interrupted, "interrupted", :awaiting_approval, "awaiting_approval"],
      do: :ok

  def close_run(context, _status) do
    with {:ok, owner} <- owner(context), do: call({:close, owner}, 5_000)
  end

  def start(command, cwd, timeout_ms, wait_ms, context)
      when is_integer(wait_ms) and wait_ms > 0 do
    with :ok <- shell_supported(),
         {:ok, owner} <- owner(context),
         {:ok, wait} <- wait_budget(wait_ms, context),
         :ok <- valid_timeout(timeout_ms),
         {:ok, call_id} <- call_id(context),
         {:ok, cwd} <- resolve_cwd(cwd, context) do
      capture = Handbean.WorkspaceChangeCapture.start(elem(owner, 2))
      deadline = now() + wait
      call({:start, owner, call_id, command, cwd, timeout_ms, deadline, capture}, wait)
    end
  end

  def start(_, _, _, _, _), do: {:error, "Job launch wait_ms must be a positive integer"}

  @doc "Start trusted BEAM work; the callback receives a bounded output sink."
  def start_beam(kind, fun, timeout_ms, wait_ms, context)
      when kind in [:script, :mix] and is_function(fun, 1) and is_integer(wait_ms) and wait_ms > 0 do
    with {:ok, owner} <- owner(context),
         {:ok, wait} <- wait_budget(wait_ms, context),
         :ok <- valid_timeout(timeout_ms),
         {:ok, call_id} <- call_id(context) do
      capture = Handbean.WorkspaceChangeCapture.start(elem(owner, 2))

      call(
        {:start, owner, call_id, {:beam, kind, fun}, nil, timeout_ms, now() + wait, capture},
        wait
      )
    end
  end

  def start_beam(_, _, _, _, _), do: {:error, "Job launch wait_ms must be a positive integer"}

  def status(id, cursor, wait_ms, context) when is_nil(id) or is_binary(id) do
    with {:ok, owner} <- owner(context),
         {:ok, wait} <- status_wait_budget(wait_ms, context),
         :ok <- valid_cursor(cursor) do
      call({:status, owner, id, cursor, now() + wait}, wait + 1_000)
    end
  end

  def status(_, _, _, _), do: {:error, "job_id must be a string or omitted"}

  def cancel(id, context) when is_binary(id) do
    with {:ok, owner} <- owner(context),
         {:ok, wait} <- wait_budget(1_000, context) do
      call({:cancel, owner, id}, wait)
    end
  end

  def cancel(_, _), do: {:error, "job_id is required"}

  def format({:ok, result}) do
    header = Handbean.JSON.encode!(Map.drop(result, [:output, :result, :changes]))
    text = if result[:output], do: header <> "\n\n" <> result.output, else: header
    text = if result[:result], do: text <> "\n\nresult:\n" <> result.result, else: text

    details =
      %{job: result}
      |> maybe_put_changes(result[:changes])

    {:ok, text, details}
  end

  def format(error), do: error

  defp maybe_put_changes(details, changes) when is_list(changes) and changes != [],
    do: Map.put(details, :changes, changes)

  defp maybe_put_changes(details, _changes), do: details

  def wait_budget(requested, context) when is_integer(requested) and requested >= 0 do
    case context[:tool_timeout] do
      timeout when is_integer(timeout) and timeout >= 200 ->
        {:ok, min(requested, min(5_000, div(timeout, 2)))}

      _ ->
        {:error, "Job tools require a trusted tool_timeout of at least 200ms"}
    end
  end

  def wait_budget(_, _), do: {:error, "wait_ms must be a non-negative integer"}

  def status_wait_budget(requested, context) when is_integer(requested) and requested >= 0 do
    case context[:tool_timeout] do
      timeout when is_integer(timeout) and timeout >= 200 ->
        {:ok, min(requested, min(30_000, div(timeout, 2)))}

      _ ->
        {:error, "Job tools require a trusted tool_timeout of at least 200ms"}
    end
  end

  def status_wait_budget(_, _), do: {:error, "wait_ms must be a non-negative integer"}

  defp owner(context) do
    case {context[:conversation_id], context[:run_id], context[:working_directory]} do
      {conversation, run, workspace}
      when is_binary(conversation) and conversation != "" and
             is_binary(run) and run != "" and is_binary(workspace) and workspace != "" ->
        {:ok,
         {conversation, run,
          Handbean.Security.PathValidator.resolve_symlink(Path.expand(workspace))}}

      _ ->
        {:error, "Job tools require trusted conversation, run and workspace context"}
    end
  end

  defp resolve_cwd(cwd, context) do
    expanded =
      (cwd || context.working_directory)
      |> Handbean.Agent.Tool.Helpers.expand_tilde()
      |> Path.expand(context.working_directory)

    with :ok <- Handbean.Security.PathValidator.reject_resolved(expanded),
         {:ok, canonical} <- Handbean.Security.PathValidator.canonicalize(expanded) do
      Handbean.Agent.Tool.resolve_path(canonical, context, :execute)
    end
  end

  defp shell_supported do
    if Handbean.Host.shell?() and Handbean.Host.shell_jobs?() and
         Handbean.Platform.ProcessManager.jobs_supported?(),
       do: :ok,
       else: {:error, "Bash jobs unavailable on this host; use synchronous Bash"}
  end

  defp call_id(%{tool_call_id: id}) when is_binary(id) and id != "", do: {:ok, id}
  defp call_id(_), do: {:error, "Job launch requires trusted tool_call_id"}
  defp valid_timeout(ms) when is_integer(ms) and ms in 1..3_600_000, do: :ok
  defp valid_timeout(_), do: {:error, "Job timeout must be 1ms to 3600000ms"}
  defp valid_cursor(cursor) when is_integer(cursor) and cursor >= 0, do: :ok
  defp valid_cursor(_), do: {:error, "cursor must be a non-negative byte offset"}
  defp now, do: System.monotonic_time(:millisecond)

  defp call(message, wait) do
    GenServer.call(Server, message, max(wait, 1))
  catch
    :exit, {:timeout, _} ->
      {:error,
       "Job response deadline reached; use job_status without job_id to recover accepted handles"}

    :exit, _ ->
      {:error, "Job service unavailable; old handles cannot be resumed"}
  end
end
