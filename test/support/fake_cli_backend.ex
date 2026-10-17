defmodule Handbean.Agent.CliAgentTest.FakeBackend do
  @moduledoc false
  @behaviour Handbean.Agent.CliAgent

  alias Handbean.Agent.CliAgent.Session

  @impl true
  def id, do: "fake-cli"

  @impl true
  def available?, do: true

  @impl true
  def list_models(_opts) do
    {:ok, [%{id: "fake-model", display_name: "Fake", reasoning_levels: ["low"]}]}
  end

  @impl true
  def start_session(opts) do
    session_id = Keyword.get(opts, :session_id) || "fake-new"

    {:ok,
     %Session{
       backend: id(),
       cwd: Keyword.get(opts, :cwd, "."),
       session_id: session_id,
       private: %{resumed: Keyword.get(opts, :session_id)}
     }}
  end

  @impl true
  def send_message(session, text, on_event) do
    if pid = Application.get_env(:handbean, :fake_cli_notify),
      do: send(pid, {:fake_cli_turn, text, session})

    cond do
      text == "slow" ->
        slow_turn(session, on_event, false)

      text == "streaming-slow" ->
        slow_turn(session, on_event, true)

      text == "status-slow" ->
        on_event.({:status, %{state: "compacting"}})
        slow_turn(session, on_event, false)

      text == "ordered-cross-sender" ->
        cross_sender_turn(session, on_event)

      text == "return-error" ->
        {:error, :fake_failure}

      text == "crash" ->
        raise "fake cli crash"

      String.contains?(text, "need-permission") and is_nil(session.private[:decision]) ->
        request =
          {:permission_request,
           %{
             id: "perm-1",
             tools: [%{name: "Edit", id: "t1", input: %{"file_path" => "lib/demo.ex"}}],
             options: [
               %{"label" => "Once", "value" => "proceed_once"},
               %{"label" => "Cancel", "value" => "cancel"}
             ]
           }}

        on_event.(request)
        {:ok, session, [request]}

      true ->
        send_text(session, on_event)
    end
  end

  defp slow_turn(session, on_event, streaming?) do
    if streaming?, do: on_event.({:text_delta, "partial"})

    if pid = Application.get_env(:handbean, :fake_cli_notify),
      do: send(pid, {:fake_cli_waiting, self()})

    receive do
      :finish_fake_cli -> send_text(session, on_event)
    end
  end

  defp cross_sender_turn(session, on_event) do
    caller = self()
    notify = Application.get_env(:handbean, :fake_cli_notify)

    spawn(fn ->
      if notify, do: send(notify, {:fake_cli_event_ready, self()})

      receive do
        :emit_cli_events -> :ok
      end

      events = [
        {:text_delta, "ordered"},
        {:tool_start, %{id: "ordered-tool", name: "Read", input: %{path: "a.ex"}}},
        {:tool_end, %{id: "ordered-tool", name: "Read", output: "done"}},
        {:turn_end, %{stop_reason: :end_turn, session_id: session.session_id}}
      ]

      Enum.each(events, on_event)
      if notify, do: send(notify, :fake_cli_event_callbacks_returned)
      send(caller, {:cross_sender_events, events})
    end)

    receive do
      {:cross_sender_events, events} -> {:ok, session, events}
    end
  end

  defp send_text(session, on_event) do
    event = {:text_delta, "fake"}
    on_event.(event)
    done = {:turn_end, %{stop_reason: :end_turn, session_id: session.session_id}}
    on_event.(done)
    {:ok, session, [event, done]}
  end

  @impl true
  def interrupt(%Session{}), do: :ok

  @impl true
  def update_model(session, _opts), do: {:ok, session}

  @impl true
  def stop_session(%Session{}), do: :ok
end

defmodule Handbean.Agent.CliAgentTest.AttachmentBackend do
  @moduledoc false
  @behaviour Handbean.Agent.CliAgent

  alias Handbean.Agent.CliAgent.Session

  @impl true
  def id, do: "attachment-cli"

  @impl true
  def available?, do: true

  @impl true
  def list_models(_opts) do
    {:ok, [%{id: "attachment-model", display_name: "Attachment", reasoning_levels: []}]}
  end

  @impl true
  def capabilities, do: %{attachments: true}

  @impl true
  def start_session(opts) do
    {:ok,
     %Session{
       backend: id(),
       cwd: Keyword.get(opts, :cwd, "."),
       session_id: "attachment-session"
     }}
  end

  @impl true
  def send_message(session, input, on_event) do
    send(Application.fetch_env!(:handbean, :fake_cli_notify), {:attachment_cli_input, input})
    done = {:turn_end, %{stop_reason: :end_turn, session_id: session.session_id}}
    on_event.(done)
    {:ok, session, [done]}
  end

  @impl true
  def interrupt(_session), do: :ok

  @impl true
  def update_model(session, _opts), do: {:ok, session}

  @impl true
  def stop_session(_session), do: :ok
end
