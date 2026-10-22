defmodule Handbean.Tool.Builtin.MixProjectTest do
  use ExUnit.Case, async: false

  alias Handbean.Tool.Builtin.MixProject

  setup do
    work =
      Path.join(System.tmp_dir!(), "sigil_mix_project_#{System.unique_integer([:positive])}")

    File.mkdir_p!(work)
    on_exit(fn -> File.rm_rf!(work) end)
    {:ok, work: work, ctx: %{working_directory: work}}
  end

  test "rejects missing workspace, unknown action, and missing mix.exs", %{ctx: ctx, work: work} do
    assert {:error, "working_directory is required"} =
             MixProject.execute(%{"action" => "compile"}, %{})

    assert {:error, message} = MixProject.execute(%{"action" => "clean"}, ctx)
    assert message =~ "unsupported"

    File.mkdir_p!(Path.join(work, "empty"))

    assert {:error, missing, _} =
             MixProject.execute(%{"action" => "compile", "path" => "empty"}, ctx)

    assert missing =~ "mix.exs"
  end

  @tag :external_api
  test "creates, installs, compiles, tests and runs a real Mix project", %{work: work, ctx: ctx} do
    write_project(work, :ok)

    assert {:ok, deps_out, deps} =
             MixProject.execute(%{"action" => "deps.get", "timeout_ms" => 60_000}, ctx)

    assert deps_out =~ "result:"
    assert File.exists?(Path.join(work, "mix.lock"))
    lock = File.read!(Path.join(work, "mix.lock"))
    assert lock =~ "makeup"
    assert lock =~ "nimble_parsec"
    assert File.dir?(Path.join(work, "deps/makeup"))
    packages = List.wrap(deps[:packages])
    assert packages == [] or :makeup in packages

    assert {:ok, compile_out, compile} =
             MixProject.execute(%{"action" => "compile", "timeout_ms" => 60_000}, ctx)

    assert compile_out =~ "result:"
    assert compile[:compile]

    assert Handbean.Workspace.MixProject.compile_args() == [
             "--no-protocol-consolidation",
             "--no-phandbean-code-paths",
             "--return-errors"
           ]

    assert Handbean.Workspace.MixProject.test_args() == ["--no-start", "--raise", "--no-compile"]

    assert {:ok, test_out, test} =
             MixProject.execute(%{"action" => "test", "timeout_ms" => 60_000}, ctx)

    assert test_out =~ "result:"
    assert test[:test] == :ok
    assert test[:test_files]
    refute test_out =~ "Result: 0 tests"

    assert test_out =~ "1 passed" or test[:stdout] =~ "1 passed" or
             test_out =~ "passed"

    assert {:ok, repeated_test_out, %{test: :ok}} =
             MixProject.execute(%{"action" => "test", "timeout_ms" => 60_000}, ctx)

    assert repeated_test_out =~ "1 passed"

    assert {:ok, run_out, run} =
             MixProject.execute(
               %{
                 "action" => "run",
                 "module" => "HandbeanMixTool.Demo",
                 "function" => "run",
                 "timeout_ms" => 60_000
               },
               ctx
             )

    assert run_out =~ "result:"
    assert run[:return]

    assert {:ok, _offline, _} =
             MixProject.execute(
               %{"action" => "compile", "offline" => true, "timeout_ms" => 60_000},
               ctx
             )
  end

  test "rejects a host module collision through the tool", %{work: work, ctx: ctx} do
    File.write!(Path.join(work, "mix.exs"), """
    defmodule HandbeanMixCollision.MixProject do
      use Mix.Project
      def project do
        [app: :jason, version: "0.0.1", deps: []]
      end
    end
    """)

    File.write!(Path.join(work, "mix.lock"), "%{}\n")

    File.mkdir_p!(Path.join(work, "lib"))
    File.write!(Path.join(work, "lib/demo.ex"), "defmodule HandbeanMixCollision.Demo do\nend\n")

    assert {:error, message, _} = MixProject.execute(%{"action" => "compile"}, ctx)
    assert message =~ "conflicts with host application jason"
  end

  test "rejects a main-project collision and never runs the host implementation", %{
    work: work,
    ctx: ctx
  } do
    Code.compile_string("""
    defmodule HandbeanMixHostSentinel do
      def value, do: :host
    end
    """)

    File.write!(Path.join(work, "mix.exs"), """
    defmodule HandbeanMixHostCollision.MixProject do
      use Mix.Project
      def project, do: [app: :handbean_mix_host_collision, version: "0.1.0", deps: []]
    end
    """)

    File.write!(Path.join(work, "mix.lock"), "%{}\n")
    File.mkdir_p!(Path.join(work, "lib"))

    File.write!(Path.join(work, "lib/sentinel.ex"), """
    defmodule HandbeanMixHostSentinel do
      def value, do: :overwritten
    end
    """)

    assert {:error, compile_message, _} =
             MixProject.execute(%{"action" => "compile"}, ctx)

    assert compile_message =~ "HandbeanMixHostSentinel"
    assert apply(HandbeanMixHostSentinel, :value, []) == :host

    assert {:error, run_message, _} =
             MixProject.execute(
               %{
                 "action" => "run",
                 "module" => "HandbeanMixHostSentinel",
                 "function" => "value"
               },
               ctx
             )

    assert run_message =~ "HandbeanMixHostSentinel"
    assert apply(HandbeanMixHostSentinel, :value, []) == :host
  end

  test "run only calls modules owned by the workspace project", %{work: work, ctx: ctx} do
    assert {:module, Jason} = Code.ensure_loaded(Jason)
    write_project(work, :hex_state)

    assert {:error, message, _} =
             MixProject.execute(
               %{
                 "action" => "run",
                 "module" => "Jason",
                 "function" => "encode!",
                 "args" => [%{}]
               },
               ctx
             )

    assert message =~ "belongs to the host"
  end

  @tag :external_api
  test "first download reuses an exactly locked host application", %{work: work, ctx: ctx} do
    host_version = Application.spec(:jason, :vsn) |> to_string()
    host_path = :jason |> :code.lib_dir() |> to_string()
    write_jason_project(work, "== #{host_version}", "HandbeanMixJasonExact")

    assert {:ok, _deps_output, _deps} =
             MixProject.execute(%{"action" => "deps.get", "timeout_ms" => 60_000}, ctx)

    reused_path = Path.join(work, "_build/dev/lib/jason")
    assert {:ok, ^host_path} = File.read_link(reused_path)

    assert {:ok, _run_output, run} =
             MixProject.execute(
               %{
                 "action" => "run",
                 "module" => "HandbeanMixJasonExact.Demo",
                 "function" => "run",
                 "timeout_ms" => 60_000
               },
               ctx
             )

    assert run[:return] == ~s({:ok, %{"host" => true}})
    refute run[:stdout] =~ "Generated jason app"
    assert {:ok, ^host_path} = File.read_link(reused_path)
  end

  test "compile rejects a broad requirement locked to a different host version", %{
    work: work,
    ctx: ctx
  } do
    host_version = Application.spec(:jason, :vsn) |> to_string()
    conflicting_version = if host_version == "1.4.4", do: "1.4.5", else: "1.4.4"
    write_jason_project(work, "~> 1.4", "HandbeanMixJasonConflict")

    File.write!(Path.join(work, "mix.lock"), """
    %{
      "jason": {:hex, :jason, "#{conflicting_version}", "checksum", [:mix], [], "hexpm", "checksum"}
    }
    """)

    assert {:error, message, _} = MixProject.execute(%{"action" => "compile"}, ctx)
    assert message =~ "jason #{conflicting_version}"
    assert message =~ "host application jason #{host_version}"
  end

  test "rejects native package trees through the tool", %{work: work, ctx: ctx} do
    File.write!(Path.join(work, "mix.exs"), """
    defmodule HandbeanMixNative.MixProject do
      use Mix.Project
      def project do
        [app: :handbean_mix_native, version: "0.0.1", compilers: [:elixir_make], deps: []]
      end
    end
    """)

    File.mkdir_p!(Path.join(work, "lib"))
    File.write!(Path.join(work, "lib/demo.ex"), "defmodule HandbeanMixNative.Demo do\nend\n")
    File.write!(Path.join(work, "mix.lock"), "%{}\n")

    assert {:error, message, _} = MixProject.execute(%{"action" => "compile"}, ctx)
    assert message =~ "native toolchain"
  end

  test "recovers after a compile failure", %{work: work, ctx: ctx} do
    File.write!(Path.join(work, "mix.exs"), """
    defmodule HandbeanMixFail.MixProject do
      use Mix.Project
      def project do
        [app: :handbean_mix_fail, version: "0.0.1", deps: []]
      end
    end
    """)

    File.mkdir_p!(Path.join(work, "lib"))
    File.write!(Path.join(work, "mix.lock"), "%{}\n")

    File.write!(
      Path.join(work, "lib/demo.ex"),
      "defmodule HandbeanMixFail.Demo do\n  def broken, do: %NotAReal{}\nend\n"
    )

    assert {:error, failed, _} = MixProject.execute(%{"action" => "compile"}, ctx)
    assert failed =~ "compilation failed" or failed =~ "NotAReal" or failed =~ "undefined"

    File.write!(Path.join(work, "lib/demo.ex"), """
    defmodule HandbeanMixFail.Demo do
      def run, do: :recovered
    end
    """)

    assert {:ok, _, _} = MixProject.execute(%{"action" => "compile"}, ctx)
  end

  test "script environment allows Mix.install when Mix is present" do
    description = Handbean.Tool.ScriptEnvironment.describe()
    assert description =~ "Mix.install"
    assert description =~ "Mix.install/2 is supported"
    refute description =~ "Do not call Mix.install"
    refute description =~ "This tool does not provide a dependency installer"
  end

  test "online and offline actions refresh Hex state for each operation", %{work: work, ctx: ctx} do
    write_project(work, :hex_state)

    assert {:ok, _online_output, online} =
             MixProject.execute(
               %{
                 "action" => "run",
                 "module" => "HandbeanMixTool.HexState",
                 "function" => "offline?"
               },
               ctx
             )

    assert online[:return] == "false"

    assert {:ok, _offline_output, offline} =
             MixProject.execute(
               %{
                 "action" => "run",
                 "module" => "HandbeanMixTool.HexState",
                 "function" => "offline?",
                 "offline" => true
               },
               ctx
             )

    assert offline[:return] == "true"

    assert {:ok, _restored_output, restored} =
             MixProject.execute(
               %{
                 "action" => "run",
                 "module" => "HandbeanMixTool.HexState",
                 "function" => "offline?"
               },
               ctx
             )

    assert restored[:return] == "false"
  end

  defp write_project(work, :ok) do
    File.write!(Path.join(work, "mix.exs"), """
    defmodule HandbeanMixTool.MixProject do
      use Mix.Project

      def project do
        [
          app: :handbean_mix_tool,
          version: "0.1.0",
          elixir: "~> 1.18",
          deps: [{:makeup, "~> 1.2"}]
        ]
      end

      def application, do: []
    end
    """)

    File.mkdir_p!(Path.join(work, "lib"))
    File.mkdir_p!(Path.join(work, "test"))

    File.write!(Path.join(work, "lib/demo.ex"), """
    defmodule HandbeanMixTool.Demo do
      def run, do: {:ok, "phone"}
    end
    """)

    File.write!(Path.join(work, "test/test_helper.exs"), "ExUnit.start(autorun: false)\n")

    File.write!(Path.join(work, "test/demo_test.exs"), """
    defmodule HandbeanMixTool.DemoTest do
      use ExUnit.Case

      test "project function" do
        assert HandbeanMixTool.Demo.run() == {:ok, "phone"}
      end
    end
    """)
  end

  defp write_project(work, :hex_state) do
    File.write!(Path.join(work, "mix.exs"), """
    defmodule HandbeanMixTool.HexStateProject do
      use Mix.Project
      def project, do: [app: :handbean_mix_hex_state, version: "0.1.0", deps: []]
    end
    """)

    File.write!(Path.join(work, "mix.lock"), "%{}\n")
    File.mkdir_p!(Path.join(work, "lib"))

    File.write!(Path.join(work, "lib/hex_state.ex"), """
    defmodule HandbeanMixTool.HexState do
      def offline?, do: Hex.State.fetch!(:offline)
    end
    """)
  end

  defp write_jason_project(work, requirement, namespace) do
    File.write!(Path.join(work, "mix.exs"), """
    defmodule #{namespace}.MixProject do
      use Mix.Project
      def project, do: [app: :handbean_mix_jason, version: "0.1.0", deps: [{:jason, #{inspect(requirement)}}]]
    end
    """)

    File.mkdir_p!(Path.join(work, "lib"))

    File.write!(Path.join(work, "lib/demo.ex"), """
    defmodule #{namespace}.Demo do
      def run, do: Jason.decode(~s({"host":true}))
    end
    """)
  end
end
