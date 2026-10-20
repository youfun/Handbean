defmodule Handbean.Jobs.SandboxTest do
  use ExUnit.Case, async: false

  alias Handbean.Jobs
  alias Handbean.Platform.{ProcessManager, ProcessRunner}
  alias Handbean.Tool.Builtin.Bash

  setup do
    workspace = Path.join(System.tmp_dir!(), "job-sandbox-#{Ecto.UUID.generate()}")
    File.mkdir_p!(workspace)

    context = %{
      conversation_id: Ecto.UUID.generate(),
      run_id: Ecto.UUID.generate(),
      working_directory: workspace,
      tool_call_id: "sandbox",
      tool_timeout: 10_000
    }

    :ok = Jobs.open_run(context, self())

    on_exit(fn ->
      Jobs.close_run(context, :completed)
      File.rm_rf!(workspace)
      File.rm(workspace <> "-outside")
    end)

    %{workspace: workspace, context: context}
  end

  @tag :os_sandbox
  test "job Bash persists workspace writes but isolates computed outside writes", %{
    workspace: workspace,
    context: context
  } do
    command =
      "target=$(printf '%s' '#{workspace}-outside'); printf probe > \"$target\"; printf inside > result.txt"

    assert {:ok, _, %{job: %{job_id: id}}} =
             Bash.execute(%{"command" => command, "job" => true, "wait_ms" => 100}, context)

    assert {:ok, %{state: :completed, exit_code: 0}} = Jobs.status(id, 0, 5000, context)
    assert File.read!(Path.join(workspace, "result.txt")) == "inside"
    refute File.exists?(workspace <> "-outside")
  end

  @tag :os_sandbox
  test "managed and explicit jobs retain cwd authorization without granting outside writes", %{
    workspace: workspace,
    context: context
  } do
    outside = workspace <> "-cwd"
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "fixture.txt"), "external-readable")
    on_exit(fn -> File.rm_rf!(outside) end)

    assert {:error, reason} = Jobs.start("pwd", outside, 10_000, 1_000, context)
    assert reason =~ "Path traversal"

    for approval_mode <- [:yolo, :smart], explicit? <- [false, true] do
      id = "#{approval_mode}-#{explicit?}"

      scoped =
        Map.merge(context, %{
          workspace_id: "job-workspace",
          tool_call_id: id,
          approval_mode: approval_mode
        })

      input = %{
        "command" =>
          "cat fixture.txt && printf inside > '#{workspace}/#{id}.txt'; " <>
            "if (printf forbidden > forbidden.txt) 2>/dev/null; then exit 99; fi",
        "cwd" => outside,
        "job" => explicit?,
        "wait_ms" => 100
      }

      approved =
        if approval_mode == :smart do
          call = %{id: id, name: "bash", input: input}
          requirement = Handbean.Permissions.Boundary.requirement(call, scoped)
          grant = Handbean.Permissions.Boundary.grant(call, scoped, requirement, :human)

          scoped
          |> Map.put(:tool_execution_grants, %{id => grant})
          |> Handbean.Permissions.Boundary.invocation_context(call)
        else
          scoped
        end

      assert {:ok, _, %{job: %{job_id: job_id}}} = Bash.execute(input, approved)

      assert {:ok, %{state: :completed, exit_code: 0, output: "external-readable"}} =
               Jobs.status(job_id, 0, 5_000, context)

      assert File.read!(Path.join(workspace, "#{id}.txt")) == "inside"
      refute File.exists?(Path.join(outside, "forbidden.txt"))
    end

    assert {:error, reason} =
             Jobs.start("pwd", outside, 10_000, 1_000, %{context | tool_call_id: "next"})

    assert reason =~ "Path traversal"
  end

  @tag :os_sandbox
  test "sandbox gate retains verified group cancellation before user code executes", %{
    workspace: workspace
  } do
    {:ok, port, pid} =
      ProcessRunner.open_gated_bash("printf unsafe > marker", workspace,
        workspace_path: workspace
      )

    on_exit(fn -> if Port.info(port), do: Port.close(port) end)
    {:ok, identity} = ProcessManager.verify_job_group(pid)
    refute File.exists?(Path.join(workspace, "marker"))
    assert :ok = ProcessManager.cleanup_job_group(identity)
    assert_receive {^port, {:exit_status, _}}, 5000
    refute File.exists?(Path.join(workspace, "marker"))
  end

  test "missing sandbox refuses gated launch rather than falling back to shell", %{
    workspace: workspace
  } do
    assert {:error, message} =
             ProcessRunner.open_gated_bash("printf unsafe > marker", workspace,
               workspace_path: workspace,
               sandbox_path: Path.join(workspace, "missing-bwrap")
             )

    assert message =~ "Sandbox executable not found" or
             message =~ "Workspace-confined bash is not supported"

    refute File.exists?(Path.join(workspace, "marker"))
  end
end
