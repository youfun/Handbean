defmodule Handbean.Agent.CliAgent do
  @moduledoc """
  Loop owner for an external CLI agent.

  One turn has one loop owner. `Handbean.Agent.Turn` remains the default: it
  calls a Provider and Handbean executes tools. A CLI session is the other
  owner. Handbean opens the session, sends the user message, and projects
  normalized events. It does not call `Handbean.Agent.Provider`, attach
  Handbean tool definitions, or re-execute the CLI's tool events.

  Backends implement this behaviour. Callers depend on `id/0` and the
  normalized events below, never on a backend's wire protocol.
  """

  alias Handbean.Agent.CliAgent.{Event, Session}

  @type model :: %{
          id: String.t(),
          display_name: String.t(),
          reasoning_levels: [String.t()]
        }

  @type capabilities :: %{
          optional(:attachments) => boolean(),
          optional(:approvals) => boolean(),
          optional(:ask_user) => boolean(),
          optional(:reasoning) => boolean(),
          optional(:session_resume) => boolean(),
          optional(:streaming) => boolean(),
          optional(:model_list) => boolean(),
          optional(:interrupt) => boolean(),
          optional(atom()) => term()
        }

  @type start_opts :: keyword()
  @type event :: Event.t()
  @type input :: String.t() | Handbean.Agent.Message.t()

  @doc "Stable backend id, such as `\"droid\"`."
  @callback id() :: String.t()

  @doc "Whether the executable is on PATH. Must not spawn it."
  @callback available?() :: boolean()

  @doc """
  Selectable models owned by this CLI.

  Returns `{:error, :models_unavailable}` when this build cannot list models.
  Does not read Handbean's provider catalog.
  """
  @callback list_models(keyword()) :: {:ok, [model()]} | {:error, term()}

  @doc "Explicit capabilities exposed at the adapter boundary."
  @callback capabilities() :: capabilities()

  @doc """
  Start a long-lived session in a workspace cwd.

  Accepts `:model` and `:reasoning_effort`. The backend maps those onto its
  own flags. Also accepts `:session_id` to resume and `:auto` (`:low`,
  `:medium`, or `:high`) for an explicit autonomy override.
  """
  @callback start_session(start_opts()) :: {:ok, Session.t()} | {:error, term()}

  @doc """
  Send one user turn and stream normalized events until that turn completes.

  `on_event` receives each `Event.t()`. The return value is the same list.
  """
  @callback send_message(Session.t(), input(), (event() -> term())) ::
              {:ok, Session.t(), [event()]} | {:error, term()}

  @doc "Stop the current turn without killing the session, when the protocol supports it."
  @callback interrupt(Session.t()) :: :ok | {:error, term()}

  @doc """
  Change the CLI's own model for later turns.

  Applies immediately when the protocol supports a mid-session update.
  Otherwise returns `{:error, :apply_on_next_start}` and the caller passes
  the same options to the next `start_session/1`. Never a Provider switch.
  """
  @callback update_model(Session.t(), keyword()) :: {:ok, Session.t()} | {:error, term()}

  @doc "Close the process."
  @callback stop_session(Session.t()) :: :ok

  @optional_callbacks capabilities: 0
end
