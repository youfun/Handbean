defmodule Handbean.Extension.MountTest do
  @moduledoc """
  TDD: in-memory mount (try then keep). Compile a string, register ext__*
  tools and child_spec workers, unmount without touching disk extensions
  or an active RunSupervisor.
  """

  use ExUnit.Case, async: false

  alias Handbean.Extension.Mount

  setup do
    n = System.unique_integer([:positive])

    on_exit(fn ->
      _ = Mount.unmount("mem#{n}")
    end)

    {:ok, n: n}
  end

  test "mount registers a compiled tool from source and execute works", %{n: n} do
    assert {:ok, mount} =
             Mount.mount(ping_source(n, "live"), name: "mem#{n}")

    assert mount.id == "mem#{n}"
    assert {:ok, entry} = Handbean.Tool.Registry.get("ext__mem#{n}__ping")
    assert {:ok, "live"} = entry.executor.(%{}, %{})
  end

  test "replacing the same id keeps the new tool registered", %{n: n} do
    assert {:ok, _} = Mount.mount(ping_source(n, "v1"), name: "mem#{n}")
    assert {:ok, first} = Handbean.Tool.Registry.get("ext__mem#{n}__ping")
    assert {:ok, "v1"} = first.executor.(%{}, %{})

    assert {:ok, _} = Mount.mount(ping_source(n, "v2"), name: "mem#{n}")
    assert {:ok, second} = Handbean.Tool.Registry.get("ext__mem#{n}__ping")
    assert {:ok, "v2"} = second.executor.(%{}, %{})
    assert second.module != first.module
  end

  test "failed replacement keeps the previous mount active", %{n: n} do
    assert {:ok, _} = Mount.mount(ping_source(n, "v1"), name: "mem#{n}")

    assert {:error, _} =
             Mount.mount("defmodule Ext.Broken#{n} do\n  this is not elixir\nend\n",
               name: "mem#{n}"
             )

    assert {:ok, entry} = Handbean.Tool.Registry.get("ext__mem#{n}__ping")
    assert {:ok, "v1"} = entry.executor.(%{}, %{})
  end

  test "unmount removes the tool and stops the worker", %{n: n} do
    assert {:ok, _mount} =
             Mount.mount(combo_source(n, "v1"), name: "mem#{n}")

    workers = Handbean.Extension.Supervisor.workers("mem#{n}")
    assert length(workers) == 1
    pid = hd(workers)
    assert Process.alive?(pid)
    assert {:ok, _} = Handbean.Tool.Registry.get("ext__mem#{n}__ping")

    assert :ok = Mount.unmount("mem#{n}")

    refute Process.alive?(pid)
    assert Handbean.Extension.Supervisor.workers("mem#{n}") == []
    assert Handbean.Tool.Registry.get("ext__mem#{n}__ping") == :error
  end

  test "failed compile does not register tools or start workers", %{n: n} do
    assert {:error, diags} =
             Mount.mount("defmodule Ext.Broken#{n} do\n  this is not elixir\nend\n",
               name: "mem#{n}"
             )

    assert [%{type: :warning, message: message} | _] = diags
    assert message =~ "Failed to compile"
    assert Handbean.Tool.Registry.get("ext__mem#{n}__ping") == :error
    assert Handbean.Extension.Supervisor.workers("mem#{n}") == []
  end

  defp ping_source(n, result) do
    """
    defmodule Ext.Mem#{n}.Ping do
      @behaviour Handbean.Agent.Tool

      def name, do: "ext__mem#{n}__ping"
      def description, do: "memory mount ping"
      def input_schema, do: %{"type" => "object", "properties" => %{}}
      def execute(_input, _context), do: {:ok, #{inspect(result)}}
    end
    """
  end

  defp combo_source(n, result) do
    ping_source(n, result) <>
      """

      defmodule Ext.Mem#{n}.Worker do
        use GenServer

        def child_spec(_opts) do
          %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}, type: :worker}
        end

        def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
        def init(_opts), do: {:ok, :up}
      end
      """
  end
end
