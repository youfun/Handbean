defmodule Handbean.Agent.Delegation.SessionData do
  @moduledoc false

  alias Handbean.Agent.Subagent.Profile

  def new(id, context, profile, mode) do
    %{
      id: id,
      seq: System.unique_integer([:monotonic, :positive]),
      parent_id: context.conversation_id,
      parent_run_id: context.run_id,
      parent_runner_pid: context.runner_pid,
      workspace: context.working_directory,
      workspace_id: context[:workspace_id],
      profile: profile,
      mode: mode,
      child_opts: nil,
      wake_opts: wake_opts(context),
      status: :running,
      report: "",
      report_truncated?: false,
      usage: %{},
      run_id: nil,
      runs: 0,
      worktree: nil,
      worktree_base: nil,
      worktree_status: nil,
      diff_stat: nil,
      error: nil
    }
  end

  def child_prompt(%Profile{name: "advisor", source: :builtin}, input) do
    Handbean.Utils.SafeMap.get_any(input, "prompt", :prompt) || task_prompt(input)
  end

  def child_prompt(_profile, input), do: task_prompt(input)

  def child_history(session) do
    access_context = %{
      conversation_id: session.parent_id,
      run_id: session.parent_run_id,
      runner_pid: session.parent_runner_pid,
      workspace_id: session.workspace_id
    }

    case Handbean.ConversationTranscriptStore.list(session.id,
           access_context: access_context
         ) do
      {:error, reason} ->
        {:error, reason}

      {:ok, entries} ->
        workspace = session.child_opts[:working_directory]
        Handbean.Attachments.History.to_messages(entries, workspace, session.id)
    end
  end

  def refresh_follow_up_authority(child_opts, job) do
    context = Keyword.get(child_opts, :context, %{})

    delegation_parent =
      context
      |> Map.get(:delegation_parent, %{})
      |> Map.merge(%{mode: :background, child_id: job.id})

    Keyword.put(child_opts, :context, Map.put(context, :delegation_parent, delegation_parent))
  end

  def persist_descriptor(session) do
    path = descriptor_path(session)

    if path do
      body =
        session
        |> Map.take([
          :id,
          :parent_id,
          :workspace,
          :workspace_id,
          :worktree,
          :worktree_base,
          :status,
          :run_id,
          :runs
        ])
        |> Map.put(:checkout_path, session.workspace)
        |> Map.put(:parent_checkout_path, session.workspace)
        |> Map.put(:workspace_path, session.child_opts && session.child_opts[:workspace_path])
        |> Map.put(:profile, session.profile.name)
        |> Handbean.JsonSafe.normalize()
        |> Handbean.JSON.encode!()

      File.mkdir_p(Path.dirname(path))
      File.write(path, body)
    end

    :ok
  end

  def resume_prompt(session) do
    "Resume the interrupted task in this same child conversation and existing worktree. " <>
      "Review the prior transcript and current files first. Do not repeat a tool operation " <>
      "whose prior result says side_effect=committed. If a prior side effect is unknown, " <>
      "reconcile it from the current file/process state before retrying. Continue from the " <>
      "last unfinished step and report the completed outcome. Recovery attempt " <>
      Integer.to_string((session.runs || 0) + 1) <> "."
  end

  defp task_prompt(input) do
    task = Handbean.Utils.SafeMap.get_any(input, "task", :task) || ""
    criteria = Handbean.Utils.SafeMap.get_any(input, "criteria", :criteria) || ""
    task <> "\n\nCompletion criteria:\n" <> criteria
  end

  defp wake_opts(context) do
    case context[:conversation_run_opts] do
      opts when is_list(opts) and opts != [] ->
        Keyword.merge(opts,
          workspace_id: context[:workspace_id],
          tools: Handbean.Agent.default_tools()
        )

      _ ->
        nil
    end
  end

  defp descriptor_path(%{parent_id: parent, id: id}) when is_binary(parent) and is_binary(id) do
    Path.join([
      Handbean.ConversationArtifacts.root(),
      "items",
      parent,
      "subagents",
      id <> ".json"
    ])
  end

  defp descriptor_path(_session), do: nil
end
