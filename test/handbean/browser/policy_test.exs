defmodule Handbean.Browser.PolicyTest do
  @moduledoc """
  Tests for browser argv classification.

  Safe navigation/snapshot/click stays auto. eval, cookies, profile,
  upload/download, and attach/CDP require approval. Local files, caller
  session takeover, and shell command syntax outside eval source are denied
  before spawn.
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
      assert {:auto, %{command: "type"}} = Policy.classify(["type", "@e1", "hello"])
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

    test "treats JavaScript operators, templates, and multiline source as eval data" do
      scripts = [
        "document.querySelector('#add-project-error')?.textContent || Array.from(document.querySelectorAll('[role=alert]')).map(x=>x.textContent).join('|')",
        "document.body && document.title",
        "`title: ${document.title}`",
        "$('body').text()",
        "const label = 'cat | bash';\nlabel",
        "document.title; 1"
      ]

      for script <- scripts do
        assert {:prompt, %{command: "eval", capability: :eval}} =
                 Policy.classify(["eval", script])

        assert {:prompt, %{command: "eval", capability: :headed}} =
                 Policy.classify(["--headed", "eval", script])

        assert {:prompt, %{command: "eval", capability: :profile}} =
                 Policy.classify(["--profile", "eval", "eval", script])
      end
    end

    test "treats only verified fill and type text slots as arbitrary text" do
      text = "printf 'ok' && cat file || python -c x; a | b > out < in\n$(touch nope) `literal`"

      for {args, decision, command} <- [
            {["fill", "@e1", text], :auto, "fill"},
            {["type", "@e1", text], :auto, "type"},
            {["type", "@e1", "--clear", text, "--delay", "25"], :auto, "type"},
            {["keyboard", "type", text], :prompt, "keyboard"},
            {["keyboard", "inserttext", text], :prompt, "keyboard"}
          ] do
        assert {^decision, %{command: ^command}} = Policy.classify(args)
      end
    end

    test "keeps parser-recognized global flags and values outside text slots" do
      text = "printf 'ok' && cat file\n$(touch nope) `literal`"

      assert {:deny, %{policy_rule: :shell_metacharacters, argument_role: :flag_value}} =
               Policy.classify(["fill", "--profile", "work && echo x", "@e1", "safe"])

      assert {:deny, %{policy_rule: :shell_metacharacters, argument_role: :flag}} =
               Policy.classify(["fill", "@e1", "--profile=work&&echo x"])

      assert {:prompt, %{command: "fill", capability: :headed}} =
               Policy.classify(["fill", "@e1", "--headed", text])

      assert {:auto, %{command: "fill"}} =
               Policy.classify(["fill", "@e1", "--unknown=$(literal) && text"])

      assert {:auto, %{command: "type"}} =
               Policy.classify(["type", "@e1", "--delay=25 && literal"])
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
      assert {:deny, %{failure_category: "validation-error"}} = Policy.classify(["eval", "1\0"])
    end

    test "rejects NUL in every argument role, including text" do
      for {args, command, role} <- [
            {["fill\0", "@e1", "text"], "unknown", :command},
            {["fill", "@e1\0", "text"], "fill", :ref},
            {["fill", "@e1", "text\0"], "fill", :text},
            {["fill", "@e1", "text", "tail\0"], "fill", :trailing_arg},
            {["--profile", "work\0", "fill", "@e1", "text"], "fill", :flag_value}
          ] do
        assert {:deny,
                %{
                  command: ^command,
                  policy_rule: :nul,
                  argument_role: ^role,
                  failure_category: "validation-error"
                }} = Policy.classify(args)
      end
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
      for args <- [
            ["--session", "mine", "snapshot", "-i"],
            ["snapshot", "--json"],
            ["snapshot", "--json=true"],
            ["open", "https://example.com", "--namespace", "other"],
            ["open", "https://example.com", "--allow-file-access"],
            ["fill", "@e1", "--json"],
            ["fill", "@e1", "--json=false"],
            ["type", "@e1", "--session=mine"],
            ["keyboard", "type", "--namespace=other"]
          ] do
        assert {:deny,
                %{
                  policy_rule: :forbidden_flag,
                  argument_role: :flag,
                  failure_category: "validation-error"
                }} = Policy.classify(args)
      end
    end

    test "rejects shell command syntax outside verified text slots with stable roles" do
      for {args, command, role} <- [
            {["open", "https://example.com && rm -rf /"], "open", :url},
            {["eval", "document.title", "&& rm -rf /"], "eval", :trailing_arg},
            {["eval && rm -rf /", "document.title"], "unknown", :command},
            {["--profile", "work && rm -rf /", "eval", "document.title"], "eval", :flag_value},
            {["--headed&&echo x", "fill", "@e1", "text"], "fill", :flag},
            {["fill", "@e1 && echo x", "text"], "fill", :ref},
            {["fill", "@e1", "text", "&& echo x"], "fill", :trailing_arg},
            {["type", "@e1 && echo x"], "type", :ref},
            {["type", "@e1 && echo x", "text"], "type", :ref},
            {["type", "@e1", "text", "extra && echo x"], "type", :trailing_arg},
            {["type", "@e1", "text", "--delay", "25 && echo x"], "type", :flag_value},
            {["keyboard", "type && echo x", "text"], "keyboard", :subcommand},
            {["keyboard", "type", "text", "extra && echo x"], "keyboard", :trailing_arg},
            {["upload", "@e1", "notes.txt && echo x"], "upload", :path}
          ] do
        assert {:deny,
                %{
                  command: ^command,
                  policy_rule: :shell_metacharacters,
                  argument_role: ^role,
                  failure_category: "validation-error"
                }} = Policy.classify(args)
      end
    end

    test "global option parsing cannot shift checked arguments into payload slots" do
      for {args, role} <- [
            {[
               "fill",
               "--executable-path",
               "/tmp/browser && echo x",
               "@e1",
               "safe"
             ], :flag_value},
            {[
               "fill",
               "@e1",
               "--state",
               "/tmp/state && echo x",
               "safe"
             ], :flag_value},
            {["fill", "@e1", "--profile=work", "trailing && echo x"], :trailing_arg},
            {["type", "@e1", "--profile=work", "trailing && echo x"], :trailing_arg},
            {[
               "keyboard",
               "type",
               "--profile=work",
               "trailing && echo x"
             ], :trailing_arg}
          ] do
        assert {:deny,
                %{
                  command: command,
                  policy_rule: :shell_metacharacters,
                  argument_role: ^role
                }} = Policy.classify(args)

        assert command in ["fill", "type", "keyboard"]
      end

      assert {:deny,
              %{
                command: "fill",
                policy_rule: :shell_metacharacters,
                argument_role: :ref
              }} = Policy.classify(["--headed", "false", "fill", "bad && ref", "text"])
    end

    test "eval keeps forbidden flags and independent argv subject to validation" do
      for flag <- ["--json", "--session=other", "--namespace=other", "--allow-file-access"] do
        assert {:deny, %{failure_category: "validation-error"}} =
                 Policy.classify(["eval", "document.title || ''", flag])

        assert {:deny, %{failure_category: "validation-error"}} =
                 Policy.classify(["eval", flag])
      end

      assert {:prompt, %{command: "eval", capability: :cdp}} =
               Policy.classify(["--cdp=9222", "eval", "document.title || ''"])
    end

    test "does not exempt an option in the inline script position" do
      for option <- ["--profile=work&&echo x", "--cdp=9222||echo x", "--unknown=$(echo x)"] do
        assert {:deny, %{failure_category: "validation-error"}} =
                 Policy.classify(["eval", option, "document.title"])
      end
    end

    test "leaves JavaScript syntax validation to the backend" do
      assert {:prompt, %{command: "eval"}} = Policy.classify(["eval", "document.title; 1"])
      assert {:prompt, %{command: "eval"}} = Policy.classify(["eval", "1; cat /etc/passwd"])
    end

    test "denial details contain only fixed policy vocabulary" do
      details =
        Policy.denial_details(%{
          command: "private command && token",
          policy_rule: "private rule",
          argument_role: "Module.function/3"
        })

      assert details == %{
               code: :browser_policy_denied,
               side_effect: :not_started,
               error_owner: :browser_policy,
               error_command: "unknown",
               error_rule: "invalid_arguments",
               error_argument_role: "unknown"
             }

      refute inspect(details) =~ "private"
      refute inspect(details) =~ "Module"
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
