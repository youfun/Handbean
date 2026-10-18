# Host uploads matching toolchain bytecode, never compiles the project.
# All deps.get, compile, test and run operations execute inside the iOS BEAM.
# elixir --name probe@127.0.0.1 --cookie COOKIE scripts/ios_mix_workspace_probe.exs NODE [resume]
[node_name | options] = System.argv()
device = String.to_atom(node_name)
unless Node.ping(device) == :pong, do: raise("device unreachable")

rpc = fn module, function, args ->
  case :rpc.call(device, module, function, args, 120_000) do
    {:badrpc, reason} -> raise "device call failed: #{inspect(reason)}"
    value -> value
  end
end

unless rpc.(System, :version, []) == System.version(), do: raise("Elixir versions differ")
%{active: 0} = rpc.(DynamicSupervisor, :count_children, [Handbean.AgentRunSupervisor])
data = rpc.(System, :fetch_env!, ["MOB_DATA_DIR"])
toolchain = Path.join(data, "workspace/mix_workspace_probe_v2/toolchain")
resume = "resume" in options

unless Enum.all?([Mix, Hex, ExUnit, BiMap], &(rpc.(:code, :which, [&1]) == :non_existing)) do
  raise "use a fresh app process; toolchain or dependency already loaded"
end

for {app, local} <- [
      mix: to_string(:code.lib_dir(:mix)),
      ex_unit: to_string(:code.lib_dir(:ex_unit)),
      hex: Path.expand("~/.mix/archives/hex-2.4.1-otp-28/hex-2.4.1-otp-28")
    ] do
  destination = Path.join([toolchain, Atom.to_string(app), "ebin"])

  unless resume do
    files = Path.wildcard(Path.join([local, "ebin", "*"])) |> Enum.filter(&File.regular?/1)
    if files == [], do: raise("toolchain not found: #{local}")
    :ok = rpc.(File, :mkdir_p, [destination])

    for file <- files do
      :ok = rpc.(File, :write, [Path.join(destination, Path.basename(file)), File.read!(file)])
    end
  end

  true = rpc.(Code, :prepend_path, [destination])
end

unless resume do
  for name <- ["ios_mix_probe_support.exs", "ios_mix_probe_runtime.exs"] do
    :ok = rpc.(File, :write, [Path.join(toolchain, name), File.read!(Path.join(__DIR__, name))])
  end
end

rpc.(Code, :compile_file, [Path.join(toolchain, "ios_mix_probe_support.exs")])

{{result, _}, _} =
  rpc.(Code, :eval_string, [
    "Code.eval_string(File.read!(path), [resume: resume], file: path)",
    [path: Path.join(toolchain, "ios_mix_probe_runtime.exs"), resume: resume]
  ])

dbg(result)
