defmodule Handbean.Agent.Middleware.ToolGuardTest do
  use ExUnit.Case, async: true

  alias Handbean.Agent.{Config, Message, State}
  alias Handbean.Agent.Middleware.ToolGuard

  defp tmp_workspace(settings) do
    dir = Path.join(System.tmp_dir!(), "sigil_tool_guard_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, ".handbean"))
    File.write!(Path.join(dir, ".handbean/settings.jsonc"), Jason.encode!(settings))
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp state(settings, tool_calls, overrides \\ %{}) do
    workspace = tmp_workspace(settings)
    config = %Config{working_directory: workspace, model: "fake", middleware: []}

    %State{State.init(config, "hi") | tool_guard_overrides: overrides}
    |> State.append_messages([Message.tool_use(tool_calls)])
  end

  test "outside-workspace calls receive an exact grant only after approval" do
    workspace = tmp_workspace(%{"tools" => %{"default_mode" => "auto"}})

    external =
      Path.join(Path.dirname(workspace), "outside-#{System.unique_integer([:positive])}.txt")

    File.write!(external, "outside")
    on_exit(fn -> File.rm(external) end)

    call = %{
      type: "tool_use",
      id: "outside-read",
      name: "read",
      input: %{"file_path" => external}
    }

    config = %Config{
      working_directory: workspace,
      model: "fake",
      middleware: [],
      context: %{workspace_id: "ws", conversation_id: "conversation"}
    }

    state =
      %State{State.init(config, "hi") | tool_guard_overrides: %{}}
      |> State.append_messages([Message.tool_use([call])])

    assert {:interrupt, interrupted, data} = ToolGuard.call(:after_tool_request, state)
    assert [%{boundary: %{operation: :read, resource: %{kind: :path}}}] = data.action_requests
    assert Map.has_key?(interrupted.tool_guard_pending_grants, call.id)
    refute Map.has_key?(interrupted.tool_guard_execution_grants, call.id)

    resolved =
      ToolGuard.resolve_approval(interrupted, [
        %{
          "tool_call_id" => call.id,
          "tool_name" => call.name,
          "action" => "approve",
          "remember" => false
        }
      ])

    assert Map.has_key?(resolved.state.tool_guard_execution_grants, call.id)
    assert resolved.state.tool_guard_pending_grants == %{}
  end

  test "yolo grants outside-workspace calls without interrupting" do
    workspace = tmp_workspace(%{"tools" => %{"default_mode" => "yolo"}})

    external =
      Path.join(Path.dirname(workspace), "yolo-#{System.unique_integer([:positive])}.txt")

    File.write!(external, "outside")
    on_exit(fn -> File.rm(external) end)

    call = %{
      type: "tool_use",
      id: "yolo-read",
      name: "read",
      input: %{"file_path" => external}
    }

    config = %Config{
      working_directory: workspace,
      model: "fake",
      middleware: [],
      context: %{workspace_id: "ws", conversation_id: "conversation"}
    }

    state =
      %State{State.init(config, "hi") | tool_guard_overrides: %{}}
      |> State.append_messages([Message.tool_use([call])])

    assert %State{} = guarded = ToolGuard.call(:after_tool_request, state)
    assert %{provenance: :yolo} = guarded.tool_guard_execution_grants[call.id]
  end

  test "conversation yolo remains constrained by workspace denies and sensitive paths" do
    workspace = tmp_workspace(%{"tools" => %{"deny" => ["bash"]}})

    config = %Config{
      working_directory: workspace,
      model: "fake",
      middleware: [],
      context: %{
        permission_mode: :yolo,
        approval_mode: :yolo,
        approvals_reviewer: :user
      }
    }

    calls = [
      %{type: "tool_use", id: "denied", name: "bash", input: %{"command" => "pwd"}},
      %{type: "tool_use", id: "sensitive", name: "read", input: %{"file_path" => ".env"}}
    ]

    assert {:tool_guard_denied, guarded} =
             %State{State.init(config, "hi") | tool_guard_overrides: %{}}
             |> State.append_messages([Message.tool_use(calls)])
             |> then(&ToolGuard.call(:after_tool_request, &1))

    assert Enum.map(guarded.tool_guard_denied_calls, & &1.id) == ["denied", "sensitive"]
    assert guarded.tool_guard_execution_grants == %{}
  end

  test "mixed batches freeze already admitted calls while later approvals use the new revision" do
    workspace =
      tmp_workspace(%{
        "tools" => %{"default_mode" => "auto", "per_tool" => %{"bash" => "prompt"}}
      })

    config = %Config{
      working_directory: workspace,
      model: "fake",
      middleware: [],
      context: %{
        permission_mode: :yolo,
        permission_revision: 7,
        approval_mode: :yolo,
        approvals_reviewer: :user
      }
    }

    calls = [
      %{
        type: "tool_use",
        id: "already-admitted",
        name: "read",
        input: %{"file_path" => "README.md"}
      },
      %{type: "tool_use", id: "pending", name: "bash", input: %{"command" => "git status"}}
    ]

    state = State.init(config, "hi") |> State.append_messages([Message.tool_use(calls)])

    assert {:interrupt, interrupted, _data} = ToolGuard.call(:after_tool_request, state)

    assert %{approval_mode: :yolo, permission_revision: 7} =
             interrupted.tool_guard_admission_contexts["already-admitted"]

    refute Map.has_key?(interrupted.tool_guard_admission_contexts, "pending")

    changed = %{
      interrupted
      | config: %{
          interrupted.config
          | context: %{
              permission_mode: :prompt,
              permission_revision: 8,
              approval_mode: :prompt,
              approvals_reviewer: :user
            }
        }
    }

    resolved =
      ToolGuard.resolve_approval(changed, [
        %{
          "tool_call_id" => "pending",
          "tool_name" => "bash",
          "action" => "approve",
          "remember" => false
        }
      ])

    assert %{approval_mode: :yolo, permission_revision: 7} =
             resolved.state.tool_guard_admission_contexts["already-admitted"]

    assert %{approval_mode: :prompt, permission_revision: 8} =
             resolved.state.tool_guard_admission_contexts["pending"]
  end

  test "pending prompt switches to the AI reviewer once for the new revision" do
    interrupted =
      %{"tools" => %{"per_tool" => %{"bash" => "prompt"}}}
      |> state([
        %{type: "tool_use", id: "b1", name: "bash", input: %{"command" => "git status"}}
      ])
      |> then(&ToolGuard.call(:after_tool_request, &1))
      |> then(fn {:interrupt, interrupted, _data} -> interrupted end)

    interrupted = %{
      interrupted
      | config: %{
          interrupted.config
          | context: %{
              permission_mode: :auto_review,
              permission_revision: 1,
              approval_mode: :auto,
              approvals_reviewer: :auto_review
            }
        }
    }

    test_pid = self()

    Process.put(Handbean.Permissions.AutoReview.transport_key(), fn _request ->
      send(test_pid, :reviewed_pending_batch)

      {:ok,
       Handbean.JSON.encode!(%{
         "decisions" => [
           %{"tool_call_id" => "b1", "decision" => "approve", "rationale" => "ok"}
         ]
       })}
    end)

    on_exit(fn -> Process.delete(Handbean.Permissions.AutoReview.transport_key()) end)

    assert :auto_review = ToolGuard.pending_reconciliation(interrupted)
    assert {:ok, resolution} = ToolGuard.resolve_auto_review(interrupted)
    assert_receive :reviewed_pending_batch
    assert Enum.map(resolution.executable_calls, & &1.id) == ["b1"]

    assert %{approval_mode: :auto, permission_revision: 1} =
             resolution.state.tool_guard_admission_contexts["b1"]
  end

  test "conversation smart tightens a workspace YOLO default and invokes the reviewer" do
    test_pid = self()

    Process.put(Handbean.Permissions.AutoReview.transport_key(), fn request ->
      send(test_pid, {:reviewed_ids, Enum.map(request.action_requests, & &1.tool_call_id)})

      {:ok,
       Handbean.JSON.encode!(%{
         "decisions" => [
           %{"tool_call_id" => "read-1", "decision" => "approve", "rationale" => "ok"}
         ]
       })}
    end)

    on_exit(fn -> Process.delete(Handbean.Permissions.AutoReview.transport_key()) end)

    state =
      %{"tools" => %{"default_mode" => "yolo"}}
      |> state([
        %{type: "tool_use", id: "read-1", name: "read", input: %{"file_path" => "README.md"}}
      ])
      |> then(fn state ->
        context = %{
          permission_mode: :auto_review,
          permission_revision: 1,
          approval_mode: :auto,
          approvals_reviewer: :auto_review,
          permission_source: :conversation
        }

        %{state | config: %{state.config | context: context}}
      end)

    assert %State{status: :running} = ToolGuard.call(:after_tool_request, state)
    assert_receive {:reviewed_ids, ["read-1"]}
  end

  test "pending reconciliation keeps new policy denies out of AI and human approvals" do
    workspace =
      tmp_workspace(%{
        "tools" => %{"per_tool" => %{"bash" => "prompt", "read" => "prompt"}}
      })

    config = %Config{
      working_directory: workspace,
      model: "fake",
      middleware: [],
      context: %{permission_mode: :prompt, approval_mode: :prompt, approvals_reviewer: :user}
    }

    calls = [
      %{type: "tool_use", id: "denied", name: "bash", input: %{"command" => "pwd"}},
      %{type: "tool_use", id: "reviewed", name: "read", input: %{"file_path" => "README.md"}}
    ]

    initial =
      %State{State.init(config, "hi") | tool_guard_overrides: %{}}
      |> State.append_messages([Message.tool_use(calls)])

    assert {:interrupt, interrupted, _data} = ToolGuard.call(:after_tool_request, initial)

    File.write!(
      Handbean.WorkspaceSettings.path(workspace),
      Handbean.JSON.encode!(%{
        "tools" => %{
          "default_mode" => "yolo",
          "deny" => ["bash"],
          "per_tool" => %{"read" => "prompt"}
        }
      })
    )

    changed = %{
      interrupted
      | config: %{
          interrupted.config
          | context: %{
              permission_mode: :auto_review,
              permission_revision: 2,
              approval_mode: :auto,
              approvals_reviewer: :auto_review,
              permission_source: :conversation
            }
        }
    }

    test_pid = self()

    Process.put(Handbean.Permissions.AutoReview.transport_key(), fn request ->
      ids = Enum.map(request.action_requests, & &1.tool_call_id)
      send(test_pid, {:reviewed_ids, ids})

      {:ok,
       Handbean.JSON.encode!(%{
         "decisions" =>
           Enum.map(ids, fn id ->
             %{"tool_call_id" => id, "decision" => "approve", "rationale" => "ok"}
           end)
       })}
    end)

    on_exit(fn -> Process.delete(Handbean.Permissions.AutoReview.transport_key()) end)

    assert :auto_review = ToolGuard.pending_reconciliation(changed)
    assert {:ok, resolution} = ToolGuard.resolve_auto_review(changed)
    assert_receive {:reviewed_ids, ["reviewed"]}
    assert Enum.map(resolution.executable_calls, & &1.id) == ["reviewed"]
    assert Enum.map(resolution.denied_blocks, & &1.tool_use_id) == ["denied"]

    human =
      ToolGuard.resolve_approval(changed, [
        %{"tool_call_id" => "denied", "action" => "approve"},
        %{"tool_call_id" => "reviewed", "action" => "approve"}
      ])

    assert Enum.map(human.executable_calls, & &1.id) == ["reviewed"]
    assert Enum.map(human.denied_blocks, & &1.tool_use_id) == ["denied"]
  end

  test "duplicate tool call ids are denied before grants can collide" do
    settings = %{"tools" => %{"default_mode" => "yolo"}}

    guarded =
      state(settings, [
        %{type: "tool_use", id: "duplicate", name: "read", input: %{"file_path" => "a"}},
        %{type: "tool_use", id: "duplicate", name: "read", input: %{"file_path" => "b"}}
      ])

    assert {:tool_guard_denied, denied} = ToolGuard.call(:after_tool_request, guarded)
    assert length(denied.tool_guard_denied_calls) == 2
    assert denied.tool_guard_execution_grants == %{}
  end

  test "after_tool_request allows memory tools and denies workspace tools without a workspace" do
    config = %Config{working_directory: nil, model: "fake", middleware: []}

    memory =
      %State{State.init(config, "hi") | tool_guard_overrides: %{}}
      |> State.append_messages([
        Message.tool_use([%{type: "tool_use", id: "m1", name: "mem_recall", input: %{}}])
      ])

    assert ToolGuard.call(:after_tool_request, memory) == memory

    web =
      %State{State.init(config, "hi") | tool_guard_overrides: %{}}
      |> State.append_messages([
        Message.tool_use([
          %{
            type: "tool_use",
            id: "w1",
            name: "web_fetch",
            input: %{"url" => "https://example.com"}
          }
        ])
      ])

    assert ToolGuard.call(:after_tool_request, web) == web

    open =
      %State{State.init(config, "hi") | tool_guard_overrides: %{}}
      |> State.append_messages([
        Message.tool_use([
          %{
            type: "tool_use",
            id: "o1",
            name: "open_url",
            input: %{"url" => "https://example.com"}
          }
        ])
      ])

    assert ToolGuard.call(:after_tool_request, open) == open

    file =
      %State{State.init(config, "hi") | tool_guard_overrides: %{}}
      |> State.append_messages([
        Message.tool_use([%{type: "tool_use", id: "r1", name: "read", input: %{}}])
      ])

    assert {:tool_guard_denied, guarded} = ToolGuard.call(:after_tool_request, file)
    assert [%{id: "r1"}] = guarded.tool_guard_denied_calls
  end

  test "loads policy from canonical workspace while evaluating paths from checkout" do
    workspace = tmp_workspace(%{"tools" => %{"deny" => ["read"]}})
    checkout = tmp_workspace(%{"tools" => %{"per_tool" => %{"read" => "auto"}}})

    config = %Config{
      workspace_path: workspace,
      working_directory: checkout,
      model: "fake",
      middleware: []
    }

    state =
      %State{State.init(config, "hi") | tool_guard_overrides: %{}}
      |> State.append_messages([
        Message.tool_use([
          %{type: "tool_use", id: "r1", name: "read", input: %{"file_path" => "README.md"}}
        ])
      ])

    assert {:tool_guard_denied, guarded} = ToolGuard.call(:after_tool_request, state)
    assert [%{id: "r1"}] = guarded.tool_guard_denied_calls
  end

  test "after_tool_request passes through when all tools are auto approved" do
    settings = %{"tools" => %{"per_tool" => %{"read" => "auto"}}}
    state = state(settings, [%{type: "tool_use", id: "r1", name: "read", input: %{}}])

    assert ToolGuard.call(:after_tool_request, state) == state
  end

  test "after_tool_request returns denied tool result blocks without executing denied tools" do
    settings = %{"tools" => %{"deny" => ["bash(rm:*)"]}}

    state =
      state(settings, [
        %{type: "tool_use", id: "b1", name: "bash", input: %{"command" => "rm -rf tmp"}}
      ])

    assert {:tool_guard_denied, guarded} = ToolGuard.call(:after_tool_request, state)
    assert [%{id: "b1"}] = guarded.tool_guard_denied_calls
    assert [result] = guarded.tool_guard_result_blocks
    assert result.tool_use_id == "b1"
    assert result.is_error == true
    assert result.content =~ "Tool call denied by workspace permissions"
    refute result.content =~ "rm -rf"
  end

  test "after_tool_request interrupts when prompt approval is required" do
    settings = %{"tools" => %{"per_tool" => %{"bash" => "prompt"}}}

    state =
      state(settings, [
        %{type: "tool_use", id: "b1", name: "bash", input: %{"command" => "git status"}}
      ])

    assert {:interrupt, interrupted, data} = ToolGuard.call(:after_tool_request, state)
    assert interrupted.status == :interrupted
    assert interrupted.interrupt_data == data
    assert data.type == :tool_approval
    assert data.hitl_tool_call_ids == ["b1"]
    assert [%{tool_call_id: "b1", tool_name: "bash"}] = data.action_requests
  end

  test "a pending batch becomes resumable only when the latest policy allows every prompt" do
    interrupted =
      %{"tools" => %{"default_mode" => "prompt"}}
      |> state([
        %{type: "tool_use", id: "r1", name: "read", input: %{"file_path" => "README.md"}},
        %{type: "tool_use", id: "w1", name: "write", input: %{"file_path" => "out.txt"}}
      ])
      |> then(&ToolGuard.call(:after_tool_request, &1))
      |> then(fn {:interrupt, interrupted, _data} -> interrupted end)

    assert :pending = ToolGuard.auto_resume_decisions(interrupted)

    assert :ok =
             Handbean.WorkspaceSettings.update_permission_mode(
               interrupted.config.working_directory,
               :yolo
             )

    assert {:ok, decisions} = ToolGuard.auto_resume_decisions(interrupted)
    assert Enum.map(decisions, & &1["tool_call_id"]) == ["r1", "w1"]
    assert Enum.all?(decisions, &(&1["action"] == "approve" and &1["remember"] == false))
  end

  test "policy reconciliation preserves calls that were admitted before the wait" do
    interrupted =
      %{
        "tools" => %{
          "default_mode" => "prompt",
          "per_tool" => %{"web_fetch" => "auto"}
        }
      }
      |> state([
        %{type: "tool_use", id: "r1", name: "read", input: %{"file_path" => "README.md"}},
        %{
          type: "tool_use",
          id: "w1",
          name: "web_fetch",
          input: %{"url" => "https://example.com"}
        }
      ])
      |> then(&ToolGuard.call(:after_tool_request, &1))
      |> then(fn {:interrupt, interrupted, _data} -> interrupted end)

    settings_path = Handbean.WorkspaceSettings.path(interrupted.config.working_directory)

    File.write!(
      settings_path,
      Handbean.JSON.encode!(%{
        "tools" => %{"default_mode" => "yolo", "deny" => ["web_fetch"]}
      })
    )

    assert {:ok, decisions} = ToolGuard.auto_resume_decisions(interrupted)
    assert Enum.map(decisions, & &1["tool_call_id"]) == ["r1"]
  end

  test "yolo reconciliation keeps explicit prompts pending while computer control auto-resumes" do
    interrupted =
      %{
        "tools" => %{
          "default_mode" => "prompt",
          "per_tool" => %{"read" => "prompt"}
        }
      }
      |> state([
        %{type: "tool_use", id: "r1", name: "read", input: %{"file_path" => "README.md"}},
        %{type: "tool_use", id: "c1", name: "computer", input: %{"action" => "select"}}
      ])
      |> then(&ToolGuard.call(:after_tool_request, &1))
      |> then(fn {:interrupt, interrupted, _data} -> interrupted end)

    assert :ok =
             Handbean.WorkspaceSettings.update_permission_mode(
               interrupted.config.working_directory,
               :yolo
             )

    assert :pending = ToolGuard.auto_resume_decisions(interrupted)
  end

  test "mixed deny, prompt, and auto batches retain every classification" do
    settings = %{
      "tools" => %{
        "deny" => ["bash(rm:*)"],
        "per_tool" => %{"read" => "prompt", "web_fetch" => "auto"}
      }
    }

    calls = [
      %{type: "tool_use", id: "deny-1", name: "bash", input: %{"command" => "rm tmp"}},
      %{type: "tool_use", id: "prompt-1", name: "read", input: %{"file_path" => "x"}},
      %{
        type: "tool_use",
        id: "auto-1",
        name: "web_fetch",
        input: %{"url" => "https://example.com"}
      }
    ]

    assert {:interrupt, interrupted, data} =
             ToolGuard.call(:after_tool_request, state(settings, calls))

    assert Enum.map(interrupted.tool_guard_denied_calls, & &1.id) == ["deny-1"]
    assert Enum.map(interrupted.tool_guard_result_blocks, & &1.tool_use_id) == ["deny-1"]
    assert data.hitl_tool_call_ids == ["prompt-1"]
    assert data.auto_approved_tool_call_ids == ["auto-1"]
    assert is_binary(data.approval_batch_id)
  end

  test "approval resolution preserves hard denials and permits only classified calls" do
    settings = %{
      "tools" => %{
        "deny" => ["bash(rm:*)"],
        "per_tool" => %{"read" => "prompt", "web_fetch" => "auto"}
      }
    }

    calls = [
      %{type: "tool_use", id: "deny-1", name: "bash", input: %{"command" => "rm tmp"}},
      %{type: "tool_use", id: "prompt-1", name: "read", input: %{"file_path" => "x"}},
      %{
        type: "tool_use",
        id: "auto-1",
        name: "web_fetch",
        input: %{"url" => "https://example.com"}
      },
      %{type: "tool_use", id: "unknown-1", name: "read", input: %{"file_path" => "y"}}
    ]

    assert {:interrupt, interrupted, _data} =
             ToolGuard.call(:after_tool_request, state(settings, calls))

    resolution =
      ToolGuard.resolve_approval(interrupted, [
        %{"tool_call_id" => "prompt-1", "action" => "approve"}
      ])

    assert Enum.map(resolution.executable_calls, & &1.id) == ["prompt-1", "auto-1"]

    assert MapSet.new(Enum.map(resolution.denied_blocks, & &1.tool_use_id)) ==
             MapSet.new(["deny-1", "unknown-1"])

    assert resolution.state.status == :running
    assert resolution.state.interrupt_data == nil
  end

  test "approval resolution normalizes atom-key decisions at its boundary" do
    settings = %{"tools" => %{"per_tool" => %{"read" => "prompt"}}}
    calls = [%{type: "tool_use", id: "prompt-1", name: "read", input: %{"file_path" => "x"}}]

    assert {:interrupt, interrupted, _data} =
             ToolGuard.call(:after_tool_request, state(settings, calls))

    resolution =
      ToolGuard.resolve_approval(interrupted, [
        %{tool_call_id: "prompt-1", action: "approve", remember: false}
      ])

    assert Enum.map(resolution.executable_calls, & &1.id) == ["prompt-1"]
    assert resolution.denied_blocks == []
  end

  test "after_tool_request auto-approves browser eval in full access" do
    settings = %{"tools" => %{"default_mode" => "auto"}}

    state =
      state(settings, [
        %{type: "tool_use", id: "br1", name: "browser", input: %{"args" => ["eval", "1"]}}
      ])

    assert ToolGuard.call(:after_tool_request, state) == state
  end

  test "after_tool_request interrupts browser eval in safe mode" do
    settings = %{"tools" => %{"default_mode" => "prompt"}}

    state =
      state(settings, [
        %{type: "tool_use", id: "br1", name: "browser", input: %{"args" => ["eval", "1"]}}
      ])

    assert {:interrupt, _interrupted, data} = ToolGuard.call(:after_tool_request, state)
    assert data.hitl_tool_call_ids == ["br1"]
  end

  test "after_tool_request denies local file navigation in browser args" do
    settings = %{"tools" => %{"default_mode" => "auto"}}

    state =
      state(settings, [
        %{
          type: "tool_use",
          id: "br2",
          name: "browser",
          input: %{"args" => ["open", "file:///etc/passwd"]}
        }
      ])

    assert {:tool_guard_denied, guarded} = ToolGuard.call(:after_tool_request, state)
    assert [%{id: "br2"}] = guarded.tool_guard_denied_calls
  end

  test "after_tool_request denies bash wrapping agent-browser" do
    settings = %{"tools" => %{"default_mode" => "auto"}}

    state =
      state(settings, [
        %{
          type: "tool_use",
          id: "b3",
          name: "bash",
          input: %{"command" => "agent-browser open https://example.com"}
        }
      ])

    assert {:tool_guard_denied, guarded} = ToolGuard.call(:after_tool_request, state)
    assert [%{id: "b3"}] = guarded.tool_guard_denied_calls
  end
end
