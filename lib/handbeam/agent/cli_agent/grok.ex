defmodule Handbeam.Agent.CliAgent.Grok do
  @moduledoc """
  Grok loop owner.

  Grok owns its tools, permissions, and session through ACP over stdio.
  This module is not a `Handbeam.Agent.Provider`. ACP stays in the Grok codec.
  Callers see only `Handbeam.Agent.CliAgent` events.

  Authentication is the host's existing `grok` login. It is inherited by the
  child process and is never written to code, logs, or config.
  """

  @behaviour Handbeam.Agent.CliAgent

  alias Handbeam.Agent.CliAgent.Grok.{Codec, Session, Transport}
  alias Handbeam.Agent.CliAgent.Session, as: CliSession
  alias Handbeam.Host
  alias Handbeam.Platform.WorkspaceEnvironment

  @id "grok"
  @executable "grok"

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
      model_change: :next_start,
      approval_survives_restart: false,
      structured_questions: false,
      mcp_tools: false,
      policy_executor: :native
    }
  end

  @impl true
  def list_models(opts \\ []) when is_list(opts) do
    with :ok <- ensure_available(opts),
         {:ok, text} <- Transport.models(opts) do
      Codec.models_from_text(text)
    end
  end

  @impl true
  def start_session(opts) when is_list(opts) do
    with :ok <- ensure_available(opts),
         :ok <- validate_start(opts),
         {:ok, handle} <- Session.start(opts) do
      {:ok, public_session(handle)}
    end
  end

  @impl true
  def send_message(%CliSession{backend: @id, private: private}, text, on_event)
      when is_binary(text) and is_function(on_event, 1) do
    case Session.send_message(private.owner, text, on_event, Map.get(private, :decision)) do
      {:ok, handle, events} -> {:ok, public_session(handle), events}
      {:error, reason} -> {:error, reason}
    end
  end

  def send_message(%CliSession{}, _text, _on_event), do: {:error, :unknown_backend}

  @impl true
  def interrupt(%CliSession{backend: @id, private: %{owner: owner}}), do: Session.interrupt(owner)
  def interrupt(%CliSession{}), do: {:error, :unknown_backend}

  @impl true
  def update_model(%CliSession{backend: @id}, opts) when is_list(opts) do
    if Keyword.get(opts, :model) || Keyword.get(opts, :reasoning_effort) do
      {:error, :apply_on_next_start}
    else
      {:error, :model_required}
    end
  end

  def update_model(%CliSession{}, _opts), do: {:error, :unknown_backend}

  @impl true
  def stop_session(%CliSession{backend: @id, private: %{owner: owner}}), do: Session.stop(owner)
  def stop_session(%CliSession{}), do: :ok

  @doc """
  Attach an explicit permission decision for the next `send_message/3`.

  `:permission` is an `optionId` Grok already offered. Without it, a
  permission request stops the turn. This never approves by default.
  """
  @spec put_decision(CliSession.t(), {:permission, String.t()}) :: CliSession.t()
  def put_decision(%CliSession{backend: @id, private: private} = session, {:permission, selected})
      when is_binary(selected) do
    %{session | private: Map.put(private, :decision, {:permission, selected})}
  end

  defp public_session(handle) do
    %CliSession{
      backend: @id,
      cwd: handle.cwd,
      session_id: handle.session_id,
      pid: handle.owner,
      private: %{owner: handle.owner}
    }
  end

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

  defp validate_binary_opt(opts, key) do
    case Keyword.get(opts, key) do
      nil -> :ok
      value when is_binary(value) and value != "" -> :ok
      _ -> {:error, {:invalid_option, key}}
    end
  end
end
