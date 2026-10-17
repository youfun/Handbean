defmodule HandbeamWeb.WorkspaceLive.CliSelection do
  @moduledoc """
  Composer choice between Handbeam's own loop and an external CLI loop.

  No CLI selected keeps `ModelSelection` and `Handbeam.Agent.Turn`. A selected
  CLI replaces the model list with that CLI's own models. It never falls back
  to the Handbeam provider catalog.
  """

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [start_async: 3]

  alias Handbeam.Agent.CliAgent.Registry
  alias Handbeam.Host

  @handbeam ""

  @doc "Assignable CLI backends. A missing executable is omitted, not installed."
  @spec selectable() :: [%{id: String.t(), available: boolean()}]
  def selectable do
    if Host.shell?() do
      Registry.selectable()
      |> Enum.filter(& &1.available)
      |> Enum.map(&%{id: &1.id})
    else
      []
    end
  end

  @doc "Mount assigns. Handbeam remains selected."
  @spec boot() :: map()
  def boot do
    %{
      available_clis: selectable(),
      selected_cli: nil,
      cli_models_error: nil,
      cli_models_loading: false,
      cli_models_revision: 0,
      handbeam_models: nil,
      handbeam_selected_model: nil,
      handbeam_reasoning_level: nil,
      handbeam_reasoning_levels: nil,
      cli_sessions: %{},
      cli_choices: %{}
    }
  end

  @spec assign_boot(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_boot(socket) do
    assign(socket, boot())
  end

  @doc "Whether this turn's loop owner is a CLI rather than Handbeam."
  @spec cli_selected?(map()) :: boolean()
  def cli_selected?(assigns) when is_map(assigns) do
    is_binary(assigns[:selected_cli]) and assigns[:selected_cli] != ""
  end

  @doc """
  Select Handbeam (`nil` or `\"\"`) or a CLI id.

  Selecting a CLI loads that CLI's models. `:models_unavailable` is shown and
  does not reuse Handbeam's catalog.
  """
  @spec select(Phoenix.LiveView.Socket.t(), String.t() | nil) :: Phoenix.LiveView.Socket.t()
  def select(socket, cli) when cli in [nil, ""] do
    socket
    |> forget_current()
    |> restore_handbeam()
    |> remember_current()
  end

  def select(socket, cli) when is_binary(cli) do
    if Enum.any?(socket.assigns.available_clis, &(&1.id == cli)) do
      socket
      |> forget_current()
      |> remember_handbeam()
      |> assign(:selected_cli, cli)
      |> load_cli_models_async(cli)
      |> remember_current()
    else
      socket
    end
  end

  @spec select_model(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def select_model(socket, model) when is_binary(model) do
    if cli_selected?(socket.assigns) and
         Enum.any?(socket.assigns.available_models, &(&1.id == model)) do
      entry = Enum.find(socket.assigns.available_models, &(&1.id == model))

      socket
      |> assign(:selected_model, model)
      |> assign_reasoning(entry)
      |> remember_current()
    else
      socket
    end
  end

  @doc "Options for `Handbeam.Agent.CliAgent.Run.turn/2`. Nil when Handbeam owns the turn."
  @spec run_opts(Phoenix.LiveView.Socket.t(), String.t()) :: keyword() | nil
  def run_opts(socket, conversation_id) do
    cwd = workspace_cwd(socket)

    if cli_selected?(socket.assigns) and is_binary(socket.assigns.selected_model) and
         is_binary(cwd) do
      [
        backend: socket.assigns.selected_cli,
        cwd: cwd,
        model: socket.assigns.selected_model,
        reasoning_effort: socket.assigns.selected_reasoning_level,
        conversation_id: conversation_id,
        session_id: resumed_session_id(socket, conversation_id)
      ]
    end
  end

  @doc """
  Remember this conversation's CLI choice, then show Handbeam controls.

  Conversation switching reloads the Handbeam catalog. Call `restore_current/1`
  after that reload so the destination conversation gets its own CLI choice back.
  """
  @spec prepare_switch(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def prepare_switch(socket) do
    socket
    |> remember_current()
    |> restore_handbeam()
  end

  @doc "Show the current conversation's CLI choice after a Handbeam model reload."
  @spec restore_current(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def restore_current(socket) do
    case choice_for(socket, socket.assigns[:current_conversation_id]) do
      %{cli: cli} = choice when is_binary(cli) and cli != "" ->
        if cli_available?(socket, cli) do
          socket
          |> remember_handbeam()
          |> apply_choice(choice)
        else
          socket
        end

      _ ->
        socket
    end
  end

  @doc "Keep the in-memory CLI choice aligned with the controls the user is looking at."
  @spec remember_current(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def remember_current(socket) do
    id = socket.assigns[:current_conversation_id]
    choices = socket.assigns[:cli_choices] || %{}

    choices =
      cond do
        not is_binary(id) ->
          choices

        choice = choice_from_assigns(socket.assigns) ->
          Map.put(choices, id, choice)

        true ->
          Map.delete(choices, id)
      end

    assign(socket, :cli_choices, choices)
  end

  @doc "Form value for the CLI picker. Empty string means Handbeam."
  @spec form_value(String.t() | nil) :: String.t()
  def form_value(nil), do: @handbeam
  def form_value(cli), do: cli

  @doc "Composer copy when a CLI cannot provide its own model list."
  @spec error_message(atom()) :: String.t()
  def error_message(:models_unavailable), do: "This CLI cannot list models."
  def error_message(:empty), do: "This CLI has no selectable models."
  def error_message(_), do: "This CLI cannot list models."

  @doc "Remember a finished CLI session so the next message in this conversation can resume it."
  @spec remember_session(Phoenix.LiveView.Socket.t(), String.t(), String.t(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def remember_session(socket, conversation_id, backend, session_id)
      when is_binary(conversation_id) and is_binary(backend) and is_binary(session_id) do
    sessions = socket.assigns[:cli_sessions] || %{}
    sessions = Map.put(sessions, conversation_id, %{backend: backend, session_id: session_id})

    Handbeam.PubSub.Session.update_extension_state(
      conversation_id,
      :cli_agent,
      :session,
      %{backend: backend, session_id: session_id}
    )

    assign(socket, :cli_sessions, sessions)
  end

  @doc "Drop a remembered CLI session. Used when the user switches loop owner."
  @spec forget_session(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def forget_session(socket, conversation_id) when is_binary(conversation_id) do
    sessions = socket.assigns[:cli_sessions] || %{}

    Handbeam.PubSub.Session.delete_extension_state(conversation_id, :cli_agent, :session)

    assign(socket, :cli_sessions, Map.delete(sessions, conversation_id))
  end

  defp resumed_session_id(socket, conversation_id) do
    selected = socket.assigns.selected_cli

    case socket.assigns[:cli_sessions][conversation_id] || persisted_session(conversation_id) do
      %{backend: ^selected, session_id: session_id} when is_binary(session_id) -> session_id
      _ -> nil
    end
  end

  defp persisted_session(conversation_id) do
    session =
      case Handbeam.PubSub.Session.whereis(conversation_id) do
        pid when is_pid(pid) ->
          snapshot = Handbeam.PubSub.Session.snapshot(conversation_id)

          extension =
            Handbeam.Utils.SafeMap.get_any(snapshot.extension_state, :cli_agent, "cli_agent") ||
              %{}

          Handbeam.Utils.SafeMap.get_any(extension, :session, "session")

        _ ->
          nil
      end

    normalize_persisted_session(session)
  end

  defp normalize_persisted_session(session) when is_map(session) do
    backend = Handbeam.Utils.SafeMap.get_any(session, :backend, "backend")
    session_id = Handbeam.Utils.SafeMap.get_any(session, :session_id, "session_id")

    if is_binary(backend) and is_binary(session_id),
      do: %{backend: backend, session_id: session_id}
  end

  defp normalize_persisted_session(_session), do: nil

  @doc false
  def finish_model_load(socket, cli, revision, result) do
    if socket.assigns.selected_cli == cli and socket.assigns.cli_models_revision == revision do
      socket
      |> assign(:cli_models_loading, false)
      |> apply_cli_models(result)
      |> remember_current()
    else
      stash_load_result(socket, cli, revision, result)
    end
  end

  defp choice_for(socket, id) when is_binary(id) do
    choices = socket.assigns[:cli_choices] || %{}
    choices[id]
  end

  defp choice_for(_socket, _id), do: nil

  defp cli_available?(socket, cli) do
    Enum.any?(socket.assigns[:available_clis] || [], &(&1.id == cli))
  end

  defp choice_from_assigns(assigns) do
    if cli_selected?(assigns) do
      %{
        cli: assigns.selected_cli,
        models: assigns[:available_models] || [],
        model: assigns[:selected_model],
        levels: assigns[:available_reasoning_levels] || [],
        reasoning: assigns[:selected_reasoning_level],
        error: assigns[:cli_models_error],
        loading: assigns[:cli_models_loading] == true,
        revision: assigns[:cli_models_revision] || 0
      }
    end
  end

  defp apply_choice(socket, choice) do
    assign(socket, %{
      selected_cli: choice.cli,
      available_models: choice.models,
      selected_model: choice.model,
      available_reasoning_levels: choice.levels,
      selected_reasoning_level: choice.reasoning,
      cli_models_error: choice.error,
      cli_models_loading: choice.loading,
      cli_models_revision: choice.revision
    })
  end

  defp stash_load_result(socket, cli, revision, result) do
    choices = socket.assigns[:cli_choices] || %{}

    choices =
      Map.new(choices, fn
        {id, %{cli: ^cli, revision: ^revision, loading: true} = choice} ->
          {id, completed_choice(choice, result)}

        other ->
          other
      end)

    assign(socket, :cli_choices, choices)
  end

  defp completed_choice(choice, {:ok, []}) do
    %{choice | models: [], model: nil, levels: [], reasoning: nil, loading: false, error: :empty}
  end

  defp completed_choice(choice, {:ok, models}) do
    model =
      if choice.model && Enum.any?(models, &(&1.id == choice.model)),
        do: choice.model,
        else: hd(models).id

    entry = Enum.find(models, &(&1.id == model)) || %{}
    levels = Map.get(entry, :reasoning_levels, [])

    reasoning =
      if choice.reasoning in levels, do: choice.reasoning, else: List.first(levels)

    %{
      choice
      | models: models,
        model: model,
        levels: levels,
        reasoning: reasoning,
        loading: false,
        error: nil
    }
  end

  defp completed_choice(choice, {:error, :not_available}) do
    %{choice | cli: nil, loading: false, error: nil}
  end

  defp completed_choice(choice, {:error, _reason}) do
    %{
      choice
      | models: [],
        model: nil,
        levels: [],
        reasoning: nil,
        loading: false,
        error: :models_unavailable
    }
  end

  defp load_cli_models_async(socket, cli) do
    revision = socket.assigns.cli_models_revision + 1
    cwd = workspace_cwd(socket)

    socket
    |> assign(
      available_models: [],
      selected_model: nil,
      available_reasoning_levels: [],
      selected_reasoning_level: nil,
      cli_models_error: nil,
      cli_models_loading: true,
      cli_models_revision: revision
    )
    |> start_async({:cli_models, cli, revision}, fn -> Registry.list_models(cli, cwd: cwd) end)
  end

  defp apply_cli_models(socket, result) do
    case result do
      {:ok, []} ->
        socket
        |> assign(:available_models, [])
        |> assign(:selected_model, nil)
        |> assign(:available_reasoning_levels, [])
        |> assign(:selected_reasoning_level, nil)
        |> assign(:cli_models_error, :empty)

      {:ok, models} ->
        first = hd(models)

        socket
        |> assign(:available_models, models)
        |> assign(:selected_model, first.id)
        |> assign(:cli_models_error, nil)
        |> assign_reasoning(first)

      {:error, :models_unavailable} ->
        socket
        |> assign(:available_models, [])
        |> assign(:selected_model, nil)
        |> assign(:available_reasoning_levels, [])
        |> assign(:selected_reasoning_level, nil)
        |> assign(:cli_models_error, :models_unavailable)

      {:error, :not_available} ->
        restore_handbeam(socket)

      {:error, _reason} ->
        socket
        |> assign(:available_models, [])
        |> assign(:selected_model, nil)
        |> assign(:available_reasoning_levels, [])
        |> assign(:selected_reasoning_level, nil)
        |> assign(:cli_models_error, :models_unavailable)
    end
  end

  defp assign_reasoning(socket, model) do
    levels = Map.get(model, :reasoning_levels, [])
    selected = socket.assigns[:selected_reasoning_level]

    selected = if selected in levels, do: selected, else: List.first(levels)

    socket
    |> assign(:available_reasoning_levels, levels)
    |> assign(:selected_reasoning_level, selected)
  end

  defp remember_handbeam(socket) do
    if cli_selected?(socket.assigns) do
      socket
    else
      assign(socket, %{
        handbeam_models: socket.assigns.available_models,
        handbeam_selected_model: socket.assigns.selected_model,
        handbeam_reasoning_level: socket.assigns.selected_reasoning_level,
        handbeam_reasoning_levels: socket.assigns.available_reasoning_levels
      })
    end
  end

  defp restore_handbeam(socket) do
    models = socket.assigns[:handbeam_models] || socket.assigns.available_models

    socket
    |> assign(:selected_cli, nil)
    |> assign(:cli_models_error, nil)
    |> assign(:cli_models_loading, false)
    |> assign(:available_models, models)
    |> assign(
      :selected_model,
      socket.assigns[:handbeam_selected_model] || socket.assigns.selected_model
    )
    |> assign(
      :available_reasoning_levels,
      socket.assigns[:handbeam_reasoning_levels] || socket.assigns.available_reasoning_levels
    )
    |> assign(
      :selected_reasoning_level,
      socket.assigns[:handbeam_reasoning_level] || socket.assigns.selected_reasoning_level
    )
  end

  defp forget_current(socket) do
    case socket.assigns[:current_conversation_id] do
      id when is_binary(id) -> forget_session(socket, id)
      _ -> socket
    end
  end

  defp workspace_cwd(socket) do
    if socket.assigns[:chat_scope] == :free,
      do: File.cwd!(),
      else: socket.assigns[:workspace_root]
  end
end
