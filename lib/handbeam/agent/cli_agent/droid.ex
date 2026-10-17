defmodule Handbeam.Agent.CliAgent.Droid do
  @moduledoc """
  Factory Droid loop owner.

  Droid owns its tools, permissions, MCP, and session. This module is not a
  `Handbeam.Agent.Provider`. The JSON-RPC codec lives here; callers see only
  `Handbeam.Agent.CliAgent` events.

  Authentication is the host's existing Factory login or `FACTORY_API_KEY`.
  The key is inherited by the child process and is never written to code,
  logs, or config.
  """

  @behaviour Handbeam.Agent.CliAgent

  alias Handbeam.Agent.CliAgent.Droid.{Codec, Session, Transport}
  alias Handbeam.Agent.CliAgent.Session, as: CliSession
  alias Handbeam.Host
  alias Handbeam.Platform.WorkspaceEnvironment

  @id "droid"
  @executable "droid"
  @auto_levels [:low, :medium, :high]

  @impl true
  def id, do: @id

  @impl true
  def available? do
    Host.shell?() and not is_nil(System.find_executable(@executable))
  end

  @impl true
  def capabilities do
    %{
      attachments: false,
      session_resume: :strong,
      native_turn_ids: :strong,
      interrupt: true,
      steering: false,
      model_change: :mid_session_ready,
      approval_survives_restart: false,
      structured_questions: true,
      mcp_tools: true,
      policy_executor: :native
    }
  end

  @impl true
  def list_models(opts \\ []) when is_list(opts) do
    with :ok <- ensure_available(opts),
         {:ok, session} <- Session.start(list_models_opts(opts)) do
      try do
        Session.list_models(session, opts)
      after
        Session.stop(session.pid)
      end
    end
  end

  @impl true
  def start_session(opts) when is_list(opts) do
    with :ok <- ensure_available(opts),
         :ok <- validate_start(opts) do
      Session.start(opts)
    end
  end

  @impl true
  def send_message(%CliSession{backend: @id, private: private}, text, on_event)
      when is_binary(text) and is_function(on_event, 1) do
    Session.send_message(private.owner, text, on_event, Map.get(private, :decision))
  end

  def send_message(%CliSession{}, _text, _on_event), do: {:error, :unknown_backend}

  @impl true
  def interrupt(%CliSession{backend: @id, private: %{owner: owner}}) do
    Session.interrupt(owner)
  end

  def interrupt(%CliSession{}), do: {:error, :unknown_backend}

  @impl true
  def update_model(%CliSession{backend: @id, private: %{owner: owner}} = session, opts)
      when is_list(opts) do
    case Session.update_model(owner, opts) do
      :ok -> {:ok, session}
      {:error, reason} -> {:error, reason}
    end
  end

  def update_model(%CliSession{}, _opts), do: {:error, :unknown_backend}

  @impl true
  def stop_session(%CliSession{backend: @id, private: %{owner: owner}}) do
    Session.stop(owner)
  end

  def stop_session(%CliSession{}), do: :ok

  @doc false
  def executable, do: @executable

  defp ensure_available(opts) do
    cond do
      not Host.shell?() ->
        {:error, :not_available}

      true ->
        case executable_path(opts) do
          {:ok, _path} -> :ok
          {:error, :not_found} -> {:error, :not_available}
          {:error, _reason} = error -> error
        end
    end
  end

  defp executable_path(opts) do
    case Keyword.get(opts, :executable) do
      path when is_binary(path) and path != "" -> {:ok, path}
      _ -> WorkspaceEnvironment.find_executable(@executable, opts[:cwd])
    end
  end

  defp validate_start(opts) do
    with :ok <- require_cwd(opts),
         :ok <- validate_auto(Keyword.get(opts, :auto)),
         :ok <- validate_binary_opt(opts, :model),
         :ok <- validate_binary_opt(opts, :reasoning_effort) do
      validate_binary_opt(opts, :session_id)
    end
  end

  defp require_cwd(opts) do
    case Keyword.get(opts, :cwd) do
      cwd when is_binary(cwd) and cwd != "" -> :ok
      _ -> {:error, :cwd_required}
    end
  end

  defp validate_auto(nil), do: :ok
  defp validate_auto(level) when level in @auto_levels, do: :ok
  defp validate_auto(_), do: {:error, :invalid_auto}

  defp validate_binary_opt(opts, key) do
    case Keyword.get(opts, key) do
      nil -> :ok
      value when is_binary(value) and value != "" -> :ok
      _ -> {:error, {:invalid_option, key}}
    end
  end

  defp list_models_opts(opts) do
    cwd = Keyword.get(opts, :cwd) || File.cwd!()

    opts
    |> Keyword.put(:cwd, cwd)
    |> Keyword.put(:purpose, :list_models)
  end

  @doc """
  Attach an explicit permission or ask-user decision to a session copy.

  The decision is consumed by the next `send_message/3`. The event callback
  may also return `{:permission, selected}` or `{:ask_user, answers}`.
  Without either, a server request stops the turn. This never approves by
  default.

  `:permission` is a `selectedOption` Droid already offered.
  `:ask_user` is a list of `%{"index" => n, "question" => q, "answer" => a}`.
  """
  @spec put_decision(CliSession.t(), {:permission, String.t()} | {:ask_user, [map()]}) ::
          CliSession.t()
  def put_decision(%CliSession{backend: @id, private: private} = session, decision)
      when is_tuple(decision) do
    %{session | private: Map.put(private, :decision, decision)}
  end

  @doc false
  def codec, do: Codec

  @doc false
  def transport, do: Transport
end
