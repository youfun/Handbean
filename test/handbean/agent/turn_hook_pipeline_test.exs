defmodule Handbean.Agent.TurnHookPipelineTest do
  use ExUnit.Case, async: false

  alias Handbean.Agent.{Config, State, Turn}
  alias Handbean.Extension.HookPipeline

  setup do
    # Ensure Tool.Registry has the basic tools
    Enum.each(
      [
        Handbean.Tool.Builtin.Read,
        Handbean.Tool.Builtin.Bash,
        Handbean.Tool.Builtin.Edit,
        Handbean.Tool.Builtin.Write
      ],
      &Handbean.Tool.Registry.register/1
    )

    # Ensure the global Extension.Registry is running (may be started by Application)
    reg = Handbean.Extension.Registry

    unless Process.whereis(reg) do
      {:ok, _pid} = Handbean.Extension.Registry.start_link(name: reg)
    end

    # Clear any previously registered extensions/hooks for a fresh test
    Handbean.Extension.Registry.reset(reg)

    on_exit(fn ->
      Handbean.Extension.Registry.reset(reg)
    end)

    :ok
  end

  @tag :tmp_dir
  test "blocked tool produces denied result block in messages" do
    session_id = "turn-hook-#{System.unique_integer([:positive])}"

    # Register extension + blocking hook on the global registry
    ext = build_extension("test-block-ext", hooks: ["tool_call"])
    :ok = Handbean.Extension.Registry.register(Handbean.Extension.Registry, ext)

    HookPipeline.register_hook_module(
      Handbean.Extension.Registry,
      "test-block-ext",
      BlockReadOnlyHook
    )

    tmp = System.tmp_dir!() |> Path.join("turn_hook_test_#{session_id}")
    File.mkdir_p!(tmp)
    # FakeProvider's :tool_use_chain reads "test_file.txt" — create it so read would succeed
    File.write!(Path.join(tmp, "test_file.txt"), "hello world")

    on_exit(fn -> File.rm_rf(tmp) end)

    config = %Config{
      provider: Handbean.TestSupport.FakeProvider,
      model: "fake-model",
      working_directory: tmp,
      max_turns: 3,
      provider_config: %{scenario: :tool_use_chain},
      tool_timeout: 30_000
    }

    state = State.init(config, "read a file")

    opts = [session_id: session_id]
    result = Turn.run_loop(state, opts)

    # Should still complete — blocked tool yields denied result
    assert result.status in [:completed]

    # Check that a denied tool result exists
    denied_blocks =
      result.messages
      |> Enum.flat_map(fn
        %{role: :tool_result, content: content} when is_list(content) -> content
        _ -> []
      end)
      |> Enum.filter(fn block ->
        is_map(block) and block[:is_error] == true
      end)

    assert length(denied_blocks) >= 1,
           "expected denied tool result blocks, got: #{inspect(result.messages)}"

    # Halt reason must be visible to the model (not a generic "not available" string)
    denied_text = Enum.map_join(denied_blocks, " ", & &1[:content])
    assert denied_text =~ "read blocked by extension policy"
    refute denied_text =~ "is not available at this stage"

    details = hd(denied_blocks)[:details] || %{}
    assert details[:blocked_by] == :extension
  end

  @tag :tmp_dir
  test "before_agent_start halt blocks run start" do
    session_id = "turn-halt-#{System.unique_integer([:positive])}"

    ext = build_extension("test-before-agent-block", hooks: ["before_agent_start"])
    :ok = Handbean.Extension.Registry.register(Handbean.Extension.Registry, ext)

    HookPipeline.register_hook_module(
      Handbean.Extension.Registry,
      "test-before-agent-block",
      BeforeAgentStartBlockerHook
    )

    tmp = System.tmp_dir!() |> Path.join("turn_halt_test_#{session_id}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    config = %Config{
      provider: Handbean.TestSupport.FakeProvider,
      model: "fake-model",
      working_directory: tmp,
      max_turns: 3,
      provider_config: %{scenario: :simple_answer},
      tool_timeout: 30_000
    }

    state = State.init(config, "hello")
    opts = [session_id: session_id]
    result = Turn.run_loop(state, opts)

    # Run should be halted before any provider call
    assert result.status == :halted
    assert result.error =~ "BLOCKED_BY_TEST"
  end

  @tag :tmp_dir
  test "tool_call transform args changes tool input" do
    session_id = "turn-xform-#{System.unique_integer([:positive])}"

    ext = build_extension("test-tool-xform", hooks: ["tool_call"])
    :ok = Handbean.Extension.Registry.register(Handbean.Extension.Registry, ext)

    HookPipeline.register_hook_module(
      Handbean.Extension.Registry,
      "test-tool-xform",
      TransformFilePathHook
    )

    tmp = System.tmp_dir!() |> Path.join("turn_xform_test_#{session_id}")
    File.mkdir_p!(tmp)

    # Create BOTH files: the original (that FakeProvider requests) and the transformed target
    original_content = "ORIGINAL_FILE_CONTENT"
    transformed_content = "TRANSFORMED_FILE_CONTENT_MARKER"
    File.write!(Path.join(tmp, "test_file.txt"), original_content)
    File.write!(Path.join(tmp, "other_file.txt"), transformed_content)

    on_exit(fn -> File.rm_rf(tmp) end)

    config = %Config{
      provider: Handbean.TestSupport.FakeProvider,
      model: "fake-model",
      working_directory: tmp,
      max_turns: 3,
      provider_config: %{scenario: :tool_use_chain},
      tool_timeout: 30_000
    }

    state = State.init(config, "read a file")
    opts = [session_id: session_id]
    result = Turn.run_loop(state, opts)

    assert result.status in [:completed]

    # The hook transforms file_path from "test_file.txt" → "other_file.txt"
    # The read tool should have read the transformed file, so the tool_result
    # must contain the transformed content, NOT the original.
    tool_result_blocks =
      result.messages
      |> Enum.flat_map(fn
        %{role: :tool_result, content: content} when is_list(content) -> content
        _ -> []
      end)
      |> Enum.filter(fn block ->
        is_map(block) and block[:is_error] != true
      end)

    assert length(tool_result_blocks) >= 1,
           "expected tool_result blocks, got: #{inspect(result.messages)}"

    # Must contain transformed content, NOT original
    result_texts = Enum.map_join(tool_result_blocks, " ", & &1[:content])
    assert result_texts =~ transformed_content
    refute result_texts =~ original_content
  end

  test "context hook transforms system_prompt visible to provider" do
    session_id = "turn-ctx-#{System.unique_integer([:positive])}"

    ext = build_extension("test-ctx-xform", hooks: ["context"])
    :ok = Handbean.Extension.Registry.register(Handbean.Extension.Registry, ext)

    HookPipeline.register_hook_module(
      Handbean.Extension.Registry,
      "test-ctx-xform",
      ContextPromptInjectorHook
    )

    config = %Config{
      provider: Handbean.TestSupport.FakeProvider,
      model: "fake-model",
      working_directory: System.tmp_dir!(),
      max_turns: 3,
      provider_config: %{scenario: :simple_answer, notify: self()},
      tool_timeout: 30_000
    }

    state = State.init(config, "hello")
    opts = [session_id: session_id]
    result = Turn.run_loop(state, opts)

    assert result.status in [:completed]

    # The context hook prepends "HOOK_INJECTED_PROMPT_PREFIX" to system_prompt.
    # FakeProvider with notify pid sends {:provider_config, config} back to self().
    assert_receive {:provider_config, provider_config}, 1_000
    assert provider_config[:system_prompt] =~ "HOOK_INJECTED_PROMPT_PREFIX"

    # Durable config/prompt must not pick up the request-scoped transform.
    refute (result.config.system_prompt || "") =~ "HOOK_INJECTED_PROMPT_PREFIX"
  end

  test "context hook message transform is request-scoped and does not persist" do
    session_id = "turn-ctx-msgs-#{System.unique_integer([:positive])}"

    ext = build_extension("test-ctx-msgs", hooks: ["context"])
    :ok = Handbean.Extension.Registry.register(Handbean.Extension.Registry, ext)

    HookPipeline.register_hook_module(
      Handbean.Extension.Registry,
      "test-ctx-msgs",
      ContextMessageRedactorHook
    )

    original_prompt = "keep this user prompt in durable history"

    config = %Config{
      provider: Handbean.TestSupport.FakeProvider,
      model: "fake-model",
      working_directory: System.tmp_dir!(),
      max_turns: 3,
      provider_config: %{scenario: :simple_answer, notify: self()},
      tool_timeout: 30_000
    }

    state = State.init(config, original_prompt)
    result = Turn.run_loop(state, session_id: session_id)

    assert result.status in [:completed]

    assert_receive {:provider_messages, provider_messages}, 1_000

    provider_texts =
      provider_messages
      |> Enum.filter(&match?(%{role: :user}, &1))
      |> Enum.map(& &1.content)

    assert "REDACTED_FOR_PROVIDER" in provider_texts
    refute original_prompt in provider_texts

    durable_user_texts =
      result.messages
      |> Enum.filter(&match?(%{role: :user}, &1))
      |> Enum.map(& &1.content)

    assert original_prompt in durable_user_texts
    refute "REDACTED_FOR_PROVIDER" in durable_user_texts
  end

  @tag :tmp_dir
  test "active set excludes tool — blocked at execution side" do
    session_id = "turn-aset-#{System.unique_integer([:positive])}"

    # Active set: only "bash" — "read" is NOT in the set
    Handbean.Tool.Registry.set_active_for_session(session_id, ["bash"])

    # Clean up active set after test
    on_exit(fn ->
      Handbean.Tool.Registry.set_active_for_session(session_id, nil)
    end)

    tmp = System.tmp_dir!() |> Path.join("turn_aset_test_#{session_id}")
    File.mkdir_p!(tmp)
    File.write!(Path.join(tmp, "test_file.txt"), "hello world")
    on_exit(fn -> File.rm_rf(tmp) end)

    config = %Config{
      provider: Handbean.TestSupport.FakeProvider,
      model: "fake-model",
      working_directory: tmp,
      max_turns: 3,
      provider_config: %{scenario: :tool_use_chain},
      tool_timeout: 30_000
    }

    state = State.init(config, "read a file")
    opts = [session_id: session_id]
    result = Turn.run_loop(state, opts)

    assert result.status in [:completed]

    # "read" tool should be blocked because it's not in the active set
    denied_blocks =
      result.messages
      |> Enum.flat_map(fn
        %{role: :tool_result, content: content} when is_list(content) -> content
        _ -> []
      end)
      |> Enum.filter(fn block ->
        is_map(block) and block[:is_error] == true
      end)

    assert length(denied_blocks) >= 1,
           "expected denied tool result blocks (active set blocked read), got: #{inspect(result.messages)}"

    details = hd(denied_blocks)[:details] || %{}
    assert details[:blocked_by] == :active_set
  end

  # ── Helpers ──

  defp build_extension(name, opts \\ []) do
    %Handbean.Extension{
      name: name,
      root: "/abs/path/.handbean/extensions/#{name}",
      enabled: true,
      hooks: Keyword.get(opts, :hooks, []),
      tools: [],
      entry: nil,
      version: "0.1.0",
      description: nil,
      permissions: %{},
      commands: [],
      providers: [],
      metadata: %{}
    }
  end
end

defmodule BlockReadOnlyHook do
  @moduledoc false
  @behaviour Handbean.Extension.Hook

  @impl true
  def handle_event(
        %Handbean.Extension.Event{name: :tool_call, payload: %{tool_name: "read"}},
        _ctx
      ),
      do: {:halt, "read blocked by extension policy"}

  def handle_event(_event, _ctx), do: :ok
end

defmodule BeforeAgentStartBlockerHook do
  @moduledoc """
  Blocks agent startup for testing before_agent_start halt semantics.
  """
  @behaviour Handbean.Extension.Hook

  @impl true
  def handle_event(%Handbean.Extension.Event{name: :before_agent_start}, _ctx),
    do: {:halt, "BLOCKED_BY_TEST"}

  def handle_event(_event, _ctx), do: :ok
end

defmodule TransformFilePathHook do
  @moduledoc """
  Transforms tool_call file_path arg from "test_file.txt" → "other_file.txt".
  Tests tool_call transform args semantics.
  """
  @behaviour Handbean.Extension.Hook

  @impl true
  def handle_event(
        %Handbean.Extension.Event{
          name: :tool_call,
          payload: %{args: %{"file_path" => "test_file.txt"}}
        },
        _ctx
      ) do
    {:ok, %{args: %{"file_path" => "other_file.txt"}}}
  end

  def handle_event(_event, _ctx), do: :ok
end

defmodule ContextPromptInjectorHook do
  @moduledoc """
  Injects a marker string into system_prompt via context hook.
  Tests context transform system_prompt semantics.
  """
  @behaviour Handbean.Extension.Hook

  @impl true
  def handle_event(%Handbean.Extension.Event{name: :context}, _ctx) do
    {:ok, %{system_prompt: "HOOK_INJECTED_PROMPT_PREFIX"}}
  end

  def handle_event(_event, _ctx), do: :ok
end

defmodule ContextMessageRedactorHook do
  @moduledoc """
  Replaces outbound messages for the provider call only.
  Durable Turn state must keep the original user prompt.
  """
  @behaviour Handbean.Extension.Hook

  @impl true
  def handle_event(%Handbean.Extension.Event{name: :context}, _ctx) do
    {:ok, %{messages: [Handbean.Agent.Message.user("REDACTED_FOR_PROVIDER")]}}
  end

  def handle_event(_event, _ctx), do: :ok
end
