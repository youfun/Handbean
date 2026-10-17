defmodule HandbeanWeb.Feature.BrowserAnnotationFeatureTest do
  @moduledoc """
  Open the workspace browser, mark an element, and append the annotation to
  the current composer. The browser subprocess is a fake runner.

  Run: mix test --include e2e test/feature/browser_annotation_feature_test.exs
  """

  use HandbeanWeb.FeatureCase, async: false

  alias Handbean.ConversationStore
  alias Handbean.TestSupport.E2EHarness

  @moduletag :e2e

  test "send to composer appends the annotation and its screenshot", %{conn: conn} do
    %{workspace: workspace} = E2EHarness.isolate_home!("browser-annotation")
    previous = Application.get_env(:handbean, :user_browser_cli)

    Application.put_env(:handbean, :user_browser_cli,
      runner: runner(),
      find_executable: fn "agent-browser" -> "/usr/local/bin/agent-browser" end
    )

    ExUnit.Callbacks.on_exit(fn ->
      if previous do
        Application.put_env(:handbean, :user_browser_cli, previous)
      else
        Application.delete_env(:handbean, :user_browser_cli)
      end
    end)

    E2EHarness.use_fake_provider!({:script, fn _messages, _tools -> "ok" end})
    {:ok, ws} = Handbean.WorkspaceStore.add(workspace, name: "Browser fixture")
    {:ok, conversation} = ConversationStore.create(ws["id"], title: "Browser annotation")
    id = conversation["id"]
    ExUnit.Callbacks.on_exit(fn -> E2EHarness.cancel!(id) end)

    session =
      conn
      |> visit("/w/#{ws["id"]}/c/#{id}")
      |> click_button("#workspace-panel-browser", "Browser")
      |> fill_in("#browser-url", "URL", with: "http://127.0.0.1:9/fixture")
      |> click_button("#browser-go", "Go")
      |> click_button("#browser-design", "Design")
      |> click_button("#browser-surface", "")
      |> assert_has("#browser-annotation-count", text: "1 command")
      |> click_button("#browser-send", "Send to composer")
      |> assert_has("#ai-input", text: "Browser annotations", timeout: 5_000)
      |> assert_has("#ai-input", text: "#cta", timeout: 5_000)
      |> assert_has("#composer-attachments img", timeout: 5_000)

    session
    |> click_button("#send-button", "Send")
    |> assert_has(".msg-bubble.msg-user", text: "Browser annotations", timeout: 5_000)

    entry =
      E2EHarness.transcript(id)
      |> Enum.find(&(&1["role"] == "user"))

    assert entry["content"] =~ "Browser annotations"
    assert entry["content"] =~ "#cta"
    assert entry["attachments"] != []
  end

  defp runner do
    fn argv, _opts ->
      cond do
        "open" in argv ->
          url = Enum.find(argv, &String.starts_with?(&1, "http"))
          ok(%{"url" => url})

        Enum.any?(argv, &String.contains?(&1, "elementFromPoint")) ->
          ok(%{
            "result" =>
              Handbean.JSON.encode!(%{
                "selector" => "#cta",
                "tag" => "button",
                "text" => "Click me",
                "rect" => %{"x" => 4, "y" => 6, "width" => 40, "height" => 16}
              })
          })

        "screenshot" in argv ->
          path = Enum.find(argv, &String.ends_with?(&1, ".jpg"))
          File.write!(path, <<0xFF, 0xD8, 0xFF, 0xD9>>)
          ok(%{"path" => path})

        true ->
          ok(%{})
      end
    end
  end

  defp ok(data) do
    {:ok,
     %{
       stdout: Handbean.JSON.encode!(%{"success" => true, "data" => data}),
       stderr: "",
       exit_code: 0,
       timed_out: false
     }}
  end
end
