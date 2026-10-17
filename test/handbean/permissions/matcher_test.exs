defmodule Handbean.Permissions.MatcherTest do
  use ExUnit.Case, async: false

  alias Handbean.Permissions.Matcher

  setup do
    previous = Application.get_env(:handbean, :host)
    fixed = :persistent_term.get({Handbean.Tool.Builtin.Browser, :backend}, :unfixed)
    :ok = Handbean.Tool.Builtin.Browser.release_backend!()
    Handbean.Host.put!(%{browser_backend: :cli})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:handbean, :host, previous),
        else: Application.delete_env(:handbean, :host)

      restore_browser(fixed)
    end)
  end

  describe "match?/2" do
    test "matches plain tool names and wildcard tool names" do
      assert Matcher.match?("read", %{name: "read", input: %{}})
      refute Matcher.match?("read", %{name: "bash", input: %{}})

      assert Matcher.match?("mem_*", %{name: "mem_recall", input: %{}})
      assert Matcher.match?("filesystem__*", %{name: "filesystem__read", input: %{}})
      refute Matcher.match?("mem_*", %{name: "read", input: %{}})
    end

    test "matches bash command patterns" do
      assert Matcher.match?("bash(rm:*)", %{
               name: "bash",
               input: %{"command" => "rm -rf tmp"}
             })

      assert Matcher.match?("bash(git push:*)", %{
               name: "bash",
               input: %{command: "git push origin master"}
             })

      refute Matcher.match?("bash(rm:*)", %{
               name: "bash",
               input: %{"command" => "git status --short"}
             })
    end

    test "matches multiline raw SQL only against the query field" do
      call = %{
        name: "ext__beam__sql",
        input: %{
          "repo" => "Handbean.Repo",
          "query" => "DROP TABLE\nusers",
          "params" => []
        }
      }

      assert Matcher.match?("ext__beam__sql(DROP:*)", call)
      refute Matcher.match?("ext__beam__sql(SELECT:*)", call)
    end

    test "raw SQL fingerprints include repo, query, and parameters" do
      input = %{
        "repo" => "Handbean.Repo",
        "query" => "DELETE FROM users WHERE id = ?",
        "params" => [1]
      }

      fingerprint = Matcher.sql_call_fingerprint(input)
      pattern = "ext__beam__sql(call:#{fingerprint})"

      assert Matcher.match?(pattern, %{name: "ext__beam__sql", input: input})

      refute Matcher.match?(pattern, %{
               name: "ext__beam__sql",
               input: Map.put(input, "params", [2])
             })
    end

    test "matches file path patterns for edit and write" do
      assert Matcher.match?("edit(.env)", %{name: "edit", input: %{"file_path" => ".env"}})

      assert Matcher.match?("write(config/*.json)", %{
               name: "write",
               input: %{path: "config/app.json"}
             })

      refute Matcher.match?("edit(.env)", %{name: "edit", input: %{"file_path" => "README.md"}})
    end

    test "CLI browser matches args only" do
      assert Matcher.match?("browser(eval:*)", %{
               name: "browser",
               input: %{"args" => ["eval", "document.cookie"]}
             })

      assert Matcher.match?("browser(open:*)", %{
               name: "browser",
               input: %{args: ["open", "https://example.com"]}
             })

      refute Matcher.match?("browser(eval:*)", %{
               name: "browser",
               input: %{"args" => ["snapshot", "-i"]}
             })

      refute Matcher.match?("browser(eval:*)", %{
               name: "browser",
               input: %{"action" => "eval", "js" => "1"}
             })
    end

    test "WebView browser matches action only" do
      Handbean.Host.put!(%{browser_backend: :webview})

      assert Matcher.match?("browser(eval:*)", %{
               name: "browser",
               input: %{"action" => "eval", "js" => "1"}
             })

      refute Matcher.match?("browser(eval:*)", %{
               name: "browser",
               input: %{"action" => "snapshot"}
             })

      refute Matcher.match?("browser(eval:*)", %{
               name: "browser",
               input: %{"args" => ["eval", "document.cookie"]}
             })
    end
  end

  defp restore_browser(:unfixed), do: Handbean.Tool.Builtin.Browser.release_backend!()

  defp restore_browser(backend) do
    :persistent_term.put({Handbean.Tool.Builtin.Browser, :backend}, backend)
    :ok
  end
end
