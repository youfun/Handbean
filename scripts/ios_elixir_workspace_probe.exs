# Run with an explicitly named host node and the device's debug cookie:
# elixir --name workspace_probe@127.0.0.1 --cookie COOKIE \
#   scripts/ios_elixir_workspace_probe.exs DEVICE_NODE [resume]
# This is a fixed-package feasibility probe, not a dependency installer.
[node_name | options] = System.argv()
device = String.to_atom(node_name)
unless Node.ping(device) == :pong, do: raise("device is not reachable")

source = ~S'''
root = Path.join(System.fetch_env!("MOB_DATA_DIR"), "workspace/elixir_workspace_probe")
ebin = Path.join(root, "_build/ebin")
expected = "bf5a2b078528465aa705f405a5c638becd63e41d280ada41e0f77e6d255a10b4"
modules = [BiMap, BiMultiMap, HandbeanWorkspaceProbe.Demo]

unless Enum.all?(modules, &(:code.which(&1) == :non_existing)) do
  raise "probe modules already available; use a fresh app process"
end

if resume do
  true = Code.prepend_path(ebin)
else
  if File.exists?(root), do: raise("probe workspace exists; use resume or a fresh workspace")
  File.mkdir_p!(ebin)
  {:ok, response} = Req.get("https://repo.hex.pm/tarballs/bimap-1.3.0.tar",
    decode_body: false, retry: false, receive_timeout: 30_000)
  200 = response.status
  archive = response.body
  ^expected = :crypto.hash(:sha256, archive) |> Base.encode16(case: :lower)
  {:ok, outer} = :erl_tar.extract({:binary, archive}, [:memory])
  {_, contents} = List.keyfind(outer, ~c"contents.tar.gz", 0)
  {:ok, files} = :erl_tar.extract({:binary, contents}, [:memory, :compressed])

  # Only materialize the two reviewed source files from this pinned archive.
  sources = for name <- ["lib/bimap.ex", "lib/bimultimap.ex"] do
    {_, bytes} = List.keyfind(files, String.to_charlist(name), 0)
    path = Path.join([root, "deps/bimap", name])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
    path
  end

  project_source = """
  defmodule HandbeanWorkspaceProbe.Demo do
    def run do
      map = BiMap.new([{"phone", 42}])
      {BiMap.fetch(map, "phone"), BiMap.fetch_key(map, 42)}
    end
  end
  """
  project_path = Path.join(root, "lib/demo.ex")
  File.mkdir_p!(Path.dirname(project_path))
  File.write!(project_path, project_source)
  File.write!(Path.join(root, "mix.exs"), """
  defmodule HandbeanWorkspaceProbe.MixProject do
    use Mix.Project
    def project, do: [app: :handbean_workspace_probe, version: "0.1.0",
      deps: [{:bimap, "== 1.3.0"}]]
  end
  """)

  for path <- sources ++ [project_path], {module, binary} <- Code.compile_file(path) do
    File.write!(Path.join(ebin, Atom.to_string(module) <> ".beam"), binary)
  end

  File.write!(
    Path.join(root, "probe-lock.json"),
    Handbean.JSON.encode!(%{
      package: "bimap",
      version: "1.3.0",
      sha256: expected,
      elixir: System.version(),
      otp: to_string(:erlang.system_info(:otp_release))
    })
  )
end

{{:ok, 42}, {:ok, "phone"}} = result = apply(HandbeanWorkspaceProbe.Demo, :run, [])
%{
  phase: if(resume, do: :resume, else: :install),
  workspace: root,
  result: result,
  elixir: System.version(),
  otp: to_string(:erlang.system_info(:otp_release)),
  mix: :code.which(Mix),
  hex: :code.which(Hex),
  ex_unit: :code.which(ExUnit),
  loaded_from: :code.which(HandbeanWorkspaceProbe.Demo),
  screen_alive: is_pid(Process.whereis(:mob_screen))
}
'''

case :rpc.call(device, Code, :eval_string, [source, [resume: "resume" in options]], 60_000) do
  {result, _bindings} when is_map(result) -> dbg(result)
  error -> raise "device probe failed: #{inspect(error)}"
end
