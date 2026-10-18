defmodule Handbean.Permissions.ToolPolicyWebviewTest do
  use ExUnit.Case, async: false

  alias Handbean.Permissions.Matcher
  alias Handbean.Permissions.Remember
  alias Handbean.Permissions.ToolPolicy

  setup do
    previous = Application.get_env(:handbean, :host)
    fixed = :persistent_term.get({Handbean.Tool.Builtin.Browser, :backend}, :unfixed)
    :ok = Handbean.Tool.Builtin.Browser.release_backend!()
    Handbean.Host.put!(%{browser_backend: :webview})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:handbean, :host, previous),
        else: Application.delete_env(:handbean, :host)

      restore_browser(fixed)
    end)
  end

  defp call(name, input), do: %{id: "call_#{name}", name: name, input: input}

  test "native JavaScript and form text are data, not shell commands" do
    policy = ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "auto"}})

    assert ToolPolicy.decision(
             policy,
             call("browser", %{"action" => "eval", "js" => "const x = 1; x + 2"})
           ) == :auto

    assert ToolPolicy.decision(
             policy,
             call("browser", %{"action" => "fill", "ref" => "e1", "value" => "a && b; c"})
           ) == :auto
  end

  test "Android default workspace allows valid open and snapshot" do
    policy = ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "auto"}})

    assert ToolPolicy.decision(
             policy,
             call("browser", %{"action" => "open", "url" => "https://example.org"})
           ) == :auto

    assert ToolPolicy.decision(policy, call("browser", %{"action" => "snapshot"})) == :auto
  end

  test "Android default workspace denies invalid URLs and actions" do
    policy = ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "auto"}})

    assert ToolPolicy.decision(
             policy,
             call("browser", %{"action" => "open", "url" => "file:///etc/passwd"})
           ) == :deny

    assert ToolPolicy.decision(
             policy,
             call("browser", %{"action" => "open", "url" => "javascript:alert(1)"})
           ) == :deny

    assert ToolPolicy.decision(policy, call("browser", %{"action" => "open"})) == :deny
    assert ToolPolicy.decision(policy, call("browser", %{"action" => "mystery"})) == :deny
  end

  test "explicit workspace deny and per_tool still win on native input" do
    deny_eval =
      ToolPolicy.from_settings(%{
        "tools" => %{"default_mode" => "auto", "deny" => ["browser(eval:*)"]}
      })

    assert ToolPolicy.decision(deny_eval, call("browser", %{"action" => "eval", "js" => "1"})) ==
             :deny

    per_tool =
      ToolPolicy.from_settings(%{
        "tools" => %{"default_mode" => "auto", "per_tool" => %{"browser" => "deny"}}
      })

    assert ToolPolicy.decision(
             per_tool,
             call("browser", %{"action" => "open", "url" => "https://example.org"})
           ) == :deny
  end

  test "eval and takeover prompt in safe mode and auto in full access" do
    auto = ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "auto"}})
    prompt = ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "prompt"}})

    assert ToolPolicy.decision(auto, call("browser", %{"action" => "eval", "js" => "1"})) == :auto

    assert ToolPolicy.decision(auto, call("browser", %{"action" => "show", "takeover" => true})) ==
             :auto

    assert ToolPolicy.decision(prompt, call("browser", %{"action" => "eval", "js" => "1"})) ==
             :prompt

    assert ToolPolicy.decision(prompt, call("browser", %{"action" => "show", "takeover" => true})) ==
             :prompt
  end

  test "native deny globs match action and ignore injected desktop args" do
    assert Matcher.match?("browser(eval:*)", %{
             name: "browser",
             input: %{"action" => "eval", "js" => "1", "args" => ["snapshot"]}
           })

    refute Matcher.match?("browser(snapshot:*)", %{
             name: "browser",
             input: %{"action" => "eval", "js" => "1", "args" => ["snapshot"]}
           })

    assert Remember.pattern(
             call("browser", %{"action" => "open", "url" => "https://example.org"})
           ) ==
             "browser(open:*)"
  end

  defp restore_browser(:unfixed), do: Handbean.Tool.Builtin.Browser.release_backend!()

  defp restore_browser(backend) do
    :persistent_term.put({Handbean.Tool.Builtin.Browser, :backend}, backend)
    :ok
  end
end
