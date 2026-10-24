defmodule Handbean.Agent.Delegation do
  @moduledoc """
  Application-scoped owner of delegated (subagent) runs.

  Registration precedes startup. Runner's init handshake closes the lost-ack
  window; neither the tool caller nor a per-run supervisor owns cleanup.

  Modes:

    * `:sync` — the parent tool call blocks for the report. Bounded by the
      parent tool timeout; the child closes when the parent run ends.
    * `:background` — the tool call returns at once. The report is delivered
      to the parent conversation as a follow-up. The child survives a normal
      parent `run_end` and is cancelled only when the parent run is cancelled.

  A started child keeps a session record so the user or the parent can send
  it direct messages: a steer while it runs, a follow-up run after it ends.
  Follow-ups reuse the child's original run opts, so a message can never widen
  the child's tools, model, or workspace. Sessions live in memory only.

  This is a trusted runtime policy, not a sandbox for malicious VM code.
  """
  use GenServer

  alias Handbean.Agent.{Coordinator, Delegation.Policy}

  alias Handbean.Agent.Delegation.{Job, Report, SessionData}

  alias Handbean.Agent.Subagent.{Profile, Worktree}
  alias Handbean.ConversationStore
  alias Handbean.PubSub.Session

  @global_limit 16
  @session_limit 64
  @progress_interval_ms 1_000
  @report_flush_ms 50
  @table :handbean_delegation_active

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Synchronous read-only researcher run (legacy `task` behaviour)."
  def run(input, context), do: run(input, context, :task)

  def run(input, context, :task), do: run(input, context, Profile.researcher(), :sync)

  def run(input, context, :advisor) do
    with {:ok, budget, profile} <- Policy.validate_advisor(context) do
      call({:run, input, context, budget, profile, :sync})
    end
  end

  def run(input, context, %Profile{} = profile, mode) when mode in [:sync, :background] do
    with {:ok, budget, profile} <- Policy.validate(context, profile, mode, input) do
      call({:run, input, context, budget, profile, mode})
    end
  end

  def attach(owner, id, runner), do: GenServer.call(owner, {:attach, id, runner})
  def attach_task(owner, id), do: GenServer.call(owner, {:attach_task, id, self()})

  @doc "Whether `run_id` is the open delegated run of child conversation `child_id`."
  def child_active?(child_id, run_id) do
    :ets.lookup(@table, child_id) == [{child_id, run_id}]
  rescue
    ArgumentError -> false
  end

  @doc "List, inspect, or cancel the children of a parent conversation."
  def status(parent_id, action, child_ref \\ nil) when action in [:list, :get, :cancel] do
    call({:status, parent_id, action, child_ref})
  end

  @doc """
  Send a direct message to a child of `parent_id`. `child_ref` is a child
  conversation id or a `subagent_type` (the most recent child of that type).

  A running child receives the message as a steer. A finished child starts a
  follow-up run with its own history. Options:

    * `:forward_to_parent` — deliver the follow-up's report to the parent
      conversation (default `false`; the reply stays in the child transcript
      and the `subagent_end` event).
    * `:source` — inbound source recorded in the child transcript.
  """
  def message(parent_id, child_ref, text, opts \\ [])
      when is_binary(parent_id) and is_binary(child_ref) and is_binary(text) do
    if String.trim(text) == "" do
      {:error, "message must be non-empty"}
    else
      call({:message, parent_id, child_ref, text, opts})
    end
  end

  @doc "Apply or discard a finished write child's worktree."
  def worktree(parent_id, action, child_ref) when action in [:apply, :discard] do
    with {:ok, session} <- call({:worktree_claim, parent_id, child_ref}) do
      result =
        case action do
          :apply -> Worktree.apply(session.workspace, session.id)
          :discard -> Worktree.discard(session.workspace, session.id)
        end

      call({:worktree_done, session.id, action, result})
      result
    end
  end

  @doc "Forward a user approval decision to a child awaiting approval."
  def resume_child(parent_id, child_ref, decisions) when is_list(decisions) do
    call({:resume_child, parent_id, child_ref, decisions})
  end

  @doc """
  Continue an interrupted child without replaying committed tool effects.

  Reuses the same child conversation and worktree. Completed receipts are
  returned; unknown receipts must be reconciled and are not rerun.
  """
  def resume_task(parent_id, child_ref) when is_binary(parent_id) and is_binary(child_ref) do
    call({:resume_task, parent_id, child_ref})
  end

  defp call(message) do
    GenServer.call(__MODULE__, message, :infinity)
  catch
    :exit, _ -> {:error, "Delegation owner unavailable; completion cannot be confirmed"}
  end

  # ── GenServer ──────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    else
      :ets.delete_all_objects(@table)
    end

    Phoenix.PubSub.subscribe(Handbean.PubSub, "runtime:runs")
    {:ok, %{jobs: %{}, sessions: %{}, reports: %{}}}
  end

  @impl true
  def handle_call({:run, input, context, budget, profile, mode}, from, state) do
    per_run = Enum.count(state.jobs, fn {_, job} -> job.parent_run_id == context.run_id end)

    cond do
      map_size(state.jobs) >= @global_limit ->
        {:reply, {:error, "Delegation capacity reached"}, state}

      per_run >= max_per_run() ->
        {:reply, {:error, "Subagent concurrency limit reached for this run (#{max_per_run()})"},
         state}

      not Policy.live_parent?(context) ->
        {:reply, {:error, "Parent run is no longer active"}, state}

      profile.isolation == :worktree and not worktree_available?(context) ->
        {:reply, {:error, "Worktree isolation needs a shell host and a git workspace"}, state}

      true ->
        start_initial(state, input, context, budget, profile, mode, from)
    end
  end

  def handle_call({:attach, id, runner}, _from, state) do
    case state.jobs[id] do
      %{status: :running} = job ->
        if open?(job) do
          job = %{job | runner: runner, runner_ref: Process.monitor(runner)}
          {:reply, :ok, Job.put(state, job)}
        else
          {:reply, {:error, :parent_closed}, state}
        end

      _ ->
        {:reply, {:error, :delegation_closed}, state}
    end
  end

  def handle_call({:attach_task, id, task}, _from, state) do
    case state.jobs[id] do
      %{status: :running} = job ->
        if open?(job),
          do: {:reply, :ok, Job.put(state, %{job | task: task})},
          else: {:reply, {:error, :delegation_closed}, state}

      _ ->
        {:reply, {:error, :delegation_closed}, state}
    end
  end

  def handle_call({:status, parent_id, :list, _ref}, _from, state) do
    children =
      state.sessions
      |> Map.values()
      |> Enum.filter(&(&1.parent_id == parent_id))
      |> Enum.sort_by(& &1.seq)
      |> Enum.map(&Report.public_session(&1, state.jobs[&1.id]))

    {:reply, {:ok, children}, state}
  end

  def handle_call({:status, parent_id, :get, ref}, _from, state) do
    reply =
      with {:ok, session} <- Job.owned_session(state, parent_id, ref) do
        {:ok, Report.public_session(session, state.jobs[session.id], report: true)}
      end

    {:reply, reply, state}
  end

  def handle_call({:status, parent_id, :cancel, ref}, _from, state) do
    with {:ok, session} <- Job.owned_session(state, parent_id, ref),
         %{status: status} = job when status in [:running, :awaiting_approval] <-
           state.jobs[session.id] do
      {:reply, {:ok, %{child_conversation_id: session.id, status: :cancelled}},
       Job.put(state, close(job, :cancelled))}
    else
      {:error, _} = error -> {:reply, error, state}
      _ -> {:reply, {:error, "Subagent is not running"}, state}
    end
  end

  def handle_call({:message, parent_id, ref, text, opts}, from, state) do
    with {:ok, session} <- Job.owned_session(state, parent_id, ref),
         :ok <- Job.messageable(session) do
      case state.jobs[session.id] do
        %{status: :running} = job ->
          steer(state, job, session, text, opts, from)

        %{status: :awaiting_approval} ->
          {:reply, {:error, "Subagent is waiting for a tool approval"}, state}

        %{} ->
          {:reply, {:error, "Subagent is finishing; retry shortly"}, state}

        nil ->
          if map_size(state.jobs) >= @global_limit,
            do: {:reply, {:error, "Delegation capacity reached"}, state},
            else: start_follow_up(state, session, text, opts, from)
      end
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:worktree_claim, parent_id, ref}, _from, state) do
    reply =
      with {:ok, session} <- Job.owned_session(state, parent_id, ref) do
        cond do
          is_nil(session.worktree) ->
            {:error, "Subagent has no worktree"}

          session.worktree_status != nil ->
            {:error, "Worktree already #{session.worktree_status}"}

          Map.has_key?(state.jobs, session.id) ->
            {:error, "Subagent is still running"}

          true ->
            {:ok, session}
        end
      end

    {:reply, reply, state}
  end

  def handle_call({:worktree_done, id, action, result}, _from, state) do
    state =
      case {result, state.sessions[id]} do
        {{:error, _}, _} ->
          state

        {_, nil} ->
          state

        {_, session} ->
          Job.put_session(
            state,
            %{session | worktree_status: done(action)},
            @session_limit
          )
      end

    {:reply, :ok, state}
  end

  def handle_call({:resume_task, parent_id, ref}, from, state) do
    with {:ok, session} <- Job.owned_session(state, parent_id, ref),
         :ok <- Job.messageable(session),
         false <- Map.has_key?(state.jobs, session.id),
         false <- map_size(state.jobs) >= @global_limit do
      prompt = SessionData.resume_prompt(session)

      start_follow_up(
        state,
        session,
        prompt,
        [forward_to_parent: true, source: :recovery],
        from
      )
    else
      {:error, _} = error ->
        {:reply, error, state}

      true ->
        {:reply, {:error, "subagent cannot be resumed while it is running or at capacity"}, state}
    end
  end

  def handle_call({:resume_child, parent_id, ref, decisions}, _from, state) do
    with {:ok, session} <- Job.owned_session(state, parent_id, ref),
         %{status: :awaiting_approval} = job <- state.jobs[session.id] do
      case Handbean.Agent.Runner.resume(job.id, decisions) do
        :ok ->
          cancel_timer(job.approval_timer)
          remaining = max(job.remaining_ms, 1_000)
          timer = Process.send_after(self(), {:deadline, job.id, job.run_id}, remaining)

          job = %{
            job
            | status: :running,
              approval_timer: nil,
              timer: timer,
              deadline_at: now() + remaining
          }

          {:reply, :ok, Job.put(state, job)}

        error ->
          {:reply, error, state}
      end
    else
      {:error, _} = error -> {:reply, error, state}
      _ -> {:reply, {:error, :not_awaiting_approval}, state}
    end
  end

  @impl true
  def handle_info({:prepared, id, child_opts, worktree}, state) do
    state =
      case state.sessions[id] do
        nil ->
          state

        session ->
          session = %{
            session
            | child_opts: child_opts,
              worktree: worktree && worktree.path,
              worktree_base: worktree && worktree.base
          }

          SessionData.persist_descriptor(session)
          Job.put_session(state, session, @session_limit)
      end

    {:noreply, state}
  end

  def handle_info({:finished, id, forward?, view}, state) do
    case state.sessions[id] do
      nil ->
        {:noreply, state}

      session ->
        session = %{
          session
          | status: view.status,
            report: view.report,
            report_truncated?: view.report_truncated?,
            usage: view.usage,
            diff_stat: view.diff_stat || session.diff_stat,
            error: view.error
        }

        SessionData.persist_descriptor(session)
        state = Job.put_session(state, session, @session_limit)

        state =
          if forward?,
            do: Report.queue(state, session, view.text, self(), @report_flush_ms),
            else: state

        {:noreply, state}
    end
  end

  def handle_info({:started, id, run_id, result}, state) do
    update_job(state, id, run_id, fn job ->
      job = %{job | started?: true}
      reply_start(job, result)

      case result do
        {:ok, _} ->
          publish(job, :subagent_start, %{
            tool_use_id: job.tool_call_id,
            child_conversation_id: job.id,
            child_run_id: job.run_id,
            subagent_type: job.profile.name,
            mode: job.mode,
            kind: job.kind
          })

          maybe_finish(%{job | reply_to: nil})

        {:error, reason} ->
          Report.startup_failure(job, reason)
          close(%{job | reply_to: nil, error: reason}, :startup_failed)
      end
    end)
  end

  def handle_info({:child_event, id, run_id, {:message_delta, %{chunk: chunk}}}, state) do
    update_job(state, id, run_id, fn job ->
      result = Handbean.Utils.Truncate.truncate(job.text <> chunk, :head, max_bytes: 16_000)
      %{job | text: result.content, truncated?: job.truncated? or result.truncated}
    end)
  end

  def handle_info({:child_event, id, run_id, {:delegation_usage, usage}}, state) do
    update_job(state, id, run_id, &%{&1 | usage: usage})
  end

  def handle_info({:child_event, id, run_id, {:turn_start, payload}}, state) do
    update_job(state, id, run_id, &%{&1 | turn: payload[:turn] || &1.turn})
  end

  def handle_info({:child_event, id, run_id, {:tool_start, payload}}, state) do
    update_job(
      state,
      id,
      run_id,
      &Report.progress(
        &1,
        Handbean.Utils.SafeMap.get_any(payload, :tool, "tool"),
        now(),
        @progress_interval_ms
      )
    )
  end

  def handle_info({:child_event, id, run_id, {:tool_approval_requested, payload}}, state) do
    update_job(state, id, run_id, fn
      %{mode: :background, status: :running} = job ->
        cancel_timer(job.timer)

        publish(
          job,
          :subagent_approval_requested,
          Map.merge(payload, %{
            tool_use_id: job.tool_call_id,
            child_conversation_id: job.id,
            subagent_type: job.profile.name
          })
        )

        timer =
          Process.send_after(self(), {:approval_deadline, job.id, job.run_id}, approval_ms())

        %{
          job
          | status: :awaiting_approval,
            timer: nil,
            approval_timer: timer,
            remaining_ms: job.deadline_at - now()
        }

      job ->
        job
    end)
  end

  def handle_info({:child_event, id, run_id, {:run_end, payload}}, state) do
    update_job(state, id, run_id, fn job ->
      job = %{job | usage: Map.get(payload, :usage, job.usage)}
      status = payload[:status]

      cond do
        job.status == :awaiting_approval and status in [:interrupted, "interrupted"] -> job
        status in [:interrupted, "interrupted"] -> close(job, :blocked)
        true -> close(job, status)
      end
    end)
  end

  def handle_info({:child_event, _id, _run_id, _event}, state), do: {:noreply, state}

  def handle_info({:deadline, id, run_id}, state),
    do: update_job(state, id, run_id, &close(&1, :timed_out))

  def handle_info({:approval_deadline, id, run_id}, state),
    do: update_job(state, id, run_id, &close(&1, :blocked))

  def handle_info({:reply_deadline, id, run_id}, state) do
    update_job(state, id, run_id, fn job ->
      case close(job, :timed_out) do
        nil ->
          nil

        job ->
          if job.from, do: GenServer.reply(job.from, Report.report(job, :cleaning_up))
          %{job | from: nil}
      end
    end)
  end

  def handle_info({:cleaned, id, run_id, diff}, state),
    do: update_job(state, id, run_id, &maybe_finish(%{&1 | cleaned?: true, diff: diff}))

  def handle_info({:retry_cleanup, id, run_id}, state),
    do: update_job(state, id, run_id, &cleanup/1)

  def handle_info({:flush_reports, parent_id}, state) do
    {batch, reports} = Map.pop(state.reports, parent_id)
    if batch, do: Report.deliver(parent_id, batch)
    {:noreply, %{state | reports: reports}}
  end

  def handle_info({:run_lifecycle, parent, :run_end, payload}, state) do
    status = payload[:status]

    if status in [:interrupted, "interrupted"] do
      {:noreply, state}
    else
      jobs =
        Enum.reduce(state.jobs, %{}, fn {id, job}, acc ->
          job =
            if job.parent_id == parent and closes_with_parent?(job, status),
              do: close(job, :parent_closed),
              else: job

          if job, do: Map.put(acc, id, job), else: acc
        end)

      {:noreply, Job.finish_removed(state, jobs, @table)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    jobs =
      Enum.reduce(state.jobs, %{}, fn {id, job}, acc ->
        job =
          cond do
            ref in [job.parent_ref, job.caller_ref] ->
              close(job, :parent_closed)

            ref == job.runner_ref and job.status in [:running, :awaiting_approval] ->
              Report.child_stopped(job, state.sessions[id], reason)
              close(%{job | error: {:child_stopped, reason}}, :child_stopped)

            ref == job.runner_ref ->
              job

            ref == job.starter_ref and not job.started? ->
              error = {:startup_failed, :starter_down, reason}
              Report.startup_failure(job, error)
              reply_start(job, {:error, "Subagent failed to start"})
              job = %{job | started?: true, reply_to: nil, error: error}

              if job.status == :running and is_nil(job.runner),
                do: close(job, :startup_failed),
                else: maybe_finish(job)

            ref == job.starter_ref ->
              maybe_finish(job)

            ref == job.cleanup_ref and not job.cleaned? ->
              # Cleanup worker failed; the owner retains responsibility.
              Process.send_after(self(), {:retry_cleanup, id, job.run_id}, 100)
              %{job | cleanup_ref: nil}

            true ->
              job
          end

        if job, do: Map.put(acc, id, job), else: acc
      end)

    {:noreply, Job.finish_removed(state, jobs, @table)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # ── Starting runs ──────────────────────────────────────────────────────

  defp start_initial(state, input, context, budget, profile, mode, from) do
    id = Ecto.UUID.generate()

    session = SessionData.new(id, context, profile, mode)

    job =
      Job.open(id, profile, mode, budget, context, from, @table, self(), now())
      |> Map.merge(%{kind: :initial, forward?: mode == :background})

    owner = self()
    prompt = SessionData.child_prompt(profile, input)

    {:ok, starter} =
      Task.Supervisor.start_child(Handbean.AgentRunTaskSupervisor, fn ->
        result = start_initial_child(job, context, prompt, owner, input)
        send(owner, {:started, id, job.run_id, result})
      end)

    job = %{job | starter_ref: Process.monitor(starter)}

    state =
      state
      |> Job.put_session(%{session | run_id: job.run_id, runs: 1}, @session_limit)
      |> Job.put(job)

    if mode == :background do
      {:reply, {:ok, Report.background_ack(job), Report.public_details(job, :running)}, state}
    else
      {:noreply, state}
    end
  end

  defp start_initial_child(job, context, prompt, owner, input) do
    with {:ok, worktree} <-
           startup_step(:worktree, fn ->
             if job.profile.isolation == :worktree,
               do: Worktree.create(context.working_directory, job.id),
               else: {:ok, nil}
           end),
         workspace = (worktree && worktree.path) || context.working_directory,
         {:ok, _} <-
           startup_step(:create_conversation, fn ->
             ConversationStore.create(context[:workspace_id],
               id: job.id,
               visibility: "internal",
               parent_conversation_id: context.conversation_id,
               parent_run_id: context.run_id,
               parent_tool_call_id: context[:tool_call_id],
               checkout_path: workspace,
               title: "Subagent #{job.profile.name}"
             )
           end),
         {:ok, child_opts} <-
           startup_step(:child_opts, fn ->
             Policy.child_opts(
               %{context | working_directory: workspace},
               job.budget,
               job.profile,
               %{mode: job.mode, child_id: job.id},
               input
             )
           end) do
      send(owner, {:prepared, job.id, child_opts, worktree})

      startup_step(:add_message, fn ->
        Coordinator.add_message(job.id, prompt, child_opts ++ Job.run_opts(job, owner))
      end)
    end
  end

  defp startup_step(stage, fun) when is_atom(stage) and is_function(fun, 0) do
    case fun.() do
      {:error, reason} -> {:error, {:startup_failed, stage, reason}}
      result -> result
    end
  rescue
    exception -> {:error, {:startup_failed, stage, {exception, __STACKTRACE__}}}
  catch
    kind, reason -> {:error, {:startup_failed, stage, {kind, reason, __STACKTRACE__}}}
  end

  defp start_follow_up(state, session, text, opts, from) do
    profile = session.profile
    budget = profile.timeout_ms
    context = %{conversation_id: session.parent_id, working_directory: session.workspace}

    job =
      Job.open(
        session.id,
        profile,
        :background,
        budget,
        context,
        nil,
        @table,
        self(),
        now()
      )
      |> Map.merge(%{
        kind: :dm,
        forward?: Keyword.get(opts, :forward_to_parent, false),
        reply_to: from
      })

    owner = self()

    child_opts =
      case SessionData.child_history(session) do
        {:error, reason} ->
          {:error, reason}

        history ->
          session.child_opts
          |> SessionData.refresh_follow_up_authority(job)
          |> Keyword.merge(
            history_messages: history,
            source: Keyword.get(opts, :source, :direct_message)
          )
          |> Keyword.merge(Job.run_opts(job, owner))
      end

    if match?({:error, _}, child_opts) do
      {:reply, {:error, "child history could not be restored"}, state}
    else
      start_follow_up_task(state, session, job, text, child_opts, owner)
    end
  end

  defp start_follow_up_task(state, session, job, text, child_opts, owner) do
    {:ok, starter} =
      Task.Supervisor.start_child(Handbean.AgentRunTaskSupervisor, fn ->
        send(
          owner,
          {:started, job.id, job.run_id, Coordinator.add_message(job.id, text, child_opts)}
        )
      end)

    job = %{job | starter_ref: Process.monitor(starter)}

    session = %{
      session
      | status: :running,
        run_id: job.run_id,
        runs: session.runs + 1,
        report: "",
        report_truncated?: false,
        error: nil
    }

    {:noreply,
     state
     |> Job.put_session(session, @session_limit)
     |> Job.put(job)}
  end

  defp steer(state, job, session, text, opts, from) do
    owner = self()

    child_opts =
      session.child_opts
      |> Keyword.merge(
        run_id: job.run_id,
        delegation_owner: owner,
        deliver_as: :steer,
        source: Keyword.get(opts, :source, :direct_message)
      )

    Task.Supervisor.start_child(Handbean.AgentRunTaskSupervisor, fn ->
      reply =
        try do
          case Coordinator.add_message(job.id, text, child_opts) do
            {:ok, %{action: :enqueued}} ->
              {:ok, %{child_conversation_id: job.id, child_run_id: job.run_id, delivery: :steer}}

            {:ok, _} ->
              {:error, "Subagent finished before the message arrived; retry to start a follow-up"}

            {:error, reason} ->
              {:error, reason}
          end
        catch
          kind, reason -> {:error, {kind, reason}}
        end

      GenServer.reply(from, reply)
    end)

    forward? = job.forward? or Keyword.get(opts, :forward_to_parent, false)
    {:noreply, Job.put(state, %{job | forward?: forward?})}
  end

  # ── Job lifecycle ──────────────────────────────────────────────────────

  defp update_job(state, id, run_id, fun) do
    case state.jobs[id] do
      %{run_id: ^run_id} = job ->
        case fun.(job) do
          nil -> {:noreply, Job.remove(state, id, @table)}
          updated -> {:noreply, Job.put(state, updated)}
        end

      _ ->
        {:noreply, state}
    end
  end

  defp open?(%{mode: :sync} = job) do
    now() < job.deadline_at and Policy.live_parent?(job.parent_context) and
      is_tuple(job.from) and Process.alive?(elem(job.from, 0))
  end

  defp open?(job), do: now() < job.deadline_at

  defp closes_with_parent?(%{mode: :sync}, _status), do: true
  defp closes_with_parent?(_job, status), do: status in [:cancelled, "cancelled"]

  defp close(%{status: status} = job, new_status) when status in [:running, :awaiting_approval] do
    cancel_timer(job.timer)
    cancel_timer(job.approval_timer)
    :ets.delete(@table, job.id)
    cleanup(%{job | status: normalize_status(new_status), timer: nil, approval_timer: nil})
  end

  defp close(job, _status), do: job

  defp cleanup(job), do: Job.cleanup(job, self())

  defp maybe_finish(%{cleaned?: true, started?: true} = job) do
    status =
      case ConversationStore.record_delegated_usage(job.parent_id, job.run_id, job.usage) do
        :ok -> job.status
        _ -> :usage_persistence_failed
      end

    job = %{job | status: status}
    if job.from, do: GenServer.reply(job.from, Report.report(job, status))
    # A cancelled parent has nothing to wake, and an explicit cancel already
    # returned its result to the caller.
    forward? =
      job.mode == :background and job.forward? and status not in [:parent_closed, :cancelled]

    send(self(), {:finished, job.id, forward?, Report.finished(job)})
    publish_end(job)
    cancel_timer(job.timer)
    cancel_timer(job.reply_timer)
    cancel_timer(job.approval_timer)

    for ref <- [job.parent_ref, job.caller_ref, job.runner_ref, job.starter_ref, job.cleanup_ref],
        is_reference(ref),
        do: Process.demonitor(ref, [:flush])

    nil
  end

  defp maybe_finish(job), do: job

  defp reply_start(%{reply_to: nil}, _result), do: :ok

  defp reply_start(job, {:ok, _}) do
    GenServer.reply(
      job.reply_to,
      {:ok, %{child_conversation_id: job.id, child_run_id: job.run_id, delivery: :follow_up}}
    )
  end

  defp reply_start(job, {:error, reason}), do: GenServer.reply(job.reply_to, {:error, reason})

  defp publish_end(job) do
    publish(job, :subagent_end, Report.end_payload(job))
  end

  defp publish(job, kind, payload), do: Session.broadcast_event(job.parent_id, kind, payload)

  defp worktree_available?(context) do
    Handbean.Host.shell?() and
      Handbean.Agent.Subagent.ProfileRegistry.git_repo?(context.working_directory)
  end

  defp done(:apply), do: :applied
  defp done(:discard), do: :discarded

  defp max_per_run, do: Application.get_env(:handbean, :subagent_max_per_run, 4)
  defp approval_ms, do: Application.get_env(:handbean, :subagent_approval_timeout_ms, 600_000)

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)

  defp normalize_status(status) when is_atom(status), do: status

  defp normalize_status(status) when is_binary(status) do
    String.to_existing_atom(status)
  rescue
    ArgumentError -> :error
  end

  defp now, do: System.monotonic_time(:millisecond)
end
