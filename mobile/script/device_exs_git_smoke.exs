# Dist smoke: LLM writes an .exs, runs it, clones a public git repo.
# Never prints credentials.

n = :"handbean_probe_android_nativechat@127.0.0.1"
:pong = Node.ping(n)

prompt = """
不要解释计划，按顺序做这三件事：

1. 用 write 在当前工作区根目录写 `tmp_hello.exs`，文件内容只有：
   IO.puts("handbean-exs-ok")
   不要 Mix.install，不要其它依赖。
2. 立刻用 run_elixir_script 运行这个 `tmp_hello.exs`。
3. 用 git 把公开仓库 https://github.com/octocat/Hello-World.git 克隆到当前工作区的 `tmp_hello_world/`（HTTPS，不要 SSH，不要凭据）。

完成后用两三句话汇报：脚本的 stdout，以及 `tmp_hello_world/` 里有哪些文件。
"""

summarize = fn entries ->
  Enum.map(entries, fn e ->
    type = e["content_type"] || e["message_type"] || e["role"]
    tool = e["tool_name"] || e["tool"]
    status = e["tool_status"] || e["status"]
    content = e["content"] || e["output"] || ""
    content = if is_binary(content), do: String.slice(content, 0, 240), else: inspect(content)
    err = e["tool_error"] || e["error"]
    %{type: type, tool: tool, status: status, content: content, error: err, id: e["id"]}
  end)
end

a0 = Mob.Test.assigns(n)
IO.inspect(%{page: a0.page, perm: a0.permission_mode, running: a0.chat && a0.chat.running}, label: "before")

:ok = Mob.Test.send_message(n, {:tap, :new_chat})
Process.sleep(400)
:ok = Mob.Test.send_message(n, {:change, :draft, prompt})
:ok = Mob.Test.send_message(n, {:tap, :send})
Process.sleep(800)

a1 = Mob.Test.assigns(n)
conv = a1.chat && a1.chat.conversation
conv_id = conv && conv["id"]
IO.puts("conversation_id=#{inspect(conv_id)} running=#{inspect(a1.chat && a1.chat.running)}")

started_at = System.monotonic_time(:millisecond)

poll = fn poll, seen_running ->
  now = System.monotonic_time(:millisecond)
  a = Mob.Test.assigns(n)
  running? = !!(a.chat && a.chat.running)
  seen_running = seen_running or running?
  elapsed = now - started_at
  stream_n = byte_size((a.chat && a.chat.stream) || "")
  n_entries = length((a.chat && a.chat.entries) || [])
  IO.puts("elapsed=#{div(elapsed, 1000)}s running=#{running?} seen=#{seen_running} entries=#{n_entries} stream=#{stream_n}")

  cond do
    elapsed > 180_000 -> {:timeout, a}
    seen_running and not running? and elapsed > 5_000 -> {:done, a}
    true ->
      Process.sleep(3000)
      poll.(poll, seen_running)
  end
end

{status, a} = poll.(poll, false)
IO.puts("STATUS=#{status}")

entries =
  if conv_id do
    :rpc.call(n, HandbeanProbe.NativeChat, :transcript, [conv_id])
  else
    (a.chat && a.chat.entries) || []
  end

IO.inspect(summarize.(entries || []), label: "transcript", limit: :infinity)

# workspace file check, no secrets
ws_path = a.workspace["path"]
IO.inspect(ws_path, label: "workspace_path")

ls = :rpc.call(n, File, :ls, [ws_path])
IO.inspect(ls, label: "workspace_ls")

hello = Path.join(ws_path, "tmp_hello.exs")
world = Path.join(ws_path, "tmp_hello_world")
IO.inspect({:exists_exs, :rpc.call(n, File, :exists?, [hello])})
IO.inspect({:exists_clone, :rpc.call(n, File, :exists?, [world])})
if :rpc.call(n, File, :exists?, [hello]) do
  IO.inspect(:rpc.call(n, File, :read, [hello]), label: "exs")
end
if :rpc.call(n, File, :exists?, [world]) do
  IO.inspect(:rpc.call(n, File, :ls, [world]), label: "clone_ls")
end
