# Host-side Mob.Test / Mob.Diag probe. Does not tap or send user events.
# Never prints credential-like assign values.

secret_key? = fn key ->
  s = key |> to_string() |> String.downcase()
  String.contains?(s, "key") or String.contains?(s, "token") or
    String.contains?(s, "secret") or String.contains?(s, "password") or
    String.contains?(s, "cookie") or String.contains?(s, "credential")
end

summarize_assign = fn
  {k, v} when is_binary(v) ->
    if secret_key?.(k), do: {k, :redacted}, else: {k, {:binary, byte_size(v)}}

  {k, v} when is_list(v) ->
    {k, {:list, length(v)}}

  {k, v} when is_map(v) ->
    {k, {:map, map_size(v)}}

  {k, v} when is_tuple(v) ->
    {k, {:tuple, tuple_size(v)}}

  {k, v} ->
    {k, v}
end

collect_types = fn tree ->
  walk = fn
    node, acc, walk when is_map(node) ->
      type = Map.get(node, :type) || Map.get(node, "type")
      acc = if type, do: Map.update(acc, type, 1, &(&1 + 1)), else: acc

      Enum.reduce(Map.values(node), acc, fn
        child, acc when is_map(child) or is_list(child) -> walk.(child, acc, walk)
        _, acc -> acc
      end)

    nodes, acc, walk when is_list(nodes) ->
      Enum.reduce(nodes, acc, &walk.(&1, &2, walk))

    _, acc, _ ->
      acc
  end

  walk.(tree, %{}, walk)
end

{:ok, _} = :net_kernel.start([:"native_inspect@127.0.0.1", :longnames])
true = Node.set_cookie(MobDev.DistCookie.for_project!())

candidates = [
  :"handbean_probe_android_nativechat@127.0.0.1",
  :"handbean_probe_android@127.0.0.1"
]

{node, ping} =
  Enum.reduce_while(candidates, {nil, :pang}, fn n, _ ->
    case Node.ping(n) do
      :pong -> {:halt, {n, :pong}}
      other -> {:cont, {n, other}}
    end
  end)

IO.puts("PING #{inspect(node)} => #{inspect(ping)}")
IO.puts("CONNECTED #{inspect(Node.list())}")

if ping != :pong do
  IO.puts("NODEDOWN — Dist tunnel or OTP not up")
  System.halt(1)
end

IO.puts("\n=== Mob.Test.screen ===")
IO.inspect(Mob.Test.screen(node), limit: :infinity)

IO.puts("\n=== Mob.Test.screen_info ===")
IO.inspect(Mob.Test.screen_info(node), limit: :infinity)

IO.puts("\n=== Mob.Test.assigns (redacted shapes) ===")

assigns = Mob.Test.assigns(node)

if is_map(assigns) do
  assigns
  |> Enum.map(summarize_assign)
  |> Enum.sort_by(fn {k, _} -> to_string(k) end)
  |> IO.inspect(limit: :infinity)
else
  IO.inspect(assigns)
end

IO.puts("\n=== Mob.Test.tree type counts ===")
tree = Mob.Test.tree(node)
IO.inspect(collect_types.(tree), limit: :infinity)

IO.puts("\n=== Mob.Test.find samples ===")

for q <- ["设置", "Settings", "新对话", "New", "发送", "Send"] do
  hits = Mob.Test.find(node, q)
  IO.puts("  #{inspect(q)} => #{length(hits)} hit(s)")
end

IO.puts("\n=== Mob.Test.inspect keys ===")
ins = Mob.Test.inspect(node)
IO.inspect(Map.keys(ins), limit: :infinity)
IO.inspect(Map.get(ins, :nav_history), limit: 20)

IO.puts("\n=== Mob.Test.element_frames ===")

frames =
  try do
    Mob.Test.element_frames(node)
  rescue
    e -> {:error, Exception.message(e)}
  end

IO.inspect(
  case frames do
    map when is_map(map) -> {:ok, map_size(map), Map.keys(map) |> Enum.take(12)}
    other -> other
  end,
  limit: :infinity
)

IO.puts("\n=== Mob.Test.view_tree (Android expected limited) ===")
IO.inspect(Mob.Test.view_tree(node), limit: 8)

IO.puts("\n=== Mob.Test.ui_tree (Android expected limited) ===")
IO.inspect(Mob.Test.ui_tree(node), limit: 8)

IO.puts("\n=== Mob.Test.screenshot ===")

case Mob.Test.screenshot(node) do
  {:ok, png} when is_binary(png) ->
    out = Path.expand("artifacts/mob-test-screenshot.png")
    File.mkdir_p!(Path.dirname(out))
    File.write!(out, png)
    IO.puts("  wrote #{out} (#{byte_size(png)} bytes)")

  other ->
    IO.inspect(other, limit: 8)
end

IO.puts("\n=== Mob.Diag.loaded_snapshot ===")
snap = :rpc.call(node, Mob.Diag, :loaded_snapshot, [])

IO.inspect(
  %{
    loaded_count: snap.loaded_count,
    shipped_count: snap.shipped_count,
    unloaded_count: length(snap.unloaded_in_bundle),
    otp_root: snap.otp_root,
    captured_at: snap.captured_at
  },
  limit: :infinity
)

IO.puts("\n=== rpc Process.whereis ===")

for name <- [:mob_screen, HandbeanWeb.Endpoint, Handbean.Repo, Handbean.Agent.Coordinator] do
  IO.puts("  #{inspect(name)} => #{inspect(:rpc.call(node, Process, :whereis, [name]))}")
end

IO.puts("\n=== Node.list on device ===")
IO.inspect(:rpc.call(node, Node, :list, []), limit: :infinity)
IO.puts("OK")
