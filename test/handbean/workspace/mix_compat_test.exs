defmodule Handbean.Workspace.MixCompatTest do
  use ExUnit.Case, async: true

  alias Handbean.Workspace.MixCompat

  defp dep(overrides) do
    struct!(
      Mix.Dep,
      Keyword.merge(
        [scm: Mix.SCM.Path, app: :demo, requirement: "0.1.0", status: {:ok, "0.1.0"}, opts: []],
        overrides
      )
    )
  end

  test "rejects nested transitive native compilers" do
    host = %MixCompat{apps: %{}, modules: MapSet.new()}
    child = dep(app: :nif_child, opts: [compilers: [:rustler]])
    parent = dep(app: :parent, deps: [child])

    assert {:error, message} = MixCompat.check([parent], host)
    assert message =~ "rustler"
  end

  test "rejects rebar/make managers and native compilers" do
    host = %MixCompat{apps: %{}, modules: MapSet.new()}

    assert {:error, message} = MixCompat.check([dep(app: :rebar_dep, manager: :rebar3)], host)
    assert message =~ "rebar3"

    assert {:error, native} =
             MixCompat.check(
               [dep(app: :nif_dep, opts: [compilers: [:elixir_make, :elixir]])],
               host
             )

    assert native =~ "elixir_make"
  end

  test "rejects host application version conflicts and module collisions" do
    tmp = Path.join(System.tmp_dir!(), "sigil_mix_compat_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "lib"))
    File.write!(Path.join(tmp, "lib/jason.ex"), "defmodule Jason do\nend\n")

    host = %MixCompat{
      apps: %{jason: "1.4.4"},
      modules: MapSet.new([Jason])
    }

    assert {:error, conflict} =
             MixCompat.check(
               [dep(app: :jason, requirement: "== 1.0.0", status: {:ok, "1.0.0"})],
               host
             )

    assert conflict =~ "conflicts with host application jason"

    collide = dep(app: :collide, opts: [dest: tmp])
    assert {:error, modules} = MixCompat.check([collide], host)
    assert modules =~ "Jason"

    File.rm_rf!(tmp)
  end

  test "rejects native source trees and mix.exs native markers" do
    tmp = Path.join(System.tmp_dir!(), "sigil_mix_native_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "c_src"))
    File.write!(Path.join(tmp, "mix.exs"), "defmodule Native.MixProject do\nend\n")
    host = %MixCompat{apps: %{}, modules: MapSet.new()}

    assert {:error, tree} = MixCompat.check([dep(app: :native, opts: [dest: tmp])], host)
    assert tree =~ "c_src"

    File.rm_rf!(Path.join(tmp, "c_src"))

    File.write!(Path.join(tmp, "mix.exs"), """
    defmodule Native.MixProject do
      def project, do: [compilers: [:elixir_make] ++ Mix.compilers()]
    end
    """)

    assert {:error, mixfile} = MixCompat.check([dep(app: :native, opts: [dest: tmp])], host)
    assert mixfile =~ "native or Rebar"

    File.rm_rf!(tmp)
  end

  test "reuses a packaged host NIF when the requirement matches a different patch" do
    host = %MixCompat{apps: %{bcrypt_elixir: "3.3.2"}, modules: MapSet.new()}
    tmp = Path.join(System.tmp_dir!(), "sigil_bcrypt_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "c_src"))
    File.write!(Path.join(tmp, "mix.exs"), "defmodule Bcrypt.MixProject do\nend\n")

    on_exit(fn -> File.rm_rf(tmp) end)

    locked =
      {:hex, :bcrypt_elixir, "3.2.1", "checksum", [:make, :mix], [], "hexpm", "checksum"}

    dependency =
      dep(
        app: :bcrypt_elixir,
        requirement: "~> 3.0",
        status: {:ok, "3.2.1"},
        manager: :make,
        opts: [dest: tmp, compilers: [:elixir_make], lock: locked]
      )

    assert :ok = MixCompat.check([dependency], host)

    host_missing = %MixCompat{apps: %{}, modules: MapSet.new()}
    assert {:error, native} = MixCompat.check([dependency], host_missing)
    assert native =~ "make" or native =~ "c_src" or native =~ "elixir_make"
  end

  test "allows matching host versions and unknown pure Mix deps" do
    host = %MixCompat{apps: %{jason: "1.4.4"}, modules: MapSet.new([Jason])}

    assert :ok =
             MixCompat.check(
               [dep(app: :jason, requirement: "== 1.4.4", status: {:ok, "1.4.4"})],
               host
             )

    assert :ok = MixCompat.check([dep(app: :bimap, requirement: "== 1.3.0")], host)
  end

  test "uses the resolved Hex lock version before status or a broad requirement" do
    host = %MixCompat{apps: %{jason: "1.4.5"}, modules: MapSet.new([Jason])}

    locked =
      {:hex, :jason, "1.4.4", "checksum", [:mix], [], "hexpm", "checksum"}

    dependency =
      dep(
        app: :jason,
        requirement: "~> 1.4",
        status: {:noappfile, "unused.app"},
        opts: [lock: locked]
      )

    assert {:error, message} = MixCompat.check([dependency], host)
    assert message =~ "jason 1.4.4"
    assert message =~ "host application jason 1.4.5"
  end

  test "checks Elixir and Erlang modules owned by the main project" do
    tmp =
      Path.join(System.tmp_dir!(), "sigil_mix_main_modules_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(tmp, "lib"))
    File.mkdir_p!(Path.join(tmp, "src"))

    File.write!(Path.join(tmp, "lib/collision.ex"), """
    defmodule MixCompatHostCollision do
    end
    """)

    File.write!(Path.join(tmp, "src/collision.erl"), """
    -module(mix_compat_erlang_collision).
    -export([value/0]).
    value() -> host.
    """)

    host = %MixCompat{
      apps: %{},
      modules: MapSet.new([MixCompatHostCollision, :mix_compat_erlang_collision])
    }

    assert {:error, message} = MixCompat.check_project_sources(tmp, host)
    assert message =~ "MixCompatHostCollision"

    File.rm!(Path.join(tmp, "lib/collision.ex"))
    assert {:error, erlang_message} = MixCompat.check_project_sources(tmp, host)
    assert erlang_message =~ "mix_compat_erlang_collision"

    File.rm_rf!(tmp)
  end

  test "detects a host module available on the frozen code path before it is loaded" do
    tmp =
      Path.join(System.tmp_dir!(), "sigil_mix_lazy_host_#{System.unique_integer([:positive])}")

    host_ebin = Path.join(tmp, "host_ebin")
    project = Path.join(tmp, "project")
    File.mkdir_p!(host_ebin)
    File.mkdir_p!(Path.join(project, "lib"))

    [{LazyMixCompatHost, beam}] =
      Code.compile_string("defmodule LazyMixCompatHost do\n  def value, do: :host\nend\n")

    File.write!(Path.join(host_ebin, "Elixir.LazyMixCompatHost.beam"), beam)
    :code.purge(LazyMixCompatHost)
    :code.delete(LazyMixCompatHost)

    File.write!(Path.join(project, "lib/lazy_host.ex"), """
    defmodule LazyMixCompatHost do
      def value, do: :project
    end
    """)

    host = %MixCompat{code_paths: MapSet.new([Path.expand(host_ebin)])}
    true = :code.add_patha(String.to_charlist(host_ebin))

    try do
      assert {:error, message} = MixCompat.check_project_sources(project, host)
      assert message =~ "LazyMixCompatHost"
      assert :code.is_loaded(LazyMixCompatHost) == false
    after
      :code.del_path(String.to_charlist(host_ebin))
      File.rm_rf!(tmp)
    end
  end

  test "does not promote dependency Mix project modules to host ownership" do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "sigil_mix_workspace_dep_#{System.unique_integer([:positive])}"
      )

    dep = Path.join(tmp, "deps/sample_dep")
    File.mkdir_p!(dep)
    mix_file = Path.join(dep, "mix.exs")

    File.write!(mix_file, """
    defmodule MixCompatWorkspaceDep.MixProject do
      use Mix.Project
      def project, do: [app: :sample_dep, version: "0.1.0"]
    end
    """)

    Code.compile_file(mix_file)
    assert {MixCompatWorkspaceDep.MixProject, []} in :code.all_loaded()

    try do
      refreshed = MixCompat.refresh_loaded_modules(%MixCompat{}, [tmp])
      refute MapSet.member?(refreshed.modules, MixCompatWorkspaceDep.MixProject)
    after
      :code.purge(MixCompatWorkspaceDep.MixProject)
      :code.delete(MixCompatWorkspaceDep.MixProject)
      File.rm_rf!(tmp)
    end
  end

  test "rejects umbrella projects" do
    assert {:error, message} = MixCompat.check_project(apps_path: "apps")
    assert message =~ "umbrella"
  end
end
