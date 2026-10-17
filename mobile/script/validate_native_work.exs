# ARC-only companion for NativeWorkTest (-e work_fixture true).
# With instrumentation waiting, invoke start, queue, then finish from a named host
# node with the project's local debug cookie and _build/dev/lib/*/ebin on its path.
# Uses a local controlled provider, never calls an external model API.
n = :"handbean_probe_android_nativechat@127.0.0.1"
:pong = Node.ping(n)

eval = fn source ->
  {result, _} = :rpc.call(n, Code, :eval_string, [source], 20_000)
  result
end

case System.argv() do
  ["start"] ->
    id =
      eval.(~S"""
      defmodule NativeWorkArcHold do
        @behaviour Handbean.Agent.Tool
        def name, do: "native_work_hold"
        def description, do: "Controlled local Work validation"
        def input_schema, do: %{type: "object", properties: %{}}
        def execute(_, _) do
          Process.register(self(), :native_work_hold)
          receive do
            :finish -> {:ok, "工具已完成，未被steer取消。"}
          after
            600_000 -> {:error, "validation timeout"}
          end
        end
      end
      defmodule NativeWorkArcProvider do
        @behaviour Handbean.Agent.Provider
        alias Handbean.Agent.Message
        def complete(messages, _, _) do
          done = Enum.any?(messages, &(&1.role == :tool_result))
          texts = if done do
            [Message.assistant("## 完成\n\n已保留工具结果和中文追加消息。")]
          else
            [Message.assistant("开始受控工具操作，等待追加消息。"), Message.tool_use([%{type: "tool_use", id: "held-tool", name: "native_work_hold", input: %{}}])]
          end
          {:ok, %{stop_reason: if(done, do: :end_turn, else: :tool_use), messages: texts, usage: %{input_tokens: 3, output_tokens: 7}}}
        end
        def stream(messages, tools, config, on_chunk) do
          unless Enum.any?(messages, &(&1.role == :tool_result)),
            do: on_chunk.("开始受控工具操作，等待追加消息。")
          complete(messages, tools, config)
        end
      end
      {:ok, w} = Handbean.WorkspaceStore.ensure_default!()
      {:ok, c} = Handbean.ConversationStore.create(w["id"], title: "Native Work 中文steer验收")
      {:ok, _} = Handbean.Agent.Coordinator.add_message(c["id"], "开始受控本地操作",
        provider: NativeWorkArcProvider, provider_config: %{}, source: :native,
        model: "fixture", streaming: true, workspace_path: w["path"],
        tools: [NativeWorkArcHold], max_turns: 4)
      c["id"]
      """)

    File.write!("/tmp/native_work_live_id", id)
    Mob.Test.send_message(n, {:tap, {:conversation, id}})
    IO.puts(id)

  ["cleanup"] ->
    id = File.read!("/tmp/native_work_live_id")
    :rpc.call(n, Handbean.Agent.Coordinator, :cancel, [id])
    :rpc.call(n, Handbean.ConversationStore, :archive, [id])
    :rpc.call(n, Handbean.Tool.Registry, :unregister, ["native_work_hold"])

    for module <- [NativeWorkArcHold, NativeWorkArcProvider] do
      :rpc.call(n, :code, :purge, [module])
      :rpc.call(n, :code, :delete, [module])
    end

    File.rm!("/tmp/native_work_live_id")

  ["queue"] ->
    id = File.read!("/tmp/native_work_live_id")
    {:ok, status} = :rpc.call(n, Handbean.Agent.Coordinator, :status, [id])
    items = :rpc.call(n, Handbean.Agent.CandidateQueue, :get_messages, [status.queue_pid])
    [%{message: %{content: "追加中文🙂 不要取消工具"}, metadata: %{deliver_as: :steer}}] = items
    true = status.running?
    true = is_pid(:rpc.call(n, Process, :whereis, [:native_work_hold]))
    IO.inspect(items)
    IO.inspect(:rpc.call(n, Process, :whereis, [:native_work_hold]), label: "live_tool")

  ["finish"] ->
    :ok = eval.("send(Process.whereis(:native_work_hold), :finish); :ok")

  ["check"] ->
    id = File.read!("/tmp/native_work_live_id")
    entries = :rpc.call(n, HandbeanProbe.NativeChat, :transcript, [id])
    true = Enum.any?(entries, &(&1["interrupts_work"] == true))
    true = Enum.any?(entries, &(&1["id"] == "tool-held-tool" and &1["tool_status"] == "done"))
    true = Enum.any?(entries, &(&1["phase"] == "commentary"))
    true = Enum.any?(entries, &(&1["phase"] == "final" and &1["status"] == "completed"))

    IO.inspect(
      Enum.map(
        entries,
        &Map.take(&1, [
          "id",
          "phase",
          "status",
          "tool_status",
          "interrupts_work",
          "content",
          "output"
        ])
      )
    )

    a = Mob.Test.assigns(n)

    IO.inspect(%{
      running: a.chat.running,
      stream: a.chat.stream,
      draft: a.draft,
      pending: a.chat.pending_approval
    })
end
