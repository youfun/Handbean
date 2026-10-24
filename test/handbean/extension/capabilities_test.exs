defmodule Handbean.Extension.CapabilitiesTest do
  use Handbean.DataCase, async: false

  alias Handbean.Agent.{Config, ModelConfig, RunOpts}
  alias Handbean.Conversations.Collaboration
  alias Handbean.Extension.{Command, HotReloader, Provider, Registry}
  alias Handbean.WorkspaceCommand

  setup do
    root =
      Path.join(System.tmp_dir!(), "handbean-capabilities-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    {:ok, root} = Handbean.Security.PathValidator.canonicalize(root)
    a = Path.join(root, "a")
    b = Path.join(root, "b")
    user = Path.join(root, "user")
    Enum.each([a, b, user], &File.mkdir_p!/1)
    registry = :sys.get_state(Registry)

    env =
      Map.new(
        [:trust_project_code, :host, :workspaces_file, :test_provider],
        &{&1, Application.fetch_env(:handbean, &1)}
      )

    workspaces_env = System.get_env("HANDBEAN_WORKSPACES_FILE")
    Application.put_env(:handbean, :trust_project_code, true)
    Application.delete_env(:handbean, :test_provider)
    Application.put_env(:handbean, :host, %{data_dir: root, shell: false})
    Application.put_env(:handbean, :workspaces_file, Path.join(root, "workspaces.json"))
    System.put_env("HANDBEAN_WORKSPACES_FILE", Path.join(root, "workspaces.json"))
    Registry.reset(Registry)
    {:ok, workspace} = Handbean.WorkspaceStore.add(a, name: "Extension commands")
    {:ok, conversation} = Handbean.ConversationStore.create(workspace["id"])

    on_exit(fn ->
      WorkspaceCommand.cancel(conversation["id"])
      :sys.replace_state(Registry, fn _ -> registry end)

      Enum.each(env, fn
        {key, {:ok, value}} -> Application.put_env(:handbean, key, value)
        {key, :error} -> Application.delete_env(:handbean, key)
      end)

      if workspaces_env,
        do: System.put_env("HANDBEAN_WORKSPACES_FILE", workspaces_env),
        else: System.delete_env("HANDBEAN_WORKSPACES_FILE")

      File.rm_rf!(root)
    end)

    %{root: root, a: a, b: b, user: user, conversation: conversation["id"]}
  end

  test "trusted command executes through shared owner, persists output, and cannot cross checkout",
       ctx do
    fixture(ctx.a, "one")
    assert {:ok, []} = reload(ctx)
    assert [%{name: "/ext:sample:echo"}] = WorkspaceCommand.list_commands(ctx.a)
    assert [] = WorkspaceCommand.list_commands(ctx.b)
    assert {:ok, command} = WorkspaceCommand.parse("/ext:sample:echo hello world")

    assert {:ok, "/ext:sample:echo hello world"} =
             WorkspaceCommand.parse("!/ext:sample:echo hello world")

    parent = self()

    responder = fn _id, entry ->
      send(parent, {:settled, entry})
      {:ok, %{}}
    end

    assert {:ok, %{entries: [user, tool]}} =
             WorkspaceCommand.submit(ctx.conversation, command,
               operation_id: "extension-command",
               responder: responder
             )

    assert user["content"] == "/ext:sample:echo hello world"
    assert tool["tool_name"] == "/ext:sample:echo"
    assert_receive {:settled, entry}, 2_000
    assert entry["output"] == "one:hello world"
    assert entry["tool_status"] == "done"
    assert File.read!(Path.join(ctx.a, "command-result")) == "one:hello world"

    assert Handbean.WorkspaceCommand.AgentResponse.observation(entry) =~
             "/ext:sample:echo hello world"

    refute WorkspaceCommand.active?(ctx.conversation)

    assert {:ok, %{state: :existing}} =
             WorkspaceCommand.submit(ctx.conversation, command,
               operation_id: "extension-command",
               responder: responder
             )

    assert {:error, :idempotency_conflict} =
             WorkspaceCommand.submit(ctx.conversation, {:extension, "/ext:sample:echo", "other"},
               operation_id: "extension-command"
             )

    assert {:error, :not_available} = Command.execute(command, %{working_directory: ctx.b})
  end

  test "model selection runs the compiled provider through the Agent loop", ctx do
    fixture(ctx.a, "model-one")
    assert {:ok, []} = reload(ctx)
    id = "ext:sample:model/chat"
    assert Enum.any?(ModelConfig.available_models_for_workspace(ctx.a), &(&1.id == id))
    refute Enum.any?(ModelConfig.available_models_for_workspace(ctx.b), &(&1.id == id))
    refute Enum.any?(ModelConfig.all_global_models(), &(&1.id == id))
    assert {:ok, opts} = RunOpts.for_workspace(ctx.a, id)
    assert Config.from_opts(opts).provider == Provider

    assert {:ok, state} =
             Handbean.Agent.run(
               "hello",
               Keyword.merge(opts,
                 working_directory: ctx.a,
                 tools: [],
                 middleware: [],
                 skills: false,
                 builtin_memory_enabled: false,
                 streaming: true
               )
             )

    assert state.status == :completed
    assert Enum.any?(state.messages, &(Handbean.Agent.Message.text(&1) == "model-one"))
    assert File.read!(Path.join(ctx.a, "provider-result")) == "chat"
  end

  test "same-name user and two projects remain independent including global resolution", ctx do
    fixture(ctx.user, "user")
    fixture(ctx.a, "a")
    fixture(ctx.b, "b")
    assert {:ok, []} = reload(ctx)
    assert {:ok, []} = reload(ctx, project: ctx.b)
    assert command_result(ctx.a) == "a:x"
    assert command_result(ctx.b) == "b:x"
    assert {:ok, global, "chat"} = ModelConfig.resolve_global_model("ext:sample:model/chat")
    assert global.extension_scope == :global

    assert {:ok, response} =
             Provider.complete([], [], Map.put(global, :working_directory, ctx.root))

    assert Handbean.Agent.Message.text(hd(response.messages)) == "user"
    assert {:ok, free, "chat"} = RunOpts.resolve_model(nil, "ext:sample:model/chat")
    assert free.extension_scope == :global

    fixture(ctx.a, "disabled", enabled: false)
    assert {:ok, []} = reload(ctx)
    assert [] = Command.list(ctx.a)
    assert command_result(ctx.b) == "b:x"
    File.rm_rf!(Path.join(ctx.a, ".handbean/extensions/sample"))
    assert {:ok, []} = reload(ctx)
    assert command_result(ctx.a) == "user:x"
  end

  test "reload failure keeps old executable generation; success replaces and removal revokes stale config",
       ctx do
    dir = fixture(ctx.a, "old")
    assert {:ok, []} = reload(ctx)

    assert {:ok, old, "chat"} =
             ModelConfig.resolve_model_for_workspace(ctx.a, "ext:sample:model/chat")

    fixture(ctx.a, "invalid", command_name: "/ext:other:echo")
    assert {:ok, [_ | _]} = reload(ctx)
    assert command_result(ctx.a) == "old:x"
    File.write!(Path.join(dir, "extension.ex"), "defmodule Broken do this is not valid")
    assert {:ok, [_ | _]} = reload(ctx)
    assert command_result(ctx.a) == "old:x"

    fixture(ctx.a, "new")
    assert {:ok, []} = reload(ctx)
    assert command_result(ctx.a) == "new:x"
    assert {:error, reason} = Provider.complete([], [], old)
    assert reason =~ "changed"

    assert {:ok, current, "chat"} =
             ModelConfig.resolve_model_for_workspace(ctx.a, "ext:sample:model/chat")

    File.rm_rf!(dir)
    assert {:ok, []} = reload(ctx)
    assert [] = Command.list(ctx.a)
    assert {:error, _} = Provider.complete([], [], current)
  end

  test "untrusted project is not compiled and trust revocation removes visibility and execution",
       ctx do
    fixture(ctx.a, "trusted")
    assert {:ok, []} = reload(ctx, trusted_project?: false)
    assert [] = Command.list(ctx.a)
    assert {:ok, []} = reload(ctx)

    assert {:ok, config, "chat"} =
             ModelConfig.resolve_model_for_workspace(ctx.a, "ext:sample:model/chat")

    Application.put_env(:handbean, :trust_project_code, false)
    assert [] = Command.list(ctx.a)
    assert {:error, _} = Provider.complete([], [], config)
  end

  test "workspace policy and exact model membership also apply to extension models", ctx do
    fixture(ctx.a, "policy")
    assert {:ok, []} = reload(ctx)

    File.write!(
      Path.join(ctx.a, ".handbean/settings.jsonc"),
      Handbean.JSON.encode!(%{
        "models" => %{"allow" => %{"providers" => %{"other" => %{"models" => ["other"]}}}}
      })
    )

    assert {:error, _} = ModelConfig.resolve_model_for_workspace(ctx.a, "ext:sample:model/chat")
    assert {:error, _} = ModelConfig.provider_config_for(ctx.a, "ext:sample:model", "unknown")
  end

  test "manifest rename keeps the replacement commands and providers", ctx do
    dir = fixture(ctx.a, "old")
    assert {:ok, []} = reload(ctx)

    File.write!(
      Path.join(dir, "extension.json"),
      Handbean.JSON.encode!(%{
        "name" => "renamed",
        "entry" => "extension.ex",
        "commands" => [%{"name" => "echo", "description" => "Renamed echo"}],
        "providers" => [
          %{
            "name" => "model",
            "models" => [%{"id" => "chat", "name" => "Renamed chat"}]
          }
        ]
      })
    )

    File.write!(Path.join(dir, "extension.ex"), """
    defmodule Renamed.Command do
      @behaviour Handbean.Extension.Command
      def name, do: "/ext:renamed:echo"
      def execute(args, _context), do: {:ok, "renamed:" <> args}
    end
    defmodule Renamed.Provider do
      @behaviour Handbean.Extension.Provider
      def name, do: "ext:renamed:model"
      def complete(_messages, _tools, _config) do
        {:ok, %{stop_reason: :end_turn, messages: [Handbean.Agent.Message.assistant("renamed")], usage: %{input_tokens: 1, output_tokens: 1}}}
      end
    end
    """)

    assert {:ok, []} = reload(ctx)
    assert [%{name: "/ext:renamed:echo"}] = Command.list(ctx.a)

    assert Enum.any?(
             ModelConfig.available_models_for_workspace(ctx.a),
             &(&1.id == "ext:renamed:model/chat")
           )

    refute Enum.any?(
             ModelConfig.available_models_for_workspace(ctx.a),
             &String.starts_with?(&1.id, "ext:sample:")
           )
  end

  test "Web input discovers and selects commands from the shared checkout catalog", ctx do
    fixture(ctx.a, "web")
    assert {:ok, []} = reload(ctx)

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        chat_scope: :workspace,
        workspace_root: ctx.a,
        current_conversation_id: ctx.conversation,
        current_checkout_path: ctx.a,
        available_skills: [],
        input_value: ""
      }
    }

    assert {:noreply, socket} =
             HandbeanWeb.WorkspaceLive.InputEvents.handle(
               "update_input",
               %{"value" => "/ext:"},
               socket
             )

    assert [%{name: "/ext:sample:echo"}] = socket.assigns.skill_suggestions

    assert {:noreply, socket} =
             HandbeanWeb.WorkspaceLive.InputEvents.handle(
               "select_skill_suggestion",
               %{"name" => "/ext:sample:echo"},
               socket
             )

    assert socket.assigns.input_value == "/ext:sample:echo "
    assert {:ok, command} = WorkspaceCommand.parse(socket.assigns.input_value)

    assert {_socket, operation_id} =
             HandbeanWeb.WorkspaceLive.Composer.workspace_command_operation(socket, command)

    assert is_binary(operation_id)
  end

  test "command output normalizes invalid UTF-8 before applying the byte bound", ctx do
    fixture(ctx.a, "output")
    assert {:ok, []} = reload(ctx)

    assert {:ok, output, %{truncated: true}} =
             Command.execute({:extension, "/ext:sample:echo", "large-invalid"}, %{
               working_directory: ctx.a
             })

    assert String.valid?(output)
    assert byte_size(output) <= 100_000
    assert output =~ "�"
  end

  test "callback errors and deadlines become durable command errors", ctx do
    fixture(ctx.a, "errors")
    assert {:ok, []} = reload(ctx)
    parent = self()

    responder = fn _id, entry ->
      send(parent, {:settled, entry})
      {:ok, %{}}
    end

    for {argument, expected} <- [{"raise", "fixture failure"}, {"block", "Command timed out"}] do
      assert {:ok, _ack} =
               WorkspaceCommand.submit(
                 ctx.conversation,
                 {:extension, "/ext:sample:echo", argument},
                 responder: responder,
                 timeout_ms: 30
               )

      assert_receive {:settled, entry}, 2_000
      assert entry["tool_status"] == "error"
      assert entry["tool_error"] == expected
      refute WorkspaceCommand.active?(ctx.conversation)
    end
  end

  test "malformed declarations preserve the old version and cross-checkout provider configs are refused",
       ctx do
    dir = fixture(ctx.a, "old")
    assert {:ok, []} = reload(ctx)

    assert {:ok, config, "chat"} =
             ModelConfig.resolve_model_for_workspace(ctx.a, "ext:sample:model/chat")

    assert {:error, reason} =
             Provider.complete([], [], Map.put(config, :working_directory, ctx.b))

    assert reason =~ "different checkout"

    File.write!(
      Path.join(dir, "extension.json"),
      Handbean.JSON.encode!(%{"name" => "sample", "commands" => "bad"})
    )

    assert {:ok, [_ | _]} = reload(ctx)
    assert command_result(ctx.a) == "old:x"
  end

  test "notifications for multiple workspaces are all reloaded", ctx do
    a = fixture(ctx.a, "a")
    b = fixture(ctx.b, "b")

    reloader =
      start_supervised!(
        {HotReloader,
         name: __MODULE__.Reloader,
         project: ctx.a,
         user_home: ctx.user,
         preload: false,
         debounce_ms: 60_000}
      )

    HotReloader.notify_path(Path.join(a, "extension.ex"), reloader)
    HotReloader.notify_path(Path.join(b, "extension.ex"), reloader)
    _state = :sys.get_state(reloader)
    send(reloader, :reload)
    _state = :sys.get_state(reloader)
    assert command_result(ctx.a) == "a:x"
    assert command_result(ctx.b) == "b:x"
  end

  defmodule ExistingImplementation do
    def value, do: :original
  end

  test "source validation prevents nested absolute module replacement", ctx do
    dir = fixture(ctx.a, "old")
    assert {:ok, []} = reload(ctx)

    File.write!(Path.join(dir, "extension.ex"), """
    defmodule Container do
      defmodule Elixir.Handbean.Extension.CapabilitiesTest.ExistingImplementation do
        def value, do: :replaced
      end
    end
    """)

    assert {:ok, [_ | _]} = reload(ctx)
    assert ExistingImplementation.value() == :original
    assert command_result(ctx.a) == "old:x"
  end

  test "global generation budget is measured in worst-case atom allocations", ctx do
    root = Path.join(ctx.a, "atom-budget-probe")

    assert {:error, :global_atom_budget} =
             Handbean.Extension.Capabilities.reserve_generation(
               root,
               "oversized-generation",
               Handbean.Extension.Capabilities.generation_atom_budget() + 1
             )
  end

  test "source validation bounds generated module atoms per revision", ctx do
    dir = fixture(ctx.a, "old")
    assert {:ok, []} = reload(ctx)

    nested_modules =
      Enum.map_join(1..65, "\n", fn index ->
        "  defmodule Generated#{index} do\n    def value, do: #{index}\n  end"
      end)

    source = "defmodule AtomBoundedRoot do\n#{nested_modules}\nend\n"
    File.write!(Path.join(dir, "extension.ex"), source)

    assert {:ok, diagnostics} = reload(ctx)
    assert Enum.any?(diagnostics, &String.contains?(&1.message, "more than 64"))
    assert command_result(ctx.a) == "old:x"
  end

  test "static identifier validation rejects source before allocating its atoms", ctx do
    dir = fixture(ctx.a, "old")
    assert {:ok, []} = reload(ctx)

    for generation <- 1..(Handbean.Extension.Capabilities.generation_limit() - 2) do
      assert :ok =
               Handbean.Extension.Capabilities.reserve_generation(
                 dir,
                 "static-validation-reserved-#{generation}"
               )
    end

    prefix = "handbean_atom_budget_#{System.unique_integer([:positive])}"
    marker = "#{prefix}_257"

    assert_raise ArgumentError, fn -> String.to_existing_atom(marker) end

    functions =
      Enum.map_join(1..257, "\n", fn index ->
        "  def #{prefix}_#{index}, do: #{index}"
      end)

    File.write!(
      Path.join(dir, "extension.ex"),
      "defmodule Ext.Sample.AtomBudget do\n#{functions}\nend\n"
    )

    assert {:ok, diagnostics} = reload(ctx)
    assert Enum.any?(diagnostics, &String.contains?(&1.message, "static identifiers"))
    assert_raise ArgumentError, fn -> String.to_existing_atom(marker) end
    assert command_result(ctx.a) == "old:x"

    fixture(ctx.a, "new")
    assert {:ok, []} = reload(ctx)
    assert command_result(ctx.a) == "new:x"
  end

  test "invalid module shape does not consume a generation", ctx do
    dir = fixture(ctx.a, "old")
    assert {:ok, []} = reload(ctx)

    for generation <- 1..(Handbean.Extension.Capabilities.generation_limit() - 2) do
      assert :ok =
               Handbean.Extension.Capabilities.reserve_generation(
                 dir,
                 "shape-validation-reserved-#{generation}"
               )
    end

    File.write!(Path.join(dir, "extension.ex"), "# no module declarations\n")

    assert {:ok, diagnostics} = reload(ctx)

    assert Enum.any?(
             diagnostics,
             &String.contains?(&1.message, "expected_literal_top_level_modules")
           )

    assert command_result(ctx.a) == "old:x"

    fixture(ctx.a, "new")
    assert {:ok, []} = reload(ctx)
    assert command_result(ctx.a) == "new:x"
  end

  test "canonical source identity survives alias reload and manifest-only changes invalidate selection",
       ctx do
    dir = fixture(ctx.a, "old")
    assert {:ok, []} = reload(ctx)

    assert {:ok, old, "chat"} =
             ModelConfig.resolve_model_for_workspace(ctx.a, "ext:sample:model/chat")

    alias_path = Path.join(ctx.root, "alias")
    File.ln_s!(ctx.a, alias_path)
    assert {:ok, []} = reload(ctx, project: alias_path)
    assert length(Registry.capability_extensions(Registry)) == 1
    path = Path.join(dir, "extension.json")
    data = Handbean.JSON.decode!(File.read!(path))
    providers = Enum.map(data["providers"], &Map.put(&1, "base_url", "https://changed.invalid"))
    File.write!(path, Handbean.JSON.encode!(Map.put(data, "providers", providers)))
    assert {:ok, []} = reload(ctx, project: alias_path)
    assert {:error, reason} = Provider.complete([], [], old)
    assert reason =~ "changed"
    fixture(ctx.a, "disabled", enabled: false)
    assert {:ok, []} = reload(ctx)
    assert [] = Command.list(alias_path)
    assert [] = Command.list(ctx.a)
  end

  test "terminal persistence retries cannot change a completed result into a timeout", ctx do
    fixture(ctx.a, "finished")
    assert {:ok, []} = reload(ctx)
    parent = self()
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    persister = fn id, entry_id, result, _duration ->
      attempt = Agent.get_and_update(attempts, &{&1, &1 + 1})
      send(parent, {:persist_attempt, result})

      if attempt == 0 do
        {:error, :injected}
      else
        {:ok, output, _} = result

        Handbean.ConversationTranscriptStore.update(id, "workspace-command-tool-" <> entry_id, %{
          "tool_status" => "done",
          "output" => output
        })
      end
    end

    responder = fn _id, entry ->
      send(parent, {:settled, entry})
      {:ok, %{}}
    end

    assert {:ok, _} =
             WorkspaceCommand.submit(
               ctx.conversation,
               {:extension, "/ext:sample:echo", "x"},
               timeout_ms: 100,
               terminal_persister: persister,
               responder: responder
             )

    assert_receive {:persist_attempt, {:ok, "finished:x", _}}, 2_000
    assert_receive {:persist_attempt, {:ok, "finished:x", _}}, 2_000
    assert_receive {:settled, %{"output" => "finished:x"}}, 2_000
  end

  test "worktree model resolution keeps workspace policy and checkout provider separate", ctx do
    repo = Path.join(ctx.root, "repo")
    worktree = Path.join(ctx.root, "worktree")
    File.mkdir_p!(repo)
    assert {_, 0} = System.cmd("git", ["init", "-q"], cd: repo)

    assert {_, 0} =
             System.cmd(
               "git",
               [
                 "-c",
                 "user.name=Fixture",
                 "-c",
                 "user.email=fixture@example.invalid",
                 "commit",
                 "--allow-empty",
                 "-qm",
                 "fixture"
               ],
               cd: repo
             )

    assert {_, 0} =
             System.cmd("git", ["worktree", "add", "-qb", "fixture-worktree", worktree], cd: repo)

    {:ok, workspace} = Handbean.WorkspaceStore.add(repo, name: "Worktree provider")
    id = "ext:sample:model/chat"

    {:ok, conversation} =
      Handbean.ConversationStore.create(workspace["id"],
        checkout_path: worktree,
        selected_model: id
      )

    fixture(repo, "main")
    fixture(worktree, "worktree")
    assert {:ok, []} = reload(ctx, project: repo)
    assert {:ok, []} = reload(ctx, project: worktree)
    assert {:ok, opts} = RunOpts.for_workspace(repo, id, checkout_path: worktree)
    assert opts[:provider_config].extension_scope == worktree
    Handbean.PubSub.Session.subscribe(conversation["id"])
    on_exit(fn -> Handbean.TestSupport.RuntimeLifecycle.stop_run!(conversation["id"]) end)

    assert {:ok, _} =
             Handbean.Agent.Coordinator.add_message(
               conversation["id"],
               "hello",
               Keyword.merge(opts,
                 tools: [],
                 middleware: [],
                 source: :cli,
                 working_directory: worktree,
                 builtin_memory_enabled: false,
                 streaming: true
               )
             )

    assert_receive {:agent_event, %{kind: :run_end, payload: %{status: :completed}}}, 5_000
    assert File.read!(Path.join(worktree, "provider-result")) == "chat"
    refute File.exists?(Path.join(repo, "provider-result"))

    File.rm!(Path.join(worktree, "provider-result"))

    context = %{
      conversation_id: conversation["id"],
      workspace_id: workspace["id"],
      run_id: "worktree-collaboration",
      approval_mode: :yolo,
      conversation_run_opts:
        Keyword.merge(opts,
          workspace_path: repo,
          working_directory: worktree,
          model: id,
          tools: [],
          source: :cli,
          streaming: false
        )
    }

    child_id =
      "delegated-" <>
        (:crypto.hash(:sha256, :erlang.term_to_binary({conversation["id"], "worktree-provider"}))
         |> Base.encode16(case: :lower))

    Handbean.PubSub.Session.subscribe(child_id)

    assert {:ok, receipt} =
             Collaboration.create(
               %{
                 "title" => "Worktree child",
                 "message" => "Use the checkout provider",
                 "request_id" => "worktree-provider",
                 "model" => "current"
               },
               context
             )

    assert receipt.conversation == child_id
    on_exit(fn -> Handbean.TestSupport.RuntimeLifecycle.stop_run!(receipt.conversation) end)
    assert_receive {:agent_event, %{kind: :run_end, payload: %{status: :completed}}}, 5_000
    assert File.read!(Path.join(worktree, "provider-result")) == "chat"
    refute File.exists?(Path.join(repo, "provider-result"))
    assert {:ok, child} = Handbean.ConversationStore.get_metadata(receipt.conversation)
    assert child["checkout_path"] == worktree

    File.write!(
      Path.join(repo, ".handbean/settings.jsonc"),
      Handbean.JSON.encode!(%{
        "models" => %{"allow" => %{"providers" => %{"other" => %{"models" => ["other"]}}}}
      })
    )

    assert {:error, _} = RunOpts.for_workspace(repo, id, checkout_path: worktree)
  end

  defp command_result(workspace) do
    assert {:ok, result, %{}} =
             Command.execute({:extension, "/ext:sample:echo", "x"}, %{
               working_directory: workspace
             })

    result
  end

  defp reload(ctx, opts \\ []) do
    HotReloader.reload(Keyword.merge([project: ctx.a, user_home: ctx.user], opts))
  end

  defp fixture(root, result, opts \\ []) do
    dir = Path.join(root, ".handbean/extensions/sample")
    File.mkdir_p!(dir)

    manifest = %{
      "name" => "sample",
      "entry" => "extension.ex",
      "enabled" => Keyword.get(opts, :enabled, true),
      "commands" => [%{"name" => "echo", "description" => "Echo arguments"}],
      "providers" => [
        %{
          "name" => "model",
          "models" => [%{"id" => "chat", "name" => "Extension chat", "contextWindow" => 128_000}]
        }
      ]
    }

    File.write!(Path.join(dir, "extension.json"), Handbean.JSON.encode!(manifest))

    File.write!(Path.join(dir, "extension.ex"), """
    defmodule Sample.Command do
      @behaviour Handbean.Extension.Command
      def name, do: #{inspect(Keyword.get(opts, :command_name, "/ext:sample:echo"))}
      def execute("raise", _context), do: raise("fixture failure")
      def execute("block", _context), do: receive(do: (:release -> {:ok, "released"}))
      def execute("large-invalid", _context), do: {:ok, :binary.copy(<<255>>, 100_000)}
      def execute(args, context) do
        result = #{inspect(result)} <> ":" <> args
        File.write!(Path.join(context.working_directory, "command-result"), result)
        {:ok, result}
      end
    end
    defmodule Sample.Provider do
      @behaviour Handbean.Extension.Provider
      def name, do: "ext:sample:model"
      def complete(_messages, _tools, config) do
        File.write!(Path.join(config.working_directory, "provider-result"), config.model)
        {:ok, %{stop_reason: :end_turn, messages: [Handbean.Agent.Message.assistant(#{inspect(result)})], usage: %{input_tokens: 1, output_tokens: 1}}}
      end
    end
    """)

    dir
  end
end
