defmodule Handbean.Tool.Builtin.GrepBudgetTest do
  use ExUnit.Case, async: false

  alias Handbean.Agent.Tool.Result
  alias Handbean.Tool.Builtin.Grep

  defmodule Backend do
    def ensure_started(_workspace),
      do: {:ok, Application.fetch_env!(:handbean, :grep_budget_test)}

    defdelegate update_paths(index, paths), to: Handbean.Search.ExFffBackend
    defdelegate set_git_status(index, entries), to: Handbean.Search.ExFffBackend
    defdelegate ignored_path?(workspace, path), to: Handbean.Search.ExFffBackend
    defdelegate refresh(index), to: Handbean.Search.ExFffBackend

    def files({owner, :block}, _opts) do
      send(owner, {:inventory_started, self()})

      receive do
        :finish -> {:error, "unexpected completion"}
      end
    end

    def files({_owner, :raise}, _opts) do
      raise ArgumentError, "private-search-pattern-secret"
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "grep-budget-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous = Application.get_env(:handbean, :search_backend)
    previous_test = Application.get_env(:handbean, :grep_budget_test)

    on_exit(fn ->
      restore(:search_backend, previous)
      restore(:grep_budget_test, previous_test)
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "the overall budget includes inventory and terminates its worker", %{root: root} do
    Application.put_env(:handbean, :search_backend, Backend)
    Application.put_env(:handbean, :grep_budget_test, {self(), :block})

    task =
      Task.async(fn -> Grep.execute(%{"pattern" => "marker"}, %{working_directory: root}) end)

    assert_receive {:inventory_started, worker}, 1_000
    monitor = Process.monitor(worker)

    assert {:error, message, %{code: :scan_timeout}} = Task.await(task, 8_000)
    assert message =~ "timed out"
    assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}
  end

  test "internal exceptions retain sanitized real stack without exception text", %{root: root} do
    Application.put_env(:handbean, :search_backend, Backend)
    Application.put_env(:handbean, :grep_budget_test, {self(), :raise})

    assert %Result{is_error: true, diagnostic: {exception, stack}} =
             result =
             Grep.execute(%{"pattern" => "private-search-pattern-secret"}, %{
               working_directory: root
             })

    assert Enum.any?(stack, fn {module, function, arity, _location} ->
             module == Backend and function == :files and arity == 2
           end)

    refute inspect({result.content, result.details, exception, stack}) =~
             "private-search-pattern-secret"

    assert Exception.message(exception) =~ "ArgumentError"
  end

  test "glob pushdown preserves suffix and legacy cross-directory matches", %{root: root} do
    File.mkdir_p!(Path.join(root, "lib/deep"))
    File.write!(Path.join(root, "lib/deep/file.ex"), "marker\n")
    File.write!(Path.join(root, "lib/deep/file.txt"), "marker\n")
    {:ok, index} = Handbean.Search.ensure_started(root)
    :ok = Handbean.Search.await(index)

    original_path = System.get_env("PATH")

    try do
      for executable_path <- [original_path, Path.join(root, "no-executables")] do
        if executable_path, do: System.put_env("PATH", executable_path)

        assert {:ok, suffix} =
                 Grep.execute(%{"pattern" => "marker", "glob" => "*.{ex,exs}"}, %{
                   working_directory: root
                 })

        assert suffix =~ "lib/deep/file.ex"
        refute suffix =~ "file.txt"

        assert {:ok, nested} =
                 Grep.execute(%{"pattern" => "marker", "glob" => "lib/*.ex"}, %{
                   working_directory: root
                 })

        assert nested =~ "lib/deep/file.ex"
      end
    after
      if original_path, do: System.put_env("PATH", original_path), else: System.delete_env("PATH")
    end
  end

  defp restore(key, nil), do: Application.delete_env(:handbean, key)
  defp restore(key, value), do: Application.put_env(:handbean, key, value)
end
