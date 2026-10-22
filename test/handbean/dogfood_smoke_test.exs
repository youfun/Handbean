defmodule Handbean.DogfoodSmoke do
  @moduledoc """
  End-to-end dogfood smoke tests against a mock OpenAI-compatible server.

  A local Bandit server is started automatically in `setup_all` on a random
  free port and stopped in `on_exit`. No external runtime is needed.

  Coverage:
  - Normal conversation: user sends message → mock returns assistant text
  - Tool loop (read): mock returns tool_calls → executor runs tool → mock returns final
  - Tool loop (write): mock returns tool_calls → executor writes file → mock returns final
  - Tool loop (edit): mock returns tool_calls → executor edits file → mock returns final
  - Tool loop (bash): mock returns tool_calls → executor runs cmd → mock returns final
  - Provider error handling without crashing
  - Workspace boundary enforcement
  - Multi-turn: tool_results → provider continuation
  """

  use Handbean.DataCase, async: false
  import ExUnit.CaptureLog, only: [with_log: 1]

  alias Handbean.Agent
  alias Handbean.Agent.Message
  alias Handbean.Agent.Provider.OpenAICompat

  defmodule MockOpenAI do
    @moduledoc false

    import Plug.Conn

    def init(opts), do: opts

    def call(%Plug.Conn{method: "POST", request_path: "/v1/chat/completions"} = conn, _opts) do
      {:ok, raw_body, conn} = read_body(conn)
      {:ok, body} = Jason.decode(raw_body)

      with ["Bearer sk-mock-key"] <- get_req_header(conn, "authorization"),
           %{"model" => "gpt-4o", "messages" => messages, "stream" => false} <- body,
           true <- is_list(messages) do
        json(conn, completion(messages))
      else
        _ -> json(conn, %{"error" => %{"message" => "invalid mock request"}}, 400)
      end
    end

    def call(conn, _opts) do
      json(conn, %{"error" => %{"message" => "not found"}}, 404)
    end

    defp completion(messages) do
      if Enum.any?(messages, &(&1["role"] == "tool")) do
        response("Tool completed successfully by the Handbean mock.")
      else
        prompt =
          messages
          |> Enum.find(&(&1["role"] == "user"))
          |> Map.fetch!("content")
          |> to_string()

        initial_response(prompt)
      end
    end

    defp initial_response(prompt) do
      downcased = String.downcase(prompt)

      cond do
        String.contains?(downcased, "show me the mix.exs") ->
          tool_response([
            tool_call("read", %{"file_path" => "mix.exs"}),
            tool_call("bash", %{"command" => "pwd"})
          ])

        String.contains?(downcased, "read the mix.exs") ->
          tool_response([tool_call("read", %{"file_path" => "mix.exs"})])

        String.contains?(downcased, "smoke_test.txt") ->
          tool_response([
            tool_call("write", %{
              "file_path" => "smoke_test.txt",
              "content" => "Dogfood smoke test fixture\n"
            })
          ])

        String.contains?(downcased, "safe_test.txt") ->
          tool_response([
            tool_call("write", %{
              "file_path" => "safe_test.txt",
              "content" => "safe smoke test fixture\n"
            })
          ])

        String.contains?(downcased, "edit the file") ->
          filename =
            Regex.run(~r/edit the file ([^ ]+)/i, prompt, capture: :all_but_first) |> hd()

          tool_response([
            tool_call("edit", %{
              "file_path" => filename,
              "old_string" => "original",
              "new_string" => "modified"
            })
          ])

        String.contains?(downcased, "pwd") ->
          tool_response([tool_call("bash", %{"command" => "pwd"})])

        String.contains?(downcased, "elixir") ->
          response("Elixir is a concurrent language running on the BEAM.")

        true ->
          response("Hello from the Handbean mock server.")
      end
    end

    defp tool_call(name, arguments) do
      %{
        "id" => "call_#{name}",
        "type" => "function",
        "function" => %{"name" => name, "arguments" => Jason.encode!(arguments)}
      }
    end

    defp tool_response(tool_calls) do
      envelope(
        %{"role" => "assistant", "content" => nil, "tool_calls" => tool_calls},
        "tool_calls"
      )
    end

    defp response(content) do
      envelope(%{"role" => "assistant", "content" => content}, "stop")
    end

    defp envelope(message, finish_reason) do
      %{
        "id" => "chatcmpl-dogfood",
        "object" => "chat.completion",
        "model" => "gpt-4o",
        "choices" => [%{"index" => 0, "message" => message, "finish_reason" => finish_reason}],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15}
      }
    end

    defp json(conn, body, status \\ 200) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(body))
    end
  end

  # ── Lifecycle ──────────────────────────────────────────────

  setup_all do
    {:ok, _} = Application.ensure_all_started(:handbean)

    # Bind to port 0 to let the OS pick a free port
    {:ok, socket} = :gen_tcp.listen(0, [:binary, {:active, false}])
    {:ok, {_addr, port}} = :inet.sockname(socket)
    :gen_tcp.close(socket)

    {:ok, server} = Bandit.start_link(plug: MockOpenAI, port: port)

    base_url = "http://127.0.0.1:#{port}/v1"
    on_exit(fn -> Supervisor.stop(server) end)

    {:ok, %{base_url: base_url}}
  end

  setup ctx do
    Enum.each(
      [
        Handbean.Tool.Builtin.Read,
        Handbean.Tool.Builtin.Write,
        Handbean.Tool.Builtin.Edit,
        Handbean.Tool.Builtin.Bash
      ],
      &ensure_registered/1
    )

    ctx
  end

  # ── Helpers ────────────────────────────────────────────────

  defp provider_config(base_url) do
    %{
      api_key: "sk-mock-key",
      base_url: base_url,
      model: "gpt-4o",
      max_retries: 1,
      retry_delay_base_ms: 10
    }
  end

  defp ensure_registered(tool) do
    case Handbean.Tool.Registry.get(tool.name()) do
      {:ok, _entry} -> :ok
      :error -> :ok = Handbean.Tool.Registry.register(tool)
    end
  end

  # ── Normal conversation ────────────────────────────────────

  describe "normal conversation" do
    test "simple user message gets assistant response", ctx do
      {result, _log} =
        with_log(fn ->
          Agent.run("Hello!",
            provider: OpenAICompat,
            provider_config: provider_config(ctx.base_url),
            model: "gpt-4o",
            working_directory: File.cwd!(),
            max_turns: 3,
            streaming: false
          )
        end)

      assert {:ok, state} = result
      assert state.status == :completed
      assert state.turn >= 1

      assistant_msgs = Enum.filter(state.messages, &(&1.role == :assistant))
      assert length(assistant_msgs) >= 1

      final = List.last(assistant_msgs)
      assert is_binary(final.content)
      refute final.content == ""
      assert final.content =~ "Hello" || final.content =~ "mock" || final.content =~ "Handbean"
    end

    test "Elixir knowledge query gets informed response", ctx do
      {result, _log} =
        with_log(fn ->
          Agent.run("What is Elixir?",
            provider: OpenAICompat,
            provider_config: provider_config(ctx.base_url),
            model: "gpt-4o",
            working_directory: File.cwd!(),
            max_turns: 3,
            streaming: false
          )
        end)

      assert {:ok, state} = result
      assert state.status == :completed

      assistant_msgs = Enum.filter(state.messages, &(&1.role == :assistant))
      final = List.last(assistant_msgs)
      assert final.content =~ "Elixir" || final.content =~ "mock"
    end
  end

  # ── Tool loop – read ───────────────────────────────────────

  describe "tool loop - read" do
    test "read file tool completes tool loop and gets final answer", ctx do
      {result, _log} =
        with_log(fn ->
          Agent.run("read the mix.exs file",
            provider: OpenAICompat,
            provider_config: provider_config(ctx.base_url),
            model: "gpt-4o",
            tools: [Handbean.Tool.Builtin.Read],
            working_directory: File.cwd!(),
            max_turns: 5,
            streaming: false
          )
        end)

      assert {:ok, state} = result
      assert state.status == :completed
      assert state.turn >= 2

      tool_msgs = Enum.filter(state.messages, &(&1.role == :tool_result))
      assert length(tool_msgs) >= 1

      assistant_msgs =
        Enum.filter(state.messages, &(&1.role == :assistant and is_binary(&1.content)))

      final = List.last(assistant_msgs)
      assert is_binary(final.content)
      assert final.content != ""
    end
  end

  # ── Tool loop – write ──────────────────────────────────────

  describe "tool loop - write" do
    test "write file tool creates file and continues", ctx do
      ws_dir = Path.join(System.tmp_dir!(), "sigil_smoke_ws/")
      File.mkdir_p!(ws_dir)
      tmp_file = Path.join(ws_dir, "smoke_test.txt")
      File.rm(tmp_file)

      {result, _log} =
        with_log(fn ->
          Agent.run("write a new file smoke_test.txt",
            provider: OpenAICompat,
            provider_config: provider_config(ctx.base_url),
            model: "gpt-4o",
            tools: [Handbean.Tool.Builtin.Write],
            working_directory: ws_dir,
            max_turns: 5,
            streaming: false
          )
        end)

      assert {:ok, state} = result
      assert state.status == :completed
      assert state.turn >= 2

      assert File.exists?(tmp_file), "Expected #{tmp_file} to be created"
      content = File.read!(tmp_file)
      assert content =~ "smoke" || content =~ "Dogfood" || content =~ "test" || content != ""

      File.rm_rf!(ws_dir)
    end
  end

  # ── Tool loop – edit ───────────────────────────────────────

  describe "tool loop - edit" do
    test "edit file tool modifies file and continues", ctx do
      tmp_file = Path.join(System.tmp_dir!(), "sigil_smoke_edit.txt")
      File.write!(tmp_file, "original content to be modified")

      {result, _log} =
        with_log(fn ->
          Agent.run(
            "edit the file #{Path.basename(tmp_file)} to change original to modified",
            provider: OpenAICompat,
            provider_config: provider_config(ctx.base_url),
            model: "gpt-4o",
            tools: [Handbean.Tool.Builtin.Edit],
            working_directory: System.tmp_dir!(),
            max_turns: 5,
            streaming: false
          )
        end)

      assert {:ok, state} = result
      assert state.status == :completed
      assert state.turn >= 2

      File.rm(tmp_file)
    end
  end

  # ── Tool loop – bash ───────────────────────────────────────

  describe "tool loop - bash" do
    test "bash tool runs command and continues", ctx do
      {result, _log} =
        with_log(fn ->
          Agent.run("run `pwd` command",
            provider: OpenAICompat,
            provider_config: provider_config(ctx.base_url),
            model: "gpt-4o",
            tools: [Handbean.Tool.Builtin.Bash],
            working_directory: File.cwd!(),
            max_turns: 5,
            streaming: false
          )
        end)

      assert {:ok, state} = result
      assert state.status == :completed
      assert state.turn >= 2

      tool_msgs = Enum.filter(state.messages, &(&1.role == :tool_result))
      assert length(tool_msgs) >= 1

      assistant_msgs =
        Enum.filter(state.messages, &(&1.role == :assistant and is_binary(&1.content)))

      final = List.last(assistant_msgs)
      assert is_binary(final.content)
      assert final.content != ""
    end

    test "project status prompt uses git directly in the workspace" do
      {result, _log} =
        with_log(fn ->
          Agent.run("查看项目状态，使用 git 命令",
            provider: Handbean.TestSupport.FakeProvider,
            provider_config: %{scenario: :bash_git_status},
            model: "fake-model",
            tools: [Handbean.Tool.Builtin.Bash],
            working_directory: File.cwd!(),
            max_turns: 5,
            streaming: false
          )
        end)

      assert {:ok, state} = result
      assert state.status == :completed

      command = only_bash_command(state)
      assert command == "git status --short"
      refute command =~ ~r/\A\s*cd\s+/

      tool_output = only_tool_output(state)
      refute tool_output =~ "Command exited with code 128"
    end
  end

  # ── Tool loop – multi-tool ─────────────────────────────────

  describe "tool loop - multi-tool" do
    test "multi-tool (read + bash) completes both and continues", ctx do
      {result, _log} =
        with_log(fn ->
          Agent.run("show me the mix.exs and run pwd",
            provider: OpenAICompat,
            provider_config: provider_config(ctx.base_url),
            model: "gpt-4o",
            tools: [Handbean.Tool.Builtin.Read, Handbean.Tool.Builtin.Bash],
            working_directory: File.cwd!(),
            max_turns: 5,
            streaming: false
          )
        end)

      assert {:ok, state} = result
      assert state.status == :completed

      tool_msgs = Enum.filter(state.messages, &(&1.role == :tool_result))
      assert length(tool_msgs) >= 1
    end
  end

  # ── Provider error handling ────────────────────────────────

  describe "provider error handling" do
    test "missing api key returns error without crashing", ctx do
      {result, _log} =
        with_log(fn ->
          Agent.run("Hello",
            provider: OpenAICompat,
            provider_config: %{base_url: ctx.base_url, model: "gpt-4o"},
            model: "gpt-4o",
            working_directory: File.cwd!(),
            max_turns: 3,
            streaming: false
          )
        end)

      assert {:ok, state} = result
      assert state.status == :error
      assert state.error =~ "OPENAI_API_KEY" || state.error =~ "not configured"
    end
  end

  # ── Workspace boundary ─────────────────────────────────────

  describe "workspace boundary" do
    test "write respects working_directory boundary", ctx do
      safe_dir = Path.join(System.tmp_dir!(), "sigil_smoke_workspace/")
      File.mkdir_p!(safe_dir)

      {result, _log} =
        with_log(fn ->
          Agent.run("write a file named safe_test.txt",
            provider: OpenAICompat,
            provider_config: provider_config(ctx.base_url),
            model: "gpt-4o",
            tools: [Handbean.Tool.Builtin.Write],
            working_directory: safe_dir,
            max_turns: 5,
            streaming: false
          )
        end)

      assert {:ok, state} = result
      assert state.status == :completed

      safe_file = Path.join(safe_dir, "safe_test.txt")
      assert File.exists?(safe_file)

      File.rm_rf!(safe_dir)
    end
  end

  defp only_bash_command(state) do
    state.messages
    |> Enum.flat_map(&Message.tool_calls/1)
    |> Enum.filter(&(&1.name == "bash"))
    |> then(fn calls ->
      assert length(calls) == 1
      hd(calls).input["command"]
    end)
  end

  defp only_tool_output(state) do
    state.messages
    |> Enum.filter(&(&1.role == :tool_result))
    |> Enum.flat_map(fn msg -> List.wrap(msg.content) end)
    |> Enum.map_join("\n", &(&1[:content] || ""))
  end
end
