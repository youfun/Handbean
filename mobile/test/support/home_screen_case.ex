defmodule HandbeanProbe.HomeScreenCase do
  @moduledoc false

  use Gettext, backend: HandbeanProbe.Gettext

  import ExUnit.Assertions
  import ExUnit.Callbacks
  import HandbeanProbe.ScreenSettle
  import Mob.ScreenCase

  alias HandbeanProbe.{HomeScreen, ModelSettings, PendingRequests}

  defmacro __using__(_opts) do
    quote do
      use Mob.ScreenCase, async: false
      use Gettext, backend: HandbeanProbe.Gettext

      import HandbeanProbe.HomeScreenCase
      import HandbeanProbe.ScreenSettle

      setup context do
        HandbeanProbe.HomeScreenCase.setup_home_screen(context)
      end
    end
  end

  defmodule UnavailableHistory do
    def page(_id, _opts), do: {:error, :unavailable}
  end

  defmodule ApprovalProvider do
    @behaviour Handbean.Agent.Provider
    alias Handbean.Agent.Message

    # With `provider_config: %{gate: pid}` every provider call first reports
    # `{:provider_turn, turn, self()}` to `pid` and waits for
    # `{:provider_continue, turn}`. Tests use it to order "rule written to disk"
    # before "next turn evaluates ToolPolicy" without sleeping.
    def complete(messages, _tools, config) do
      turn = Enum.count(messages, &(&1.role == :tool_result))
      wait_for_gate(config[:gate], turn)

      message =
        if turn < 2 do
          Message.tool_use([
            %{
              type: "tool_use",
              id: "approval-#{turn}",
              name: "write",
              input: %{"file_path" => "approval.txt", "content" => "write-#{turn}"}
            }
          ])
        else
          Message.assistant("approval finished")
        end

      {:ok,
       %{
         stop_reason: if(turn < 2, do: :tool_use, else: :end_turn),
         messages: [message],
         usage: %{input_tokens: 1, output_tokens: 1}
       }}
    end

    def stream(messages, tools, config, _callback), do: complete(messages, tools, config)

    defp wait_for_gate(gate, turn) when is_pid(gate) do
      send(gate, {:provider_turn, turn, self()})

      receive do
        {:provider_continue, ^turn} -> :ok
      after
        5_000 -> :ok
      end
    end

    defp wait_for_gate(_gate, _turn), do: :ok
  end

  defmodule ApprovalFileProvider do
    @behaviour Handbean.Agent.Provider
    alias Handbean.Agent.Message

    def complete(messages, _tools, _config) do
      if Enum.any?(messages, &(&1.role == :tool_result)) do
        {:ok,
         %{
           stop_reason: :end_turn,
           messages: [Message.assistant("file approval finished")],
           usage: %{input_tokens: 1, output_tokens: 1}
         }}
      else
        {:ok,
         %{
           stop_reason: :tool_use,
           messages: [
             Message.tool_use([
               %{
                 type: "tool_use",
                 id: "approval-file-0",
                 name: "open_file",
                 input: %{"path" => "approval.txt"}
               }
             ])
           ],
           usage: %{input_tokens: 1, output_tokens: 1}
         }}
      end
    end

    def stream(messages, tools, config, _callback), do: complete(messages, tools, config)
  end

  defmodule ProviderFixture do
    def init(owner), do: owner

    def call(conn, owner) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:provider_request, self(), Jason.decode!(body)})

      receive do
        :respond -> :ok
      after
        5_000 -> :ok
      end

      conn =
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_chunked(200)

      {:ok, conn} =
        Plug.Conn.chunk(
          conn,
          "data: " <>
            Jason.encode!(%{
              choices: [%{delta: %{content: "Native fixture"}, finish_reason: nil}]
            }) <> "\n\n"
        )

      # Hold the response open: the UI must expose this prefix BEFORE completion.
      receive do
        :finish -> :ok
      after
        5_000 -> :ok
      end

      reply =
        "data: " <>
          Jason.encode!(%{
            choices: [%{delta: %{content: " answer"}, finish_reason: nil}]
          }) <>
          "\n\n" <>
          "data: " <>
          Jason.encode!(%{choices: [%{delta: %{}, finish_reason: "stop"}]}) <>
          "\n\ndata: [DONE]\n\n"

      {:ok, conn} = Plug.Conn.chunk(conn, reply)
      conn
    end
  end

  def setup_home_screen(_context) do
    Handbean.Repo.delete_all(Handbean.Storage.Conversation)

    dir = Path.join(System.tmp_dir!(), "native_chat_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    host = Application.get_env(:handbean, :host)
    previous_platform = Application.get_env(:handbean_probe, :native_platform)
    HandbeanProbe.NativePlatform.put!(:android)
    Handbean.Host.put!(%{data_dir: dir, shell: false, mcp: false})

    vars = %{
      "HANDBEAN_WORKSPACE" => Path.join(dir, "workspace"),
      "HANDBEAN_MODELS_FILE" => Path.join(dir, "models.json"),
      "HANDBEAN_WORKSPACES_FILE" => Path.join(dir, "workspaces.json"),
      "HANDBEAN_GLOBAL_SETTINGS_FILE" => Path.join(dir, "settings.json")
    }

    previous = Map.new(vars, fn {key, _} -> {key, System.get_env(key)} end)
    Enum.each(vars, fn {key, value} -> System.put_env(key, value) end)

    on_exit(fn ->
      HandbeanProbe.RuntimeCleanup.stop!()

      if host,
        do: Application.put_env(:handbean, :host, host),
        else: Application.delete_env(:handbean, :host)

      if previous_platform,
        do: Application.put_env(:handbean_probe, :native_platform, previous_platform),
        else: Application.delete_env(:handbean_probe, :native_platform)

      Enum.each(previous, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)

      _ = File.rm_rf(dir)
    end)

    %{view: settle(mount_screen(HomeScreen)), dir: dir}
  end

  # Full msgid; the notice is matched as a whole so translation edits stay in one place.
  def send_failed,
    do: gettext("Send failed. Check the model configuration and network, then try again.")

  def seed_input_models(view) do
    :ok =
      Handbean.Agent.ModelConfig.write_config(%{
        "defaultProvider" => "stepfun",
        "defaultModel" => "step-router-v1",
        "providers" => %{
          "stepfun" => %{
            "api" => "stepfun-step-plan",
            "apiKey" => "fixture-key",
            "baseUrl" => "https://example.invalid/v1",
            "models" => [
              %{"id" => "step-router-v1", "name" => "Step Router v1", "input" => ["text"]},
              %{
                "id" => "step-3.7-flash",
                "name" => "Step 3.7 Flash",
                "input" => ["text", "image"]
              }
            ]
          }
        }
      })

    models = ModelSettings.load(assigns(view).workspace)
    %{view | socket: Mob.Socket.assign(view.socket, :models, models)}
  end

  defmodule IOSAdapter do
    @behaviour HandbeanProbe.Platform.IOS.Adapter

    def open_url(url) do
      send(pid(), {:open_url, url})
      reply()
    end

    def share_text(text) do
      send(pid(), {:share_text, text})
      reply()
    end

    def pick_images do
      send(pid(), :pick_images)
      reply()
    end

    def present_file(path, mode) do
      send(pid(), {:present_file, path, mode})
      reply()
    end

    defp pid, do: Application.get_env(:handbean_probe, :ios_test_pid, self())
    defp reply, do: Application.get_env(:handbean_probe, :ios_adapter_reply, :ok)
  end

  def install_platform_fake(fun) do
    Application.put_env(:handbean_probe, :platform_fake, fun)
    on_exit(fn -> Application.delete_env(:handbean_probe, :platform_fake) end)
  end

  # Isolated durable share FIFO for one test; removed from the env on exit.
  def share_root!(prefix) do
    root = Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    Application.put_env(:handbean_probe, :share_intake_root, root)
    on_exit(fn -> Application.delete_env(:handbean_probe, :share_intake_root) end)
    root
  end

  def write_share_fixture!(id, rec) do
    dir = Path.join(HandbeanProbe.ShareIntake.root(), id)
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "manifest.json"),
      Jason.encode!(
        Map.merge(%{"intake_id" => id, "updated_at" => System.system_time(:millisecond)}, rec)
      )
    )
  end

  def release_turn(turn) do
    assert_receive {:provider_turn, ^turn, provider}, 5_000
    send(provider, {:provider_continue, turn})
  end

  def await_approval(runner, attempts \\ 100)
  def await_approval(_, 0), do: flunk("Runner did not enter awaiting_approval")

  def await_approval(runner, attempts) do
    if :sys.get_state(runner).status != :awaiting_approval do
      receive do
      after
        10 -> await_approval(runner, attempts - 1)
      end
    end
  end

  def new_provider(workspace) do
    ModelSettings.action(:add_provider, ModelSettings.load(workspace), workspace)
    |> ModelSettings.change(:name, "test")
    |> ModelSettings.change(:base_url, "https://example.com/v1")
    |> ModelSettings.change(:api_key, "fixture-key-not-real")
  end

  def new_model(workspace) do
    state =
      case ModelSettings.load(workspace) do
        %{providers: providers} = loaded ->
          if Enum.any?(providers, &(&1.id == "test")) do
            %{loaded | selected_provider: "test"}
          else
            ModelSettings.action(:save_provider, new_provider(workspace), workspace)
          end
      end

    state
    |> then(&ModelSettings.action({:select_provider, "test"}, &1, workspace))
    |> then(&ModelSettings.action(:add_model, &1, workspace))
    |> ModelSettings.change(:model, "native-model")
    |> ModelSettings.change(:name, "Native Model")
  end

  # Dispatch one message, then deliver every off-screen task reply it caused.
  def composer_generation(view),
    do: PendingRequests.generation(assigns(view).pending_requests, :composer)

  def info(view, message) do
    {:noreply, socket} = HomeScreen.handle_info(message, view.socket)
    settle(%{view | socket: socket})
  end

  def notice_text(view), do: HandbeanProbe.HomeScreen.Notice.text(assigns(view).notice)

  def write_native_models!(base_url) do
    assert :ok =
             Handbean.Agent.ModelConfig.write_config(%{
               "defaultProvider" => "fixture",
               "defaultModel" => "native-model",
               "providers" => %{
                 "fixture" => %{
                   "api" => "openai-chat-completions",
                   "apiKey" => "fixture-key",
                   "baseUrl" => base_url,
                   "models" => [%{"id" => "native-model", "name" => "Fixture"}]
                 }
               }
             })
  end
end
