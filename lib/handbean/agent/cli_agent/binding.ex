defmodule Handbean.Agent.CliAgent.Binding do
  @moduledoc """
  Per-conversation CLI harness binding state.

  Separates external CLI harness native state (`backend`, `instance_id`,
  `session_id`, `identity_strength`, `cwd`, `capabilities`, active `run_id`,
  `status_detail`, and suspended `pending_request`) from Handbean's canonical
  conversation transcript projection.
  """

  alias Handbean.Agent.CliAgent.Registry
  alias Handbean.Agent.CliAgent.Session, as: CliSession
  alias Handbean.PubSub.Session
  alias Handbean.Utils.SafeMap

  @type identity_strength :: :strong | :weak | :ephemeral
  @type runtime_status :: :idle | :running | :awaiting_approval

  @type t :: %{
          conversation_id: String.t() | nil,
          backend: String.t(),
          instance_id: String.t(),
          session_id: String.t() | nil,
          identity_strength: identity_strength(),
          cwd: String.t() | nil,
          model: String.t() | nil,
          reasoning_effort: String.t() | nil,
          capabilities: map(),
          status: runtime_status(),
          status_detail: String.t() | nil,
          active_run_id: String.t() | nil,
          pending_request: map() | nil,
          last_terminal_status: atom() | String.t() | nil,
          updated_at_ms: integer()
        }

  @doc "Return the normalized CLI harness binding for a conversation, or `nil`."
  @spec get(String.t() | nil) :: t() | nil
  def get(conversation_id) when is_binary(conversation_id) do
    raw =
      case Session.whereis(conversation_id) do
        pid when is_pid(pid) ->
          snapshot = Session.snapshot(conversation_id)
          extension = SafeMap.get_any(snapshot.extension_state, :cli_agent, "cli_agent") || %{}
          SafeMap.get_any(extension, :session, "session")

        _ ->
          nil
      end

    normalize(raw, conversation_id)
  catch
    :exit, _ -> nil
  end

  def get(_conversation_id), do: nil

  @doc "Upsert the CLI harness binding for a conversation."
  @spec put(String.t(), map() | keyword()) :: t()
  def put(conversation_id, attrs) when is_binary(conversation_id) do
    attrs_map = Map.new(attrs)
    incoming_backend = SafeMap.get_any(attrs_map, :backend, "backend")

    base =
      case get(conversation_id) do
        %{backend: ^incoming_backend} = existing when is_binary(incoming_backend) ->
          existing

        existing when is_nil(incoming_backend) and is_map(existing) ->
          existing

        _ ->
          %{}
      end

    merged =
      base
      |> Map.merge(attrs_map)
      |> Map.put(:conversation_id, conversation_id)
      |> Map.put(:updated_at_ms, System.system_time(:millisecond))

    binding = normalize(merged, conversation_id)

    if is_map(binding) do
      _ = Session.start_or_get(session_id: conversation_id)
      Session.update_extension_state(conversation_id, :cli_agent, :session, binding)
    end

    binding
  end

  @doc "Clear the persisted CLI harness binding for a conversation."
  @spec clear(String.t() | nil) :: :ok
  def clear(conversation_id) when is_binary(conversation_id) do
    Session.delete_extension_state(conversation_id, :cli_agent, :session)
    :ok
  end

  def clear(_conversation_id), do: :ok

  @doc "Record that a CLI turn has started for a conversation."
  @spec record_run_start(String.t(), String.t(), String.t(), keyword()) :: t()
  def record_run_start(conversation_id, backend, run_id, opts \\ [])
      when is_binary(conversation_id) and is_binary(backend) and is_binary(run_id) do
    session_id =
      case Keyword.get(opts, :session_id) do
        id when is_binary(id) and id != "" -> id
        _ -> resumable_session_id(conversation_id, backend, opts)
      end

    put(conversation_id, %{
      backend: backend,
      instance_id: Keyword.get(opts, :instance_id, backend),
      session_id: session_id,
      cwd: Keyword.get(opts, :cwd),
      model: Keyword.get(opts, :model),
      reasoning_effort: Keyword.get(opts, :reasoning_effort),
      active_run_id: run_id,
      status: :running,
      status_detail: nil,
      pending_request: nil
    })
  end

  @doc "Record the native CLI session returned by `start_session/1` or `send_message/3`."
  @spec record_session(String.t() | nil, CliSession.t(), keyword()) :: t() | nil
  def record_session(conversation_id, session, opts \\ [])

  def record_session(conversation_id, %CliSession{} = session, opts)
      when is_binary(conversation_id) do
    if is_binary(session.backend) and is_binary(session.session_id) and session.session_id != "" do
      put(conversation_id, %{
        backend: session.backend,
        instance_id: Keyword.get(opts, :instance_id, session.backend),
        session_id: session.session_id,
        cwd: session.cwd || Keyword.get(opts, :cwd),
        model: Keyword.get(opts, :model),
        reasoning_effort: Keyword.get(opts, :reasoning_effort),
        identity_strength:
          Keyword.get(opts, :identity_strength) ||
            default_identity_strength(session.backend, session.session_id)
      })
    else
      get(conversation_id)
    end
  end

  def record_session(_conversation_id, _session, _opts), do: nil

  @doc "Record a fine-grained CLI working status detail during an active run."
  @spec record_status(String.t() | nil, String.t() | nil, String.t() | nil) :: t() | nil
  def record_status(conversation_id, run_id, detail)
      when is_binary(conversation_id) and is_binary(detail) and detail != "" do
    case get(conversation_id) do
      %{active_run_id: active_run_id} = binding
      when is_nil(run_id) or is_nil(active_run_id) or active_run_id == run_id ->
        put(conversation_id, %{
          backend: binding.backend,
          status_detail: detail
        })

      _ ->
        nil
    end
  end

  def record_status(_conversation_id, _run_id, _detail), do: nil

  @doc "Record that the active CLI run suspended on an approval or question."
  @spec record_awaiting(String.t(), String.t(), :permission | :ask_user, map(), String.t() | nil) ::
          t() | nil
  def record_awaiting(conversation_id, run_id, kind, meta, batch_id \\ nil)
      when is_binary(conversation_id) and is_binary(run_id) and kind in [:permission, :ask_user] and
             is_map(meta) do
    case get(conversation_id) do
      %{backend: backend} ->
        pending_request = %{
          kind: kind,
          request_id: SafeMap.get_any(meta, :id, "id") || "cli-#{kind}",
          batch_id: batch_id,
          tools: SafeMap.get_any(meta, :tools, "tools") || [],
          options: SafeMap.get_any(meta, :options, "options") || [],
          questions: SafeMap.get_any(meta, :questions, "questions") || []
        }

        put(conversation_id, %{
          backend: backend,
          active_run_id: run_id,
          status: :awaiting_approval,
          status_detail: "Waiting for approval",
          pending_request: pending_request
        })

      nil ->
        nil
    end
  end

  @doc "Record that a suspended CLI run resumed after user decision."
  @spec record_resumed(String.t(), String.t()) :: t() | nil
  def record_resumed(conversation_id, run_id)
      when is_binary(conversation_id) and is_binary(run_id) do
    case get(conversation_id) do
      %{backend: backend} ->
        put(conversation_id, %{
          backend: backend,
          active_run_id: run_id,
          status: :running,
          status_detail: nil,
          pending_request: nil
        })

      nil ->
        nil
    end
  end

  @doc "Record that the CLI run finished, keeping the native session id for later turns."
  @spec record_run_end(String.t(), String.t() | nil, atom() | String.t()) :: t() | nil
  def record_run_end(conversation_id, run_id, terminal_status)
      when is_binary(conversation_id) do
    case get(conversation_id) do
      %{backend: backend, active_run_id: active_run_id}
      when is_nil(run_id) or is_nil(active_run_id) or active_run_id == run_id ->
        put(conversation_id, %{
          backend: backend,
          active_run_id: nil,
          status: :idle,
          status_detail: nil,
          pending_request: nil,
          last_terminal_status: terminal_status
        })

      other ->
        other
    end
  end

  @doc """
  Return a validated native `session_id` only when the conversation's binding
  belongs to the same `backend`, supports session resumption, is not ephemeral,
  and has a compatible working directory.
  """
  @spec resumable_session_id(String.t() | nil, String.t() | nil, keyword()) :: String.t() | nil
  def resumable_session_id(conversation_id, backend, opts \\ [])

  def resumable_session_id(conversation_id, backend, opts)
      when is_binary(conversation_id) and is_binary(backend) and backend != "" do
    capabilities = capabilities_for(backend)

    binding =
      get(conversation_id) ||
        normalize(Keyword.get(opts, :fallback), conversation_id)

    with true <- Map.get(capabilities, :session_resume, true) != false,
         %{
           backend: ^backend,
           session_id: session_id,
           identity_strength: strength,
           cwd: bound_cwd
         }
         when is_binary(session_id) and session_id != "" and strength != :ephemeral <- binding,
         true <- cwd_compatible?(bound_cwd, Keyword.get(opts, :cwd)) do
      session_id
    else
      _ -> nil
    end
  end

  def resumable_session_id(_conversation_id, _backend, _opts), do: nil

  @doc "Normalize a raw binding map (atom or string keys) into `t()`."
  @spec normalize(term(), String.t() | nil) :: t() | nil
  def normalize(raw, conversation_id \\ nil)

  def normalize(raw, conversation_id) when is_map(raw) do
    backend = SafeMap.get_any(raw, :backend, "backend")

    if is_binary(backend) and backend != "" do
      session_id = SafeMap.get_any(raw, :session_id, "session_id")

      capabilities =
        capabilities_for(backend, SafeMap.get_any(raw, :capabilities, "capabilities"))

      strength =
        raw
        |> SafeMap.get_any(:identity_strength, "identity_strength")
        |> normalize_strength(backend, session_id, capabilities)

      %{
        conversation_id:
          conversation_id || SafeMap.get_any(raw, :conversation_id, "conversation_id"),
        backend: backend,
        instance_id: SafeMap.get_any(raw, :instance_id, "instance_id") || backend,
        session_id: if(is_binary(session_id) and session_id != "", do: session_id),
        identity_strength: strength,
        cwd: SafeMap.get_any(raw, :cwd, "cwd"),
        model: SafeMap.get_any(raw, :model, "model"),
        reasoning_effort: SafeMap.get_any(raw, :reasoning_effort, "reasoning_effort"),
        capabilities: capabilities,
        status: normalize_status(SafeMap.get_any(raw, :status, "status")),
        status_detail: SafeMap.get_any(raw, :status_detail, "status_detail"),
        active_run_id: SafeMap.get_any(raw, :active_run_id, "active_run_id"),
        pending_request: SafeMap.get_any(raw, :pending_request, "pending_request"),
        last_terminal_status: SafeMap.get_any(raw, :last_terminal_status, "last_terminal_status"),
        updated_at_ms:
          SafeMap.get_any(raw, :updated_at_ms, "updated_at_ms") ||
            System.system_time(:millisecond)
      }
    end
  end

  def normalize(_raw, _conversation_id), do: nil

  defp capabilities_for(backend, fallback \\ nil) when is_binary(backend) do
    case Registry.capabilities(backend) do
      {:ok, caps} ->
        caps

      {:error, _} when is_map(fallback) ->
        fallback

      {:error, _} ->
        %{
          attachments: false,
          approvals: false,
          ask_user: false,
          reasoning: false,
          session_resume: true,
          streaming: true,
          model_list: true,
          interrupt: true
        }
    end
  end

  defp default_identity_strength(backend, session_id) do
    caps = capabilities_for(backend)

    cond do
      Map.get(caps, :session_resume, true) == false -> :ephemeral
      is_binary(session_id) and session_id != "" -> :strong
      true -> :weak
    end
  end

  defp normalize_strength(strength, backend, session_id, capabilities) do
    cond do
      Map.get(capabilities, :session_resume, true) == false ->
        :ephemeral

      strength in [:strong, "strong"] ->
        :strong

      strength in [:weak, "weak"] ->
        :weak

      strength in [:ephemeral, "ephemeral"] ->
        :ephemeral

      true ->
        default_identity_strength(backend, session_id)
    end
  end

  defp normalize_status(status) when status in [:running, "running"], do: :running

  defp normalize_status(status)
       when status in [:awaiting_approval, "awaiting_approval"],
       do: :awaiting_approval

  defp normalize_status(_), do: :idle

  defp cwd_compatible?(bound_cwd, requested_cwd)
       when is_binary(bound_cwd) and bound_cwd != "" and is_binary(requested_cwd) and
              requested_cwd != "" do
    Path.expand(bound_cwd) == Path.expand(requested_cwd)
  end

  defp cwd_compatible?(_bound_cwd, _requested_cwd), do: true
end
