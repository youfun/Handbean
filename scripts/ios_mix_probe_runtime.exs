# Executed on iOS by ios_mix_workspace_probe.exs, with a `resume` binding.
root = Path.join(System.fetch_env!("MOB_DATA_DIR"), "workspace/mix_workspace_probe_v2/project")
home = Path.dirname(root)
cwd = File.cwd!()
inets_before = Enum.any?(Application.started_applications(), fn {app, _, _} -> app == :inets end)

env_keys =
  ~w(MIX_HOME HEX_HOME HEX_OFFLINE MIX_OS_DEPS_COMPILE_PARTITION_COUNT MIX_OS_CONCURRENCY_LOCK)

original_env = Map.new(env_keys, &{&1, System.get_env(&1)})

if not File.exists?(root) do
  if resume, do: raise("no installed project to resume")
  File.mkdir_p!(Path.join(root, "lib"))
  File.mkdir_p!(Path.join(root, "test"))

  File.write!(Path.join(root, "mix.exs"), """
  defmodule HandbeanMixProbe.Project do
    use Mix.Project
    def project do
      [app: :handbean_mix_probe_project, version: "0.1.0", consolidate_protocols: false,
       phandbean_code_paths: false, deps: [{:bimap, "== 1.3.0"}]]
    end
    def application, do: []
  end
  """)

  File.write!(Path.join(root, "lib/demo.ex"), """
  defmodule HandbeanMixProbe.Demo do
    def run, do: BiMap.new([{"phone", 42}]) |> BiMap.fetch_key(42)
  end
  """)

  File.write!(Path.join(root, "test/test_helper.exs"), "ExUnit.start(autorun: false)\n")

  File.write!(Path.join(root, "test/demo_test.exs"), """
  defmodule HandbeanMixProbe.DemoTest do
    use ExUnit.Case
    test "calls installed dependency" do
      assert HandbeanMixProbe.Demo.run() == {:ok, "phone"}
    end
    test "missing key remains an error" do
      assert BiMap.fetch(BiMap.new(), "missing") == :error
    end
    test "external build commands are rejected" do
      assert_raise RuntimeError, ~r/external commands/, fn ->
        HandbeanMixProbe.Shell.cmd("make", [])
      end
    end
  end
  """)
end

try do
  System.put_env("MIX_HOME", Path.join(home, "mix_home"))
  System.put_env("HEX_HOME", Path.join(home, "hex_home"))
  System.put_env("HEX_OFFLINE", if(resume, do: "1", else: "0"))
  System.put_env("MIX_OS_DEPS_COMPILE_PARTITION_COUNT", "1")
  System.put_env("MIX_OS_CONCURRENCY_LOCK", "0")
  Mix.start()
  old_mix_env = Mix.env()
  old_shell = Mix.shell()

  try do
    Mix.env(:test)
    Mix.shell(HandbeanMixProbe.Shell)

    # Register the original Hex app with only the transport/startup adapted.
    {:ok, [{:application, :hex, hex_spec}]} =
      :file.consult(Path.join(:code.lib_dir(:hex), "ebin/hex.app") |> String.to_charlist())

    hex_spec =
      hex_spec
      |> Keyword.update!(:applications, &List.delete(&1, :inets))
      |> Keyword.put(:mod, {HandbeanMixProbe.HexApplication, []})

    :ok = :application.load({:application, :hex, hex_spec})
    {:ok, _} = Application.ensure_all_started(:hex)

    Mix.Task.clear()

    results =
      Mix.Project.in_project(:handbean_mix_probe_project, root, fn _ ->
        deps = Mix.Task.run("deps.get", ["--no-archives-check"])

        compile =
          Mix.Task.run("compile", [
            "--no-protocol-consolidation",
            "--no-phandbean-code-paths",
            "--return-errors"
          ])

        if match?({:error, _}, compile), do: raise("project compilation failed")

        test =
          Mix.Task.run("test", [
            "--no-start",
            "--raise",
            "--no-compile"
          ])

        {:ok, "phone"} = result = apply(HandbeanMixProbe.Demo, :run, [])

        %{
          deps: deps,
          compile: compile,
          test: test,
          result: result,
          lock: File.read!("mix.lock"),
          phase: if(resume, do: :resume, else: :install)
        }
      end)

    ^cwd = File.cwd!()

    ^inets_before =
      Enum.any?(Application.started_applications(), fn {app, _, _} -> app == :inets end)

    Map.merge(results, %{
      cwd_restored: true,
      inets_changed: false,
      inets_already_running: inets_before,
      screen_alive: is_pid(Process.whereis(:mob_screen)),
      project: root
    })
  after
    Mix.Task.clear()
    Mix.env(old_mix_env)
    Mix.shell(old_shell)
  end
after
  for {key, value} <- original_env do
    if value, do: System.put_env(key, value), else: System.delete_env(key)
  end
end
