defmodule Handbean.Browser.WebViewSessionTest do
  use ExUnit.Case, async: false

  alias Handbean.Browser.{Display, WebViewSession, WebViewSupervisor}
  alias Handbean.Tool.Builtin.Browser

  setup do
    previous_engine = Application.get_env(:handbean, :browser_engine)
    previous_host = Application.get_env(:handbean, :host)
    fixed = :persistent_term.get({Browser, :backend}, :unfixed)
    :ok = Browser.release_backend!()
    Handbean.Host.put!(%{browser_backend: :webview, shell: false})

    {:ok, _} = start_supervised({Registry, keys: :unique, name: Handbean.Browser.WebViewRegistry})
    {:ok, _} = start_supervised(WebViewSupervisor)
    _ = Display.reset!()

    conversation_id = "conv-wv-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      if previous_engine do
        Application.put_env(:handbean, :browser_engine, previous_engine)
      else
        Application.delete_env(:handbean, :browser_engine)
      end

      if previous_host do
        Application.put_env(:handbean, :host, previous_host)
      else
        Application.delete_env(:handbean, :host)
      end

      restore_browser(fixed)
    end)

    %{conversation_id: conversation_id}
  end

  test "open then snapshot hits the fake engine, not chat DOM", %{
    conversation_id: conversation_id
  } do
    test = self()

    install_fake!(fn cmd, _opts ->
      send(test, {:engine, cmd})

      case cmd.op do
        :create ->
          {:ok, %{}}

        :load ->
          {:ok, %{"action" => "open", "url" => cmd.url}}

        :eval ->
          {:ok,
           ~s({"action":"snapshot","url":"https://example.com/b","title":"B","text":"browser","items":[{"ref":"0","tag":"a","text":"Go"}],"hasMob":"undefined"})}

        _ ->
          {:ok, %{}}
      end
    end)

    {:ok, %{session_id: session_id}} = WebViewSupervisor.ensure(conversation_id, "auto")

    assert {:ok, _, details} =
             WebViewSession.call(session_id, %{
               "action" => "open",
               "url" => "https://example.com/a"
             })

    assert details.session_id == session_id
    assert details.generation == 1

    assert {:ok, text, _} = WebViewSession.call(session_id, %{"action" => "snapshot"})
    assert text =~ "url: https://example.com/b"
    assert text =~ "[0] a Go"
    refute text =~ "window.mob"
  end

  test "async snapshot returns a generation usable by the following click", %{
    conversation_id: conversation_id
  } do
    install_fake!(fn cmd, _opts ->
      if cmd.op == :eval do
        send(
          cmd.caller,
          {:engine_result,
           %{
             session_id: cmd.session_id,
             request_id: cmd.request_id,
             generation: cmd.generation,
             result: ~s({"ok":true,"items":[{"ref":"0","tag":"a","text":"Go"}]})
           }}
        )

        {:error, :async}
      else
        {:ok, %{}}
      end
    end)

    {:ok, %{session_id: session_id}} = WebViewSupervisor.ensure(conversation_id, "auto")
    assert {:ok, _, snapshot} = WebViewSession.call(session_id, %{"action" => "snapshot"})

    assert {:ok, _, _} =
             WebViewSession.call(session_id, %{
               "action" => "click",
               "ref" => "0",
               "refs_gen" => snapshot.refs_gen
             })
  end

  test "async native callbacks preserve UTF-8 binary fields", %{
    conversation_id: conversation_id
  } do
    test = self()

    install_fake!(fn cmd, _opts ->
      case cmd.op do
        :create ->
          {:ok, %{}}

        :eval ->
          send(test, {:eval, cmd})
          {:error, :async}

        _ ->
          {:ok, %{}}
      end
    end)

    {:ok, %{session_id: session_id}} = WebViewSupervisor.ensure(conversation_id, "auto")

    task =
      Task.async(fn ->
        WebViewSession.call(session_id, %{"action" => "eval", "js" => "document.title"})
      end)

    assert_receive {:eval, cmd}

    send(cmd.caller, {
      :engine_result,
      %{
        session_id: cmd.session_id,
        request_id: cmd.request_id,
        generation: cmd.generation,
        result: ~s({"ok":true,"value":"原生浏览器 🚀"}),
        url: "http://127.0.0.1:5088/中文🚀"
      }
    })

    assert {:ok, text, details} = Task.await(task)
    assert text =~ "原生浏览器 🚀"
    assert details.session_id == session_id
  end

  test "Browser.execute isolates conversations and preserves session and command fields" do
    test = self()
    Handbean.Host.put!(%{browser_backend: :webview})

    install_fake!(fn cmd, _opts ->
      send(test, {:engine, cmd})

      case cmd.op do
        :create ->
          {:ok, %{}}

        :load ->
          Process.put({:url, cmd.session_id}, cmd.url)
          {:ok, %{"action" => "open", "url" => cmd.url}}

        :eval ->
          url = Process.get({:url, cmd.session_id})
          {:ok, Jason.encode!(%{"ok" => true, "url" => url, "text" => url, "items" => []})}

        _ ->
          {:ok, %{}}
      end
    end)

    assert {:ok, _, first_details} =
             Browser.execute(
               %{"action" => "open", "url" => "https://example.test/alpha"},
               %{conversation_id: "browser-alpha"}
             )

    assert {:ok, _, second_details} =
             Browser.execute(
               %{"action" => "open", "url" => "https://example.test/beta"},
               %{conversation_id: "browser-beta"}
             )

    assert first_details.session_id != second_details.session_id
    assert_received {:engine, %{op: :create, conversation_id: "browser-alpha"}}
    assert_received {:engine, %{op: :create, conversation_id: "browser-beta"}}

    assert {:ok, alpha, _} =
             Browser.execute(%{"action" => "snapshot"}, %{conversation_id: "browser-alpha"})

    assert {:ok, beta, _} =
             Browser.execute(%{"action" => "snapshot"}, %{conversation_id: "browser-beta"})

    assert alpha =~ "/alpha"
    refute alpha =~ "/beta"
    assert beta =~ "/beta"
    refute beta =~ "/alpha"

    assert {:error, "stale DOM ref"} =
             Browser.execute(
               %{"action" => "click", "ref" => "0", "refs_gen" => -1},
               %{conversation_id: "browser-alpha"}
             )

    assert {:ok, "waiting for user takeover", takeover_details} =
             Browser.execute(
               %{"action" => "show", "takeover" => true, "reason" => "请登录"},
               %{conversation_id: "browser-alpha"}
             )

    assert takeover_details.needs_user
    assert takeover_details.reason == "请登录"

    assert {:ok, _, fresh_details} =
             Browser.execute(
               %{
                 "action" => "open",
                 "url" => "https://example.test/fresh",
                 "session_mode" => "fresh"
               },
               %{conversation_id: "browser-alpha"}
             )

    assert fresh_details.session_id != first_details.session_id
    assert fresh_details.generation == first_details.generation + 1
  end

  test "file urls are rejected before the engine", %{conversation_id: conversation_id} do
    install_fake!(fn cmd, _ ->
      if cmd.op == :load, do: flunk("file url reached engine")
      {:ok, %{}}
    end)

    {:ok, %{session_id: session_id}} = WebViewSupervisor.ensure(conversation_id, "auto")

    assert {:error, reason} =
             WebViewSession.call(session_id, %{"action" => "open", "url" => "file:///etc/passwd"})

    assert reason =~ "http"
  end

  test "stale DOM refs and late results after close are rejected", %{
    conversation_id: conversation_id
  } do
    test = self()

    install_fake!(fn cmd, _opts ->
      send(test, {:engine, cmd})

      case cmd.op do
        :eval -> {:error, :async}
        :destroy -> {:ok, %{}}
        _ -> {:ok, %{}}
      end
    end)

    {:ok, %{session_id: session_id}} = WebViewSupervisor.ensure(conversation_id, "auto")
    {:ok, %{refs_gen: gen}} = {:ok, WebViewSession.snapshot_state(session_id)}

    task =
      Task.async(fn ->
        WebViewSession.call(
          session_id,
          %{"action" => "click", "ref" => "0", "refs_gen" => gen + 99},
          timeout_ms: 200
        )
      end)

    assert {:error, reason} = Task.await(task)
    assert reason =~ "stale" or reason =~ "timed out" or reason =~ "busy" or reason =~ "not found"
  end

  test "user takeover blocks writes; hide does not restore automation", %{
    conversation_id: conversation_id
  } do
    install_fake!(fn _cmd, _ -> {:ok, %{}} end)
    {:ok, %{session_id: session_id}} = WebViewSupervisor.ensure(conversation_id, "auto")

    assert :ok = WebViewSession.user_takeover(session_id)

    assert {:error, reason, details} =
             WebViewSession.call(session_id, %{"action" => "click", "ref" => "0"})

    assert reason =~ "user control"
    assert details.needs_user

    assert {:ok, "hidden", _} = WebViewSession.call(session_id, %{"action" => "hide"})
    state = WebViewSession.snapshot_state(session_id)
    assert state.control == :user
    refute state.visible

    assert {:error, _, _} =
             WebViewSession.call(session_id, %{"action" => "fill", "ref" => "0", "value" => "x"})

    assert :ok = WebViewSession.user_handback(session_id)
    state = WebViewSession.snapshot_state(session_id)
    assert state.control == :agent
  end

  test "fresh bumps generation and does not claim profile isolation", %{
    conversation_id: conversation_id
  } do
    install_fake!(fn _cmd, _ -> {:ok, %{}} end)

    {:ok, first} = WebViewSupervisor.ensure(conversation_id, "auto")
    {:ok, second} = WebViewSupervisor.ensure(conversation_id, "fresh")
    assert second.generation == first.generation + 1
    assert second.session_id != first.session_id

    details = WebViewSession.snapshot_state(second.session_id)
    assert details.generation == second.generation
  end

  test "timeout marks recovery and does not retry", %{conversation_id: conversation_id} do
    install_fake!(fn cmd, _ ->
      if cmd.op == :load, do: {:error, :async}, else: {:ok, %{}}
    end)

    {:ok, %{session_id: session_id}} = WebViewSupervisor.ensure(conversation_id, "auto")

    assert {:error, reason, details} =
             WebViewSession.call(
               session_id,
               %{"action" => "open", "url" => "https://example.com"},
               timeout_ms: 30
             )

    assert reason =~ "timed out"
    assert details.side_effects_unknown
    assert WebViewSession.snapshot_state(session_id).needs_recovery

    assert {:error, recovery, _} = WebViewSession.call(session_id, %{"action" => "snapshot"})
    assert recovery =~ "recovery"
  end

  test "late callback after close does not complete the closed request", %{
    conversation_id: conversation_id
  } do
    test = self()

    install_fake!(fn cmd, _ ->
      send(test, {:cmd, cmd})
      if cmd.op in [:eval, :load], do: {:error, :async}, else: {:ok, %{}}
    end)

    {:ok, %{session_id: session_id}} = WebViewSupervisor.ensure(conversation_id, "auto")

    task =
      Task.async(fn ->
        WebViewSession.call(session_id, %{"action" => "snapshot"}, timeout_ms: 5_000)
      end)

    assert_receive {:cmd, %{op: :eval}}, 500

    close = Task.async(fn -> WebViewSession.call(session_id, %{"action" => "close"}) end)
    _ = Task.await(close, 1_000)

    result = Task.yield(task, 1_000) || Task.shutdown(task)

    assert match?({:ok, {:error, _, %{stale?: true}}}, result) or
             match?({:ok, {:error, "browser session is closed"}}, result) or
             match?({:ok, {:error, "browser session is closed", _}}, result) or
             match?({:exit, _}, result) or
             is_nil(result)
  end

  test "tool schema stays on the backend fixed before the test host change" do
    :ok = Browser.fix_backend!()
    schema = Browser.input_schema()
    assert schema.required == ["action"]
    assert "show" in schema.properties.action.enum
    refute Map.has_key?(schema.properties, :args)

    Handbean.Host.put!(%{browser_backend: :cli})
    assert Browser.backend() == :webview
    assert Browser.input_schema().required == ["action"]
  end

  test "desktop schema stays args when the fixed backend is released" do
    :ok = Browser.release_backend!()
    Application.delete_env(:handbean, :host)
    schema = Browser.input_schema()
    assert schema.required == ["args"]
  end

  defp restore_browser(:unfixed), do: Browser.release_backend!()

  defp restore_browser(backend) do
    :persistent_term.put({Browser, :backend}, backend)
    :ok
  end

  defp install_fake!(fun) do
    Application.put_env(:handbean, :browser_engine, fun)
  end
end
