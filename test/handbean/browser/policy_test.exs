defmodule Handbean.Browser.PolicyTest do
  @moduledoc """
  Tests for browser argv classification.

  Safe navigation/snapshot/click stays auto. eval, cookies, profile,
  upload/download, and attach/CDP require approval. Local files, caller
  session takeover, and shell metacharacters are denied before spawn.
  """

  use ExUnit.Case, async: true

  alias Handbean.Browser.Policy

  describe "classify/1 — auto" do
    test "allows http(s) navigation, snapshot, and interaction" do
      assert {:auto, %{command: "open"}} = Policy.classify(["open", "https://example.com"])
      assert {:prompt, %{command: "open"}} = Policy.classify(["open", "http://localhost:4000"])
      assert {:auto, %{command: "goto"}} = Policy.classify(["goto", "https://example.com/docs"])
      assert {:auto, %{command: "snapshot"}} = Policy.classify(["snapshot", "-i"])
      assert {:auto, %{command: "click"}} = Policy.classify(["click", "@e2"])
      assert {:auto, %{command: "fill"}} = Policy.classify(["fill", "@e1", "hello"])
      assert {:auto, %{command: "type"}} = Policy.classify(["type", "hello"])
      assert {:auto, %{command: "get"}} = Policy.classify(["get", "title"])
      assert {:auto, %{command: "tab"}} = Policy.classify(["tab", "list"])
      assert {:auto, %{command: "wait"}} = Policy.classify(["wait", "1000"])
      assert {:auto, %{command: "screenshot"}} = Policy.classify(["screenshot"])
      assert {:auto, %{command: "close"}} = Policy.classify(["close"])
      assert {:auto, %{command: "quit"}} = Policy.classify(["quit"])
      assert {:auto, %{command: "read"}} = Policy.classify(["read", "https://example.com"])
      assert {:auto, %{command: "find"}} = Policy.classify(["find", "text", "Hello", "click"])
      assert {:auto, %{command: "select"}} = Policy.classify(["select", "@e1", "a"])
      assert {:auto, %{command: "dblclick"}} = Policy.classify(["dblclick", "@e1"])
    end

    test "treats inspection flags as stateless auto commands" do
      assert {:auto, %{command: "--help"}} = Policy.classify(["--help"])
      assert {:auto, %{command: "--version"}} = Policy.classify(["--version"])
      assert {:auto, %{command: "-h"}} = Policy.classify(["-h"])
      assert {:auto, %{command: "-V"}} = Policy.classify(["-V"])

      assert {:auto, %{command: "--help"}} =
               Policy.classify(["--profile", "work", "--help"])
    end
  end

  describe "classify/1 — prompt" do
    test "requires approval for eval, cookies, storage, auth, and I/O" do
      assert {:prompt, %{command: "eval", capability: :eval}} =
               Policy.classify(["eval", "document.cookie"])

      assert {:prompt, %{command: "cookies", capability: :cookies}} =
               Policy.classify(["cookies", "get"])

      assert {:prompt, %{command: "storage", capability: :storage}} =
               Policy.classify(["storage", "local", "get"])

      assert {:prompt, %{command: "auth", capability: :auth}} =
               Policy.classify(["auth", "save"])

      assert {:prompt, %{command: "upload", capability: :upload}} =
               Policy.classify(["upload", "@e1", "file.pdf"])

      assert {:prompt, %{command: "eval", capability: :eval}} =
               Policy.classify(["eval", "-h"])

      assert {:prompt, %{command: "upload", capability: :upload}} =
               Policy.classify(["upload", "@e1", "-h"])

      assert {:prompt, %{command: "download", capability: :download}} =
               Policy.classify(["download", "@e3"])
    end

    test "requires approval for close --all, local URLs, and pdf" do
      assert {:prompt, %{command: "close"}} = Policy.classify(["close", "--all"])
      assert {:prompt, %{command: "open"}} = Policy.classify(["open", "http://127.0.0.1:4000"])

      assert {:prompt, %{command: "open"}} =
               Policy.classify(["open", "http://169.254.169.254/latest/meta-data/"])

      assert {:prompt, %{command: "pdf"}} = Policy.classify(["pdf", "out.pdf"])
    end

    test "requires approval for profile, headed, and attach/CDP" do
      assert {:prompt, %{capability: :profile}} =
               Policy.classify(["open", "https://example.com", "--profile", "work"])

      assert {:prompt, %{capability: :headed}} =
               Policy.classify(["--headed", "open", "https://x.test"])

      assert {:prompt, %{command: "connect", capability: :connect}} = Policy.classify(["connect"])

      assert {:prompt, %{capability: :cdp}} =
               Policy.classify(["open", "https://x.test", "--cdp", "9222"])
    end

    test "unknown commands are not auto-approved" do
      assert {:prompt, %{command: "mystery", capability: :unknown}} =
               Policy.classify(["mystery", "--foo"])
    end
  end

  describe "classify/1 — deny" do
    test "rejects empty or non-string args" do
      assert {:deny, %{failure_category: "validation-error"}} = Policy.classify([])
      assert {:deny, %{failure_category: "validation-error"}} = Policy.classify([1, "open"])
    end

    test "rejects local and non-http navigation even with prompt flags" do
      assert {:deny, %{failure_category: "validation-error"}} =
               Policy.classify(["open", "file:///etc/passwd"])

      assert {:deny, %{failure_category: "validation-error"}} =
               Policy.classify(["--headed", "open", "file:///etc/passwd"])

      assert {:deny, %{failure_category: "validation-error"}} =
               Policy.classify(["open", "file:///etc/passwd", "--profile", "work"])

      assert {:deny, %{failure_category: "validation-error"}} =
               Policy.classify(["goto", "about:blank"])

      assert {:deny, %{failure_category: "validation-error"}} =
               Policy.classify(["open", "javascript:alert(1)"])
    end

    test "rejects caller-owned session, json injection, and file access" do
      assert {:deny, %{failure_category: "validation-error"}} =
               Policy.classify(["--session", "mine", "snapshot", "-i"])

      assert {:deny, %{failure_category: "validation-error"}} =
               Policy.classify(["snapshot", "--json"])

      assert {:deny, %{failure_category: "validation-error"}} =
               Policy.classify(["open", "https://example.com", "--namespace", "other"])

      assert {:deny, %{failure_category: "validation-error"}} =
               Policy.classify(["open", "https://example.com", "--allow-file-access"])
    end

    test "rejects shell metacharacters so args cannot become a shell" do
      assert {:deny, %{failure_category: "validation-error"}} =
               Policy.classify(["open", "https://example.com && rm -rf /"])

      assert {:deny, %{failure_category: "validation-error"}} =
               Policy.classify(["eval", "1; cat /etc/passwd"])
    end

    test "does not treat ordinary JS semicolons as a shell" do
      assert {:prompt, %{command: "eval"}} = Policy.classify(["eval", "document.title; 1"])
    end
  end

  describe "classify_native/1" do
    test "allows http(s) open and snapshot" do
      assert {:auto, %{command: "open"}} =
               Policy.classify_native(%{"action" => "open", "url" => "https://example.org"})

      assert {:auto, %{command: "snapshot"}} = Policy.classify_native(%{"action" => "snapshot"})
    end

    test "prompts eval and takeover; denies files and malformed input" do
      assert {:prompt, %{command: "eval", capability: :eval}} =
               Policy.classify_native(%{"action" => "eval", "js" => "1"})

      assert {:prompt, %{command: "show", capability: :profile}} =
               Policy.classify_native(%{"action" => "show", "takeover" => true})

      assert {:deny, %{failure_category: "validation-error"}} =
               Policy.classify_native(%{"action" => "open", "url" => "file:///etc/passwd"})

      assert {:deny, %{failure_category: "validation-error"}} =
               Policy.classify_native(%{"action" => "open", "url" => "not-a-url"})

      assert {:deny, %{failure_category: "validation-error"}} =
               Policy.classify_native(%{"action" => "cookies"})

      assert {:deny, %{failure_category: "validation-error"}} =
               Policy.classify_native(%{"url" => "https://example.org"})
    end
  end

  describe "inspection?/1" do
    test "detects help and version only" do
      assert Policy.inspection?(["--help"])
      assert Policy.inspection?(["--version"])
      refute Policy.inspection?(["open", "https://example.com"])
      refute Policy.inspection?(["snapshot", "-i"])
      refute Policy.inspection?(["eval", "-h"])
      refute Policy.inspection?(["upload", "@e1", "-h"])

      assert Policy.command(["--profile", "work", "eval", "-h"]) == "eval"
      assert Policy.command(["--cdp", "9222", "upload", "@e1", "-h"]) == "upload"
    end
  end

  describe "sensitive_local_path?/2" do
    test "finds upload sources and browser output paths" do
      refute Policy.sensitive_local_path?(["upload", "@e1", "notes.txt", "image.png"], nil)

      assert Policy.sensitive_local_path?(["upload", "@e1", "~/.ssh/id_rsa"], nil)
      assert Policy.sensitive_local_path?(["screenshot", "--full", ".env"], nil)
      assert Policy.sensitive_local_path?(["pdf", "keys/client.pem"], nil)
      assert Policy.sensitive_local_path?(["download", "@e2", "private/token.p12"], nil)
      assert Policy.sensitive_local_path?(["wait", "--download", ".env.local"], nil)

      assert Policy.sensitive_local_path?(
               ["--profile", "work", "upload", "@e1", "~/.ssh/id_rsa"],
               nil
             )

      assert Policy.sensitive_local_path?(
               ["pdf", "--profile", "work", ".env.production"],
               nil
             )

      assert Policy.sensitive_local_path?(["--screenshot-dir=.ssh", "screenshot"], nil)
    end
  end
end
