defmodule Handbean.Tool.Builtin.RunElixirScriptTest do
  use ExUnit.Case, async: false

  alias Handbean.Tool.Builtin.ElixirScriptIO
  alias Handbean.Tool.Builtin.RunElixirScript

  setup do
    work =
      Path.join(System.tmp_dir!(), "sigil_elixir_script_#{System.unique_integer([:positive])}")

    File.mkdir_p!(work)
    on_exit(fn -> File.rm_rf!(work) end)
    {:ok, work: work, ctx: %{working_directory: work}}
  end

  defp write_script(work, name, source) do
    path = Path.join(work, name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, source)
    path
  end

  defp run(work, ctx, name, source, input \\ %{}) do
    write_script(work, name, source)
    RunElixirScript.execute(Map.merge(%{"path" => name}, input), ctx)
  end

  test "evaluates zip and crypto on an actual .exs file", %{work: work, ctx: ctx} do
    source = """
    {:ok, {_name, zip}} = :zip.create(~c"mem.zip", [{~c"a.txt", "hello"}], [:memory])
    hash = :crypto.hash(:sha256, zip)
    {byte_size(zip), Base.encode16(hash, case: :lower)}
    """

    assert {:ok, output, data} = run(work, ctx, "zip_hash.exs", source)
    assert output =~ "return:"
    assert data.return =~ ~r/^\{[1-9][0-9]*, "[0-9a-f]{64}"\}$/
  end

  test "injects args and workspace without touching argv or cwd", %{work: work, ctx: ctx} do
    argv_before = System.argv()
    cwd_before = File.cwd!()

    source = """
    IO.puts("args=" <> Enum.join(args, ","))
    IO.puts("workspace=" <> workspace)
    {args, workspace, System.argv(), File.cwd!()}
    """

    assert {:ok, output, data} =
             run(work, ctx, "binds.exs", source, %{"args" => ["alpha", "beta"]})

    assert output =~ "args=alpha,beta"
    assert output =~ "workspace=" <> work
    assert data.stdout =~ "args=alpha,beta"
    assert System.argv() == argv_before
    assert File.cwd!() == cwd_before
    assert data.return =~ inspect(["alpha", "beta"])
    assert data.return =~ work
  end

  test "caps unicode stdout on a UTF-8 boundary", %{work: work, ctx: ctx} do
    source = """
    IO.write(String.duplicate("你", 20_000))
    :ok
    """

    assert {:ok, output, data} = run(work, ctx, "unicode.exs", source)
    assert data.stdout_truncated?
    assert output =~ "stdout truncated"
    assert String.valid?(data.stdout)
    refute String.ends_with?(data.stdout, <<0xE4>>)
    assert String.ends_with?(data.stdout, "你")
    assert byte_size(data.stdout) <= 32_768
  end

  test "returns bounded raise text with file metadata", %{work: work, ctx: ctx} do
    source = """
    raise "script-boom"
    """

    assert {:error, message, data} = run(work, ctx, "boom.exs", source)
    assert message =~ "script-boom"
    assert message =~ "boom.exs"
    assert data.path =~ "boom.exs"
  end

  test "returns bounded exit text", %{work: work, ctx: ctx} do
    source = """
    exit(:script_bye)
    """

    assert {:error, message, _data} = run(work, ctx, "exit.exs", source)
    assert message =~ "exit"
    assert message =~ "script_bye"
  end

  test "times out and does not leave the worker or IO process", %{work: work, ctx: ctx} do
    name = :"elixir_script_timeout_#{System.unique_integer([:positive])}"
    Process.register(self(), name)

    source = """
    send(String.to_atom(hd(args)), {:started, self(), Process.group_leader()})
    receive do
      :never -> :ok
    end
    """

    task =
      Task.async(fn ->
        run(work, ctx, "hang.exs", source, %{
          "args" => [Atom.to_string(name)],
          "timeout_ms" => 150
        })
      end)

    assert_receive {:started, worker, io}, 1_000
    assert {:error, message, data} = Task.await(task, 2_000)
    assert message =~ "timed out"
    assert data.timed_out
    refute Process.alive?(worker)
    refute Process.alive?(io)
  end

  test "kills worker and IO when the execute caller dies", %{work: work, ctx: ctx} do
    name = :"elixir_script_cancel_#{System.unique_integer([:positive])}"
    Process.register(self(), name)

    source = """
    send(String.to_atom(hd(args)), {:started, self(), Process.group_leader()})
    receive do
      :never -> :ok
    end
    """

    {:ok, caller} =
      Task.start(fn ->
        run(work, ctx, "cancel.exs", source, %{
          "args" => [Atom.to_string(name)],
          "timeout_ms" => 30_000
        })
      end)

    assert_receive {:started, worker, io}, 1_000
    caller_ref = Process.monitor(caller)
    worker_ref = Process.monitor(worker)
    io_ref = Process.monitor(io)
    Process.exit(caller, :kill)

    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}, 1_000
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 1_000
    assert_receive {:DOWN, ^io_ref, :process, ^io, _}, 1_000
  end

  test "rejects missing path, traversal, symlink, and oversize source", %{work: work, ctx: ctx} do
    assert {:error, "path is required"} = RunElixirScript.execute(%{}, ctx)
    assert {:error, reason} = RunElixirScript.execute(%{"path" => "missing.exs"}, ctx)
    assert reason =~ "not found"

    File.write!(Path.join(work, "notes.txt"), "IO.puts(1)\n")
    assert {:error, ext} = RunElixirScript.execute(%{"path" => "notes.txt"}, ctx)
    assert ext =~ ".exs"

    outside =
      Path.join(
        System.tmp_dir!(),
        "sigil_elixir_outside_#{System.unique_integer([:positive])}.exs"
      )

    File.write!(outside, "1\n")
    on_exit(fn -> File.rm_rf!(outside) end)

    link = Path.join(work, "escape.exs")
    File.ln_s!(outside, link)
    assert {:error, symlink} = RunElixirScript.execute(%{"path" => "escape.exs"}, ctx)
    assert symlink =~ "regular" or symlink =~ "outside" or symlink =~ "traversal"

    big = write_script(work, "big.exs", :binary.copy("x", 256_001))
    assert File.exists?(big)
    assert {:error, size} = RunElixirScript.execute(%{"path" => "big.exs"}, ctx)
    assert size =~ "exceeds"
  end

  test "empty .exs evaluates to nil", %{work: work, ctx: ctx} do
    write_script(work, "empty.exs", "")
    assert {:ok, output, data} = RunElixirScript.execute(%{"path" => "empty.exs"}, ctx)
    assert output =~ "return:"
    assert data.return == "nil"
  end

  test "rejects timeout_ms above the executor tool timeout", %{work: _work, ctx: ctx} do
    assert {:error, message} =
             RunElixirScript.execute(%{"path" => "a.exs", "timeout_ms" => 300_000}, ctx)

    assert message =~ "60000"
  end

  test "does not leak a caller watcher after a short script", %{work: work, ctx: ctx} do
    before = monitored_by(self())
    assert {:ok, _output, _data} = run(work, ctx, "quick.exs", "1 + 1\n")
    leaked = MapSet.difference(monitored_by(self()), before)
    assert MapSet.size(leaked) == 0
  end

  test "times out hostile Inspect inside the worker", %{work: work, ctx: ctx} do
    source = """
    %Handbean.Tool.Builtin.ElixirScriptHangInspect{}
    """

    assert {:error, message, data} =
             run(work, ctx, "hang_inspect.exs", source, %{"timeout_ms" => 200})

    assert message =~ "timed out"
    assert data.timed_out
  end

  test "latin1 writes become UTF-8 and invalid unicode is not stored as raw bytes" do
    io = ElixirScriptIO.start_link(64)
    assert :ok = put_chars(io, :latin1, <<0xE4, 0xF6>>)
    snap = ElixirScriptIO.snapshot(io)
    assert snap.text == "äö"
    refute snap.truncated?

    assert :ok = put_chars(io, :unicode, <<0xFF>>)
    snap = ElixirScriptIO.snapshot(io)
    assert snap.text == "äö"
    assert snap.truncated?
    refute String.contains?(snap.text, <<0xFF>>)
    ElixirScriptIO.stop(io)
  end

  test "stops appending after a truncated multibyte write and ignores empty writes" do
    io = ElixirScriptIO.start_link(5)
    assert :ok = put_chars(io, :unicode, "你你")
    first = ElixirScriptIO.snapshot(io)
    assert first.truncated?
    assert first.text == "你"
    assert byte_size(first.text) == 3

    Enum.each(1..200, fn _ -> put_chars(io, :unicode, "") end)
    assert :ok = put_chars(io, :unicode, "x")
    second = ElixirScriptIO.snapshot(io)
    assert second.text == "你"
    refute second.text =~ "x"
    ElixirScriptIO.stop(io)
  end

  defp monitored_by(pid) do
    {:monitored_by, pids} = Process.info(pid, :monitored_by)
    MapSet.new(pids)
  end

  defp put_chars(pid, encoding, chars) do
    reply = make_ref()
    send(pid, {:io_request, self(), reply, {:put_chars, encoding, chars}})
    assert_receive {:io_reply, ^reply, :ok}, 1_000
    :ok
  end
end
