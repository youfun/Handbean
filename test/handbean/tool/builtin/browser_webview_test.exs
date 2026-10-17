defmodule Handbean.Tool.Builtin.BrowserWebViewTest do
  use ExUnit.Case, async: false

  alias Handbean.Tool.Builtin.Browser

  setup do
    previous = Application.get_env(:handbean, :host)
    fixed = :persistent_term.get({Browser, :backend}, :unfixed)
    :ok = Browser.release_backend!()
    Handbean.Host.put!(%{browser_backend: :webview})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:handbean, :host, previous),
        else: Application.delete_env(:handbean, :host)

      restore_backend(fixed)
    end)

    :ok
  end

  test "mobile schema uses action not args" do
    schema = Browser.input_schema()
    assert schema.required == ["action"]

    assert schema.properties.action.enum == [
             "open",
             "snapshot",
             "eval",
             "click",
             "fill",
             "back",
             "show",
             "hide",
             "close"
           ]

    refute Map.has_key?(schema.properties, :args)
  end

  test "open rejects non-http urls" do
    assert {:error, reason} =
             Browser.execute(%{"action" => "open", "url" => "file:///etc/passwd"}, %{})

    assert reason =~ "http"
  end

  test "open calls the injected webview runner" do
    runner = fn command, _opts ->
      send(self(), {:ran, command})
      {:ok, "url: https://example.com\ntitle: Example"}
    end

    assert {:ok, text, details} =
             Browser.execute(%{"action" => "open", "url" => "https://example.com"}, %{
               browser_webview_runner: runner
             })

    assert text =~ "example.com"
    assert details.backend == "webview"
    assert_received {:ran, command}
    assert command.action == "open"
    assert command.url == "https://example.com"
  end

  test "snapshot and eval go through the same runner" do
    runner = fn command, _opts ->
      {:ok, inspect(command)}
    end

    context = %{browser_webview_runner: runner}

    assert {:ok, text, details} = Browser.execute(%{"action" => "snapshot"}, context)
    assert text =~ "snapshot"
    assert details.backend == "webview"

    assert {:ok, text, details} =
             Browser.execute(%{"action" => "eval", "js" => "1+1"}, context)

    assert text =~ "eval"
    assert details.backend == "webview"
  end

  defp restore_backend(:unfixed), do: Browser.release_backend!()

  defp restore_backend(backend) do
    :persistent_term.put({Browser, :backend}, backend)
    :ok
  end
end
