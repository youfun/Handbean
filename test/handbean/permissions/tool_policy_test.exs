defmodule Handbean.Permissions.ToolPolicyTest do
  use ExUnit.Case, async: true

  alias Handbean.Permissions.{Boundary, ToolPolicy}
  alias Handbean.Platform.ProcessSandbox

  defp call(name, input \\ %{}), do: %{id: "call_#{name}", name: name, input: input}

  defp bash_without_flag_mode do
    if ProcessSandbox.os_enforced?(), do: :auto, else: :prompt
  end

  describe "outside-workspace boundaries" do
    @tag :tmp_dir
    test "interactive modes prompt, yolo grants, and deny stays final", %{tmp_dir: root} do
      external =
        Path.join(Path.dirname(root), "external-#{System.unique_integer([:positive])}.txt")

      File.write!(external, "outside")
      on_exit(fn -> File.rm(external) end)

      read = call("read", %{"file_path" => external})
      context = %{working_directory: root, workspace_id: "source", conversation_id: "c1"}

      prompt = ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "prompt"}})

      assert %{decision: :prompt, requirement: %{operation: :read}} =
               ToolPolicy.assess(prompt, read, context)

      auto = ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "auto"}})

      assert %{decision: :prompt, requirement: %{operation: :read}} =
               ToolPolicy.assess(auto, read, context)

      yolo = ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "yolo"}})

      assert %{decision: :auto, requirement: %{operation: :read}} =
               ToolPolicy.assess(yolo, read, context)

      deny = ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "deny"}})
      assert %{decision: :deny} = ToolPolicy.assess(deny, read, context)
    end

    @tag :tmp_dir
    test "sensitive paths are denied even in yolo", %{tmp_dir: root} do
      sensitive = Path.join([Path.dirname(root), ".s" <> "sh", "id_rsa"])
      read = call("read", %{"file_path" => sensitive})
      context = %{working_directory: root, workspace_id: "source", conversation_id: "c1"}
      yolo = ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "yolo"}})

      assert %{decision: :deny, requirement: nil} = ToolPolicy.assess(yolo, read, context)
    end

    @tag :tmp_dir
    test "an invocation grant is bound to call id, input, resource, and operation", %{
      tmp_dir: root
    } do
      external = Path.join(Path.dirname(root), "grant-#{System.unique_integer([:positive])}.txt")
      other = external <> ".other"
      File.write!(external, "outside")
      File.write!(other, "other")

      on_exit(fn ->
        File.rm(external)
        File.rm(other)
      end)

      call = %{id: "boundary-1", name: "read", input: %{"file_path" => external}}

      context = %{
        working_directory: root,
        workspace_id: "source",
        conversation_id: "c1",
        run_id: "run-1"
      }

      requirement = Boundary.requirement(call, context)
      grant = Boundary.grant(call, context, requirement, :human)

      invocation =
        Boundary.invocation_context(
          Map.put(context, :tool_execution_grants, %{call.id => grant}),
          call
        )

      assert Boundary.path_allowed?(invocation, external, :read)
      refute Boundary.path_allowed?(invocation, external, :write)
      refute Boundary.path_allowed?(invocation, other, :read)

      changed = put_in(call, [:input, "file_path"], other)

      changed_context =
        Boundary.invocation_context(
          Map.put(context, :tool_execution_grants, %{call.id => grant}),
          changed
        )

      refute Map.has_key?(changed_context, :boundary_grant)

      wrong_id = %{call | id: "boundary-2"}

      wrong_id_context =
        Boundary.invocation_context(
          Map.put(context, :tool_execution_grants, %{call.id => grant}),
          wrong_id
        )

      refute Map.has_key?(wrong_id_context, :boundary_grant)
    end

    @tag :tmp_dir
    test "a grant rejects source identity replay and clears a stale selected grant", %{
      tmp_dir: root
    } do
      external =
        Path.join(Path.dirname(root), "identity-#{System.unique_integer([:positive])}.txt")

      File.write!(external, "outside")
      on_exit(fn -> File.rm(external) end)

      call = %{id: "identity-1", name: "read", input: %{"file_path" => external}}

      context = %{
        working_directory: root,
        workspace_id: "source-workspace",
        conversation_id: "source-conversation",
        run_id: "source-run"
      }

      requirement = Boundary.requirement(call, context)
      grant = Boundary.grant(call, context, requirement, :human)

      for {field, replayed} <- [
            workspace_id: "other-workspace",
            conversation_id: "other-conversation",
            run_id: "other-run"
          ] do
        replay_context =
          context
          |> Map.put(field, replayed)
          |> Map.put(:boundary_grant, grant)
          |> Map.put(:tool_execution_grants, %{call.id => grant})
          |> Boundary.invocation_context(call)

        refute Map.has_key?(replay_context, :boundary_grant)
        refute Map.has_key?(replay_context, :tool_execution_grants)
      end

      for {context_field, grant_field} <- [
            {:workspace_id, :source_workspace_id},
            {:conversation_id, :source_conversation_id},
            {:run_id, :run_id}
          ],
          missing <- [nil, "", " "] do
        missing_context =
          context
          |> Map.put(context_field, missing)
          |> Map.put(:tool_execution_grants, %{call.id => grant})
          |> Boundary.invocation_context(call)

        refute Map.has_key?(missing_context, :boundary_grant)

        invalid_grant = Map.put(grant, grant_field, missing)

        invalid_candidate =
          context
          |> Map.put(:tool_execution_grants, %{call.id => invalid_grant})
          |> Boundary.invocation_context(call)

        refute Map.has_key?(invalid_candidate, :boundary_grant)
      end

      cleared = Boundary.invocation_context(Map.put(context, :boundary_grant, grant), call)
      refute Map.has_key?(cleared, :boundary_grant)
    end

    @tag :tmp_dir
    test "a frozen path grant rejects file and subtree symlink replacement", %{tmp_dir: root} do
      parent = Path.dirname(root)
      first = Path.join(parent, "first-#{System.unique_integer([:positive])}")
      second = Path.join(parent, "second-#{System.unique_integer([:positive])}")
      link = Path.join(parent, "link-#{System.unique_integer([:positive])}")
      File.mkdir_p!(first)
      File.mkdir_p!(second)
      File.write!(Path.join(first, "item.txt"), "first")
      File.write!(Path.join(second, "item.txt"), "second")
      File.ln_s!(first, link)

      on_exit(fn ->
        File.rm(link)
        File.rm_rf(first)
        File.rm_rf(second)
      end)

      file_call = %{
        id: "file-link",
        name: "read",
        input: %{"file_path" => Path.join(link, "item.txt")}
      }

      file_requirement = Boundary.requirement(file_call, %{working_directory: root})
      file_grant = Boundary.grant(file_call, %{}, file_requirement, :human)

      subtree_call = %{id: "tree-link", name: "grep", input: %{"path" => link}}
      subtree_requirement = Boundary.requirement(subtree_call, %{working_directory: root})
      subtree_grant = Boundary.grant(subtree_call, %{}, subtree_requirement, :human)

      File.rm!(link)
      File.ln_s!(second, link)

      refute Boundary.path_allowed?(
               %{boundary_grant: file_grant},
               Path.join(link, "item.txt"),
               :read
             )

      refute Boundary.path_allowed?(%{boundary_grant: subtree_grant}, link, :search)

      refute Boundary.path_allowed?(
               %{boundary_grant: subtree_grant},
               Path.join(link, "item.txt"),
               :search
             )
    end

    @tag :tmp_dir
    test "default deny cannot be weakened by a per-tool prompt", %{tmp_dir: root} do
      external = Path.join(Path.dirname(root), "deny-#{System.unique_integer([:positive])}.txt")
      call = call("read", %{"file_path" => external})

      policy =
        ToolPolicy.from_settings(%{
          "tools" => %{"default_mode" => "deny", "per_tool" => %{"read" => "prompt"}}
        })

      assert %{decision: :deny, requirement: %{operation: :read}} =
               ToolPolicy.assess(policy, call, %{working_directory: root})
    end
  end

  @tag :tmp_dir
  test "unreadable or malformed settings deny execution even with prior session grants", %{
    tmp_dir: root
  } do
    path = Handbean.WorkspaceSettings.path(root)
    File.mkdir_p!(Path.dirname(path))

    for contents <- ["{broken", "[]"] do
      File.write!(path, contents)
      policy = ToolPolicy.from_workspace(root, %{"bash" => :auto}, ["bash", "schedule"])
      assert ToolPolicy.decision(policy, call("bash")) == :deny
      assert ToolPolicy.decision(policy, call("schedule", %{"action" => "list"})) == :deny
    end

    File.rm!(path)
    File.mkdir!(path)
    assert ToolPolicy.from_workspace(root) |> ToolPolicy.decision(call("write")) == :deny

    File.rmdir!(path)
    assert ToolPolicy.from_workspace(root) |> ToolPolicy.decision(call("write")) == :auto
  end

  test "malformed permission sections cannot discard restrictions and grant auto access" do
    for tools <- [nil, [], %{"deny" => "bash"}, %{"per_tool" => []}, %{"mcp" => "deny"}] do
      policy = ToolPolicy.from_settings(%{"tools" => tools}, %{"bash" => :auto}, ["bash"])
      assert ToolPolicy.decision(policy, call("bash")) == :deny
    end
  end

  test "free chat allows bounded media publication but sensitive paths still deny" do
    policy = ToolPolicy.from_workspace(nil)

    assert ToolPolicy.decision(
             policy,
             call("publish_media", %{"path" => "/tmp/browser/result.png"})
           ) == :auto

    assert ToolPolicy.decision(
             policy,
             call("publish_media", %{"path" => "/tmp/.ssh/secret.png"})
           ) == :deny
  end

  # Failure list for bash `unsandboxed: true` (written before the implementation):
  #   - full-access workspaces (`default_mode: auto`) still prompt;
  #   - read-only workspaces (`default_mode: deny`) deny;
  #   - deny rules and session deny overrides still deny;
  #   - allow rules, `per_tool: auto`, and session allow overrides do not skip the prompt,
  #     because they were granted for sandboxed execution;
  #   - only the literal boolean `true` escalates; `"true"` or `1` stays sandboxed.
  describe "unsandboxed bash" do
    defp unsandboxed(command \\ "mix test"),
      do: call("bash", %{"command" => command, "unsandboxed" => true})

    test "prompts even in full-access workspaces" do
      policy = ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "auto"}})
      assert ToolPolicy.decision(policy, unsandboxed()) == :prompt
    end

    test "is denied in read-only workspaces" do
      policy = ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "deny"}})
      assert ToolPolicy.decision(policy, unsandboxed()) == :deny
    end

    test "deny rules and session deny overrides still win" do
      policy = ToolPolicy.from_settings(%{"tools" => %{"deny" => ["bash(rm:*)"]}})
      assert ToolPolicy.decision(policy, unsandboxed("rm -rf x")) == :deny

      policy = ToolPolicy.from_settings(%{}, %{"bash" => :deny})
      assert ToolPolicy.decision(policy, unsandboxed()) == :deny
    end

    test "sandboxed grants do not skip the prompt" do
      policy =
        ToolPolicy.from_settings(
          %{"tools" => %{"allow" => ["bash"], "per_tool" => %{"bash" => "auto"}}},
          %{"bash" => :auto}
        )

      assert ToolPolicy.decision(policy, unsandboxed()) == :prompt
    end

    test "session pattern grants do not cover unsandboxed or unrelated prompts" do
      policy =
        ToolPolicy.from_settings(
          %{"tools" => %{"default_mode" => "prompt"}},
          %{},
          ["bash(mix test*)"]
        )

      assert ToolPolicy.decision(policy, call("bash", %{"command" => "mix test"})) ==
               bash_without_flag_mode()

      assert ToolPolicy.decision(policy, call("bash", %{"command" => "rm -rf tmp"})) == :prompt
      assert ToolPolicy.decision(policy, unsandboxed("mix test")) == :prompt
    end

    test "auto_review config does not skip the unsandboxed prompt" do
      policy =
        ToolPolicy.from_settings(%{
          "tools" => %{
            "default_mode" => "auto",
            "approvals_reviewer" => "auto_review",
            "allow" => ["bash"]
          }
        })

      assert ToolPolicy.decision(policy, unsandboxed()) == :prompt
    end

    test "only the boolean true escalates when an OS sandbox exists" do
      policy = ToolPolicy.from_settings(%{})
      expected = bash_without_flag_mode()

      for value <- ["true", 1, false, nil] do
        input = %{"command" => "ls", "unsandboxed" => value}
        assert ToolPolicy.decision(policy, call("bash", input)) == expected
      end
    end

    test "per_tool deny still wins over yolo and auto" do
      for mode <- ["auto", "yolo"] do
        policy =
          ToolPolicy.from_settings(%{
            "tools" => %{"default_mode" => mode, "per_tool" => %{"bash" => "deny"}}
          })

        assert ToolPolicy.decision(policy, unsandboxed()) == :deny
        assert ToolPolicy.decision(policy, call("bash", %{"command" => "ls"})) == :deny
      end
    end

    test "per_tool prompt still wins over yolo escalation" do
      policy =
        ToolPolicy.from_settings(%{
          "tools" => %{"default_mode" => "yolo", "per_tool" => %{"bash" => "prompt"}}
        })

      assert ToolPolicy.decision(policy, unsandboxed()) == :prompt
      assert ToolPolicy.decision(policy, call("bash", %{"command" => "ls"})) == :prompt
    end
  end

  describe "bash without an OS sandbox" do
    unless ProcessSandbox.os_enforced?() do
      test "prompts in full-access workspaces and auto-approves in yolo" do
        auto = ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "auto"}})
        assert ToolPolicy.decision(auto, call("bash", %{"command" => "ls"})) == :prompt

        yolo = ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "yolo"}})
        assert ToolPolicy.decision(yolo, call("bash", %{"command" => "ls"})) == :auto
      end

      test "deny still wins and sandboxed grants do not skip the prompt" do
        denied = ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "deny"}})
        assert ToolPolicy.decision(denied, call("bash", %{"command" => "ls"})) == :deny

        granted =
          ToolPolicy.from_settings(
            %{"tools" => %{"allow" => ["bash"], "per_tool" => %{"bash" => "auto"}}},
            %{"bash" => :auto},
            ["bash"]
          )

        assert ToolPolicy.decision(granted, call("bash", %{"command" => "ls"})) == :prompt
      end
    end
  end

  # Failure list for `task_status` `action: "apply"` (subagent worktree diff → workspace):
  #   - prompts even with full access and a `task_status` allow grant;
  #   - denied in read-only workspaces;
  #   - other actions (list/get/message/discard) follow the normal policy.
  describe "subagent worktree apply" do
    test "prompts despite full access or grants, denies in read-only" do
      apply = call("task_status", %{"action" => "apply", "child_conversation_id" => "c"})

      policy =
        ToolPolicy.from_settings(
          %{"tools" => %{"default_mode" => "auto", "per_tool" => %{"task_status" => "auto"}}},
          %{"task_status" => :auto}
        )

      assert ToolPolicy.decision(policy, apply) == :prompt

      policy = ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "deny"}})
      assert ToolPolicy.decision(policy, apply) == :deny
    end

    test "other actions are not escalated" do
      policy = ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "auto"}})

      for action <- ~w(list get message discard) do
        assert ToolPolicy.decision(policy, call("task_status", %{"action" => action})) == :auto
      end
    end
  end

  describe "from_settings/2" do
    test "defaults to auto for missing or old settings" do
      assert ToolPolicy.from_settings(%{}) |> ToolPolicy.decision(call("bash")) ==
               bash_without_flag_mode()

      old_settings = %{"tools" => %{"beam" => %{"auto" => true}, "explicit" => []}}
      assert ToolPolicy.from_settings(old_settings) |> ToolPolicy.decision(call("edit")) == :auto
    end

    test "applies precedence deny > per_tool > allow > default_mode" do
      settings = %{
        "tools" => %{
          "default_mode" => "prompt",
          "allow" => ["bash", "mem_*"],
          "deny" => ["bash(rm:*)"],
          "per_tool" => %{"bash" => "auto", "write" => "deny", "read" => "prompt"}
        }
      }

      policy = ToolPolicy.from_settings(settings)

      assert ToolPolicy.decision(policy, call("bash", %{"command" => "rm -rf tmp"})) == :deny

      assert ToolPolicy.decision(policy, call("bash", %{"command" => "git status"})) ==
               bash_without_flag_mode()

      assert ToolPolicy.decision(policy, call("write")) == :deny
      assert ToolPolicy.decision(policy, call("read")) == :prompt
      assert ToolPolicy.decision(policy, call("mem_recall")) == :auto
      assert ToolPolicy.decision(policy, call("unknown")) == :prompt
    end

    test "session overrides deny before workspace policy" do
      policy =
        ToolPolicy.from_settings(
          %{"tools" => %{"default_mode" => "auto", "per_tool" => %{"bash" => "auto"}}},
          %{"bash" => :deny}
        )

      assert ToolPolicy.decision(policy, call("bash", %{"command" => "git status"})) == :deny
    end

    test "invalid approval modes deny rather than grant execution" do
      settings = %{
        "tools" => %{"default_mode" => "wat", "per_tool" => %{"bash" => "wat"}}
      }

      policy = ToolPolicy.from_settings(settings)
      assert ToolPolicy.decision(policy, call("bash")) == :deny
      assert ToolPolicy.decision(policy, call("other")) == :deny
    end

    test "mount tools auto-run in full access and prompt in safe mode" do
      auto_policy = ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "auto"}})
      assert ToolPolicy.decision(auto_policy, call("ext__mount__apply")) == :auto
      assert ToolPolicy.decision(auto_policy, call("ext__mount__drop")) == :auto

      prompt_policy = ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "prompt"}})
      assert ToolPolicy.decision(prompt_policy, call("ext__mount__apply")) == :prompt
      assert ToolPolicy.decision(prompt_policy, call("ext__mount__drop")) == :prompt

      configured =
        ToolPolicy.from_settings(%{
          "tools" => %{"per_tool" => %{"ext__mount__apply" => "auto"}}
        })

      assert ToolPolicy.decision(configured, call("ext__mount__apply")) == :auto
    end

    test "mix_project prompts in auto workspaces but honors deny and allow" do
      auto = ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "auto"}})

      assert ToolPolicy.decision(auto, call("mix_project", %{"action" => "compile"})) ==
               :prompt

      denied =
        ToolPolicy.from_settings(%{
          "tools" => %{"default_mode" => "auto", "deny" => ["mix_project"]}
        })

      assert ToolPolicy.decision(denied, call("mix_project", %{"action" => "compile"})) ==
               :deny

      session =
        ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "auto"}}, %{
          "mix_project" => :auto
        })

      assert ToolPolicy.decision(session, call("mix_project", %{"action" => "compile"})) ==
               :auto

      always =
        ToolPolicy.from_settings(%{
          "tools" => %{"default_mode" => "auto", "allow" => ["mix_project"]}
        })

      assert ToolPolicy.decision(always, call("mix_project", %{"action" => "compile"})) ==
               :auto
    end

    test "run_elixir_script prompts in auto workspaces but honors deny and allow" do
      auto = ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "auto"}})

      assert ToolPolicy.decision(auto, call("run_elixir_script", %{"path" => "a.exs"})) ==
               :prompt

      denied =
        ToolPolicy.from_settings(%{
          "tools" => %{"default_mode" => "auto", "deny" => ["run_elixir_script"]}
        })

      assert ToolPolicy.decision(denied, call("run_elixir_script", %{"path" => "a.exs"})) ==
               :deny

      session =
        ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "auto"}}, %{
          "run_elixir_script" => :auto
        })

      assert ToolPolicy.decision(session, call("run_elixir_script", %{"path" => "a.exs"})) ==
               :auto

      always =
        ToolPolicy.from_settings(%{
          "tools" => %{"default_mode" => "auto", "allow" => ["run_elixir_script"]}
        })

      assert ToolPolicy.decision(always, call("run_elixir_script", %{"path" => "a.exs"})) ==
               :auto
    end

    test "read-only database schema inspection remains automatic" do
      for mode <- ["auto", "yolo"] do
        policy = ToolPolicy.from_settings(%{"tools" => %{"default_mode" => mode}})

        assert ToolPolicy.decision(
                 policy,
                 call("ext__beam__db_schema", %{"operation" => "list_tables"})
               ) == :auto
      end
    end

    test "raw SQL prompts in auto workspaces but honors explicit authorization" do
      sql_call = call("ext__beam__sql", %{"query" => "UPDATE users SET admin = 1"})
      auto = ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "auto"}})
      assert ToolPolicy.decision(auto, sql_call) == :prompt

      read_only = ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "deny"}})
      assert ToolPolicy.decision(read_only, sql_call) == :deny

      denied =
        ToolPolicy.from_settings(%{
          "tools" => %{"default_mode" => "auto", "deny" => ["ext__beam__sql"]}
        })

      assert ToolPolicy.decision(denied, sql_call) == :deny

      allowed =
        ToolPolicy.from_settings(%{
          "tools" => %{"default_mode" => "auto", "allow" => ["ext__beam__sql"]}
        })

      assert ToolPolicy.decision(allowed, sql_call) == :auto
    end

    test "system open and share tools prompt in full access unless explicitly allowed or denied" do
      auto = ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "auto"}})

      assert ToolPolicy.decision(auto, call("open_url", %{"url" => "https://a.com"})) ==
               :prompt

      assert ToolPolicy.decision(auto, call("open_file", %{"path" => "a.pdf"})) ==
               :prompt

      assert ToolPolicy.decision(auto, call("share_file", %{"path" => "a.pdf"})) ==
               :prompt

      assert ToolPolicy.decision(
               auto,
               call("device_calendar", %{"calendar_action" => "list_events"})
             ) ==
               :prompt

      assert ToolPolicy.decision(auto, call("device_alarm", %{"hour" => 7, "minute" => 30})) ==
               :prompt

      # "Always allow" appends to the workspace allow list; only that tool changes.
      always =
        ToolPolicy.from_settings(%{
          "tools" => %{"default_mode" => "auto", "allow" => ["open_url"]}
        })

      assert ToolPolicy.decision(always, call("open_url", %{"url" => "https://a.com"})) ==
               :auto

      assert ToolPolicy.decision(always, call("open_file", %{"path" => "a.pdf"})) ==
               :prompt

      assert ToolPolicy.decision(always, call("share_file", %{"path" => "a.pdf"})) ==
               :prompt

      # "Allow for this session" writes a session override.
      session =
        ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "auto"}}, %{
          "share_file" => :auto
        })

      assert ToolPolicy.decision(session, call("share_file", %{"path" => "a.pdf"})) ==
               :auto

      assert ToolPolicy.decision(session, call("open_url", %{"url" => "https://a.com"})) ==
               :prompt

      denied =
        ToolPolicy.from_settings(%{
          "tools" => %{"default_mode" => "auto", "deny" => ["open_url"]}
        })

      assert ToolPolicy.decision(denied, call("open_url", %{"url" => "https://a.com"})) ==
               :deny

      per_tool_denied =
        ToolPolicy.from_settings(%{
          "tools" => %{
            "default_mode" => "auto",
            "allow" => ["open_file"],
            "per_tool" => %{"open_file" => "deny"}
          }
        })

      assert ToolPolicy.decision(per_tool_denied, call("open_file", %{"path" => "a.pdf"})) ==
               :deny

      session_denied =
        ToolPolicy.from_settings(
          %{"tools" => %{"default_mode" => "auto", "allow" => ["open_url"]}},
          %{"open_url" => :deny}
        )

      assert ToolPolicy.decision(
               session_denied,
               call("open_url", %{"url" => "https://a.com"})
             ) == :deny
    end

    test "system open and share tools still prompt in safe mode and honor allow rules there" do
      prompt = ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "prompt"}})

      assert ToolPolicy.decision(prompt, call("open_url", %{"url" => "https://a.com"})) ==
               :prompt

      allowed =
        ToolPolicy.from_settings(%{
          "tools" => %{"default_mode" => "prompt", "allow" => ["open_url"]}
        })

      assert ToolPolicy.decision(allowed, call("open_url", %{"url" => "https://a.com"})) ==
               :auto
    end

    test "full access skips capability prompts but keeps capability denies" do
      policy = ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "auto"}})

      assert ToolPolicy.decision(
               policy,
               call("browser", %{"args" => ["open", "https://example.com"]})
             ) ==
               :auto

      assert ToolPolicy.decision(policy, call("browser", %{"args" => ["eval", "1"]})) == :auto

      assert ToolPolicy.decision(policy, call("browser", %{"args" => ["cookies", "get"]})) ==
               :auto

      assert ToolPolicy.decision(
               policy,
               call("browser", %{"args" => ["open", "file:///etc/passwd"]})
             ) == :deny
    end

    test "safe mode still prompts for browser sensitive families" do
      policy = ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "prompt"}})

      assert ToolPolicy.decision(policy, call("browser", %{"args" => ["eval", "1"]})) == :prompt

      assert ToolPolicy.decision(policy, call("browser", %{"args" => ["eval", "-h"]})) ==
               :prompt

      assert ToolPolicy.decision(
               policy,
               call("browser", %{"args" => ["upload", "@e1", "-h"]})
             ) == :prompt

      assert ToolPolicy.decision(policy, call("browser", %{"args" => ["cookies", "get"]})) ==
               :prompt
    end

    test "browser classification takes precedence over a generic allow rule" do
      policy =
        ToolPolicy.from_settings(%{
          "tools" => %{"default_mode" => "prompt", "allow" => ["browser"]}
        })

      assert ToolPolicy.decision(policy, call("browser", %{"args" => ["eval", "1"]})) ==
               :prompt

      assert ToolPolicy.decision(
               policy,
               call("browser", %{"args" => ["open", "file:///etc/passwd"]})
             ) == :deny
    end

    test "explicit workspace policy still wins over browser capability defaults" do
      deny_eval =
        ToolPolicy.from_settings(%{
          "tools" => %{"default_mode" => "auto", "deny" => ["browser(eval:*)"]}
        })

      assert ToolPolicy.decision(deny_eval, call("browser", %{"args" => ["eval", "1"]})) == :deny

      auto_eval =
        ToolPolicy.from_settings(%{
          "tools" => %{"default_mode" => "auto", "per_tool" => %{"browser" => "auto"}}
        })

      assert ToolPolicy.decision(auto_eval, call("browser", %{"args" => ["eval", "1"]})) == :auto
    end

    test "desktop does not classify native action/url as argv" do
      policy = ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "auto"}})

      assert ToolPolicy.decision(
               policy,
               call("browser", %{"action" => "open", "url" => "https://example.org"})
             ) == :deny
    end

    test "denies bash wrapping agent-browser even when default_mode is auto" do
      policy = ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "auto"}})

      assert ToolPolicy.decision(
               policy,
               call("bash", %{"command" => "agent-browser open https://example.com"})
             ) == :deny

      assert ToolPolicy.decision(
               policy,
               call("bash", %{"command" => "npx agent-browser snapshot -i"})
             ) == :deny

      assert ToolPolicy.decision(policy, call("bash", %{"command" => "ls"})) ==
               bash_without_flag_mode()
    end
  end

  describe "yolo" do
    test "auto-approves prompts and capability denies, but not env or credential paths" do
      policy = ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "yolo"}})

      assert ToolPolicy.decision(
               policy,
               call("bash", %{"command" => "mix test", "unsandboxed" => true})
             ) == :auto

      assert ToolPolicy.decision(
               policy,
               call("task_status", %{"action" => "apply"})
             ) == :auto

      assert ToolPolicy.decision(policy, call("run_elixir_script")) == :auto
      assert ToolPolicy.decision(policy, call("mix_project")) == :auto
      assert ToolPolicy.decision(policy, call("ext__term_send")) == :auto

      assert ToolPolicy.decision(policy, call("ext__beam__sql", %{"query" => "DROP TABLE users"})) ==
               :auto

      assert ToolPolicy.decision(
               policy,
               call("bash", %{"command" => "agent-browser open https://example.com"})
             ) == :auto

      assert ToolPolicy.decision(policy, call("read", %{"file_path" => ".env"})) == :deny

      assert ToolPolicy.decision(policy, call("bash", %{"command" => "cat ~/.ssh/id_rsa"})) ==
               :deny
    end

    test "explicit deny rules still win" do
      policy =
        ToolPolicy.from_settings(%{
          "tools" => %{"default_mode" => "yolo", "deny" => ["bash"]}
        })

      assert ToolPolicy.decision(policy, call("bash", %{"command" => "ls"})) == :deny
      assert ToolPolicy.decision(policy, call("write")) == :auto
    end
  end

  describe "sensitive paths" do
    test "allow, session allow, and unsandboxed cannot turn a credential path into prompt or auto" do
      policy =
        ToolPolicy.from_settings(
          %{
            "tools" => %{
              "default_mode" => "auto",
              "allow" => ["read", "bash"],
              "per_tool" => %{"read" => "auto", "bash" => "auto"}
            }
          },
          %{"read" => :auto, "bash" => :auto},
          ["read", "bash"]
        )

      for call <- [
            call("read", %{"file_path" => ".env"}),
            call("read", %{"file_path" => "~/.ssh/id_rsa"}),
            call("bash", %{"command" => "cat ~/.ssh/id_rsa"}),
            call("bash", %{"command" => "cat ~/.ssh/id_rsa", "unsandboxed" => true})
          ] do
        decision = ToolPolicy.decision(policy, call)
        assert decision == :deny
        refute decision in [:prompt, :auto]
      end

      assert ToolPolicy.decision(policy, call("read", %{"file_path" => "lib/app.ex"})) == :auto

      assert ToolPolicy.decision(policy, call("bash", %{"command" => "ls lib"})) ==
               bash_without_flag_mode()
    end

    test "browser file input and output paths cannot access credentials" do
      policy =
        ToolPolicy.from_settings(%{
          "tools" => %{"default_mode" => "yolo", "allow" => ["browser"]}
        })

      for args <- [
            ["upload", "@e1", "~/.ssh/id_rsa"],
            ["--profile", "work", "upload", "@e1", "~/.ssh/id_rsa"],
            ["screenshot", ".env"],
            ["--screenshot-dir=.ssh", "screenshot"],
            ["pdf", "secrets/client.key"],
            ["pdf", "--profile", "work", ".env.production"],
            ["download", "@e2", "../credentials/token.p12"],
            ["wait", "--download", ".env.production"]
          ] do
        assert ToolPolicy.decision(policy, call("browser", %{"args" => args})) == :deny
      end
    end
  end
end
