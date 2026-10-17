defmodule Handbean.Agent.Subagent.ProfileTest do
  @moduledoc """
  Failure list for profile parsing (docs/subagent-plan.md §4.4):

  - missing name / description / body / frontmatter → rejected
  - name outside `^[a-z][a-z0-9_-]{0,39}$` → rejected
  - delegation tools in `tools` → stripped with a warning
  - `mode: write` without `isolation: worktree` → rejected
  - `max_turns` outside 1..32, `timeout_ms` outside 5_000..1_800_000 → rejected
  - unknown model → registered, fails at run time
  - override of a builtin name → keeps builtin tool ceiling, mode, isolation
  - bash without a host shell → dropped; worktree profile without shell+git → hidden

  Invariant: a profile never yields a tool the parent run is not authorized for.
  """
  use ExUnit.Case, async: true

  alias Handbean.Agent.Subagent.Profile

  defp md(front, body \\ "Stay inside the task.") do
    "---\n#{front}\n---\n#{body}\n"
  end

  test "accepts a complete read-only profile" do
    assert {:ok, profile, []} =
             Profile.parse(
               md("""
               name: test-runner
               description: run specified tests
               tools: [read, grep, bash]
               mode: read_only
               max_turns: 6
               timeout_ms: 180000
               """)
             )

    assert profile.name == "test-runner"
    assert profile.tools == ["read", "grep", "bash"]
    assert profile.mode == :read_only
    assert profile.isolation == :shared
    assert profile.max_turns == 6
    assert profile.timeout_ms == 180_000
    assert profile.system_prompt == "Stay inside the task."
    assert profile.source == :workspace
  end

  test "rejects a missing name, description, or body" do
    assert {:error, "missing name"} = Profile.parse(md("description: x"))
    assert {:error, "missing description"} = Profile.parse(md("name: ok"))
    assert {:error, "missing body"} = Profile.parse(md("name: ok\ndescription: x", ""))
    assert {:error, "missing frontmatter or body"} = Profile.parse("just text")
  end

  test "rejects a name outside the allowed pattern" do
    for name <- ["Test", "1abc", "has space", "has.dot", String.duplicate("a", 41)] do
      assert {:error, "invalid name"} = Profile.parse(md("name: #{name}\ndescription: x"))
    end
  end

  test "strips delegation tools and warns instead of registering them" do
    assert {:ok, profile, [warning]} =
             Profile.parse(
               md("""
               name: curious
               description: looks around
               tools: [read, task, advisor, task_status, create_thread]
               """)
             )

    assert profile.tools == ["read"]
    assert warning =~ "task"
    assert warning =~ "advisor"
  end

  test "rejects write mode unless isolation is worktree" do
    assert {:error, "mode write requires isolation worktree"} =
             Profile.parse(md("name: writer\ndescription: writes\nmode: write"))

    assert {:error, "mode write requires isolation worktree"} =
             Profile.parse(
               md("name: writer\ndescription: writes\nmode: write\nisolation: shared")
             )

    assert {:ok, profile, []} =
             Profile.parse(
               md(
                 "name: writer\ndescription: writes\nmode: write\nisolation: worktree\ntools: [write]"
               )
             )

    assert profile.mode == :write
    assert profile.isolation == :worktree
  end

  test "rejects max_turns and timeout_ms outside their ranges" do
    assert {:error, "invalid max_turns"} =
             Profile.parse(md("name: a\ndescription: x\nmax_turns: 0"))

    assert {:error, "invalid max_turns"} =
             Profile.parse(md("name: a\ndescription: x\nmax_turns: 33"))

    assert {:error, "invalid timeout_ms"} =
             Profile.parse(md("name: a\ndescription: x\ntimeout_ms: 4999"))

    assert {:error, "invalid timeout_ms"} =
             Profile.parse(md("name: a\ndescription: x\ntimeout_ms: 1800001"))
  end

  test "keeps an unknown model for a runtime error instead of rejecting registration" do
    assert {:ok, profile, []} =
             Profile.parse(md("name: a\ndescription: x\nmodel: missing/model"))

    assert profile.model == {"missing", "model"}
  end

  test "intersecting tools cannot widen a parent authorization ceiling" do
    {:ok, workspace, _} =
      Profile.parse(
        md("""
        name: researcher
        description: override
        tools: [read, write, bash, task]
        """),
        source: :workspace
      )

    builtin = Profile.researcher()
    narrowed = %{workspace | tools: Profile.intersect_tools(workspace, builtin.tools)}
    assert narrowed.tools == ["read"]
    refute "write" in narrowed.tools
    refute "task" in narrowed.tools
  end

  test "user and workspace overrides of a builtin keep its tool ceiling, mode, and isolation" do
    {:ok, override, _} =
      Profile.parse(
        md("""
        name: researcher
        description: override
        tools: [read, write, bash]
        mode: write
        isolation: worktree
        """),
        source: :workspace
      )

    [merged] =
      Handbean.Agent.Subagent.ProfileRegistry.merge([[Profile.researcher()], [override]])

    assert merged.system_prompt == "Stay inside the task."
    assert merged.tools == ["read"]
    assert merged.mode == :read_only
    assert merged.isolation == :shared
  end

  test "a new workspace profile cannot grant itself write or shell access" do
    root = Path.join(System.tmp_dir!(), "profiles-#{System.unique_integer([:positive])}")
    home = Path.join(root, "home")
    File.mkdir_p!(Path.join(root, ".handbean/agents"))
    on_exit(fn -> File.rm_rf!(root) end)

    File.write!(
      Path.join(root, ".handbean/agents/test-runner.md"),
      md(
        "name: test-runner\ndescription: runs tests\ntools: [read, bash, write, edit]\nmode: write\nisolation: worktree"
      )
    )

    File.write!(Path.join(root, ".handbean/agents/broken.md"), md("name: Broken\ndescription: x"))

    alias Handbean.Agent.Subagent.ProfileRegistry

    names = root |> ProfileRegistry.list(home: home) |> Enum.map(& &1.name)
    assert names == ["advisor", "researcher", "test-runner"]

    runner =
      root
      |> ProfileRegistry.available(["read", "bash", "write", "edit"],
        home: home,
        shell?: true
      )
      |> Enum.find(&(&1.name == "test-runner"))

    assert runner.tools == ["read"]
    assert runner.mode == :read_only
    assert runner.isolation == :shared
  end

  test "a trusted user profile may define a write-mode agent" do
    {:ok, writer, _} =
      Profile.parse(
        md(
          "name: writer\ndescription: writes\ntools: [read, bash, write, edit]\nmode: write\nisolation: worktree"
        ),
        source: :user
      )

    merged = Handbean.Agent.Subagent.ProfileRegistry.merge([[Profile.builtin()], [writer]])
    writer = Enum.find(merged, &(&1.name == "writer"))

    assert writer.tools == ["read", "bash", "write", "edit"]
    assert writer.mode == :write
    assert writer.isolation == :worktree
  end

  test "a workspace override cannot inherit write access from a trusted user profile" do
    {:ok, user_writer, _} =
      Profile.parse(
        md(
          "name: writer\ndescription: trusted writer\ntools: [read, bash, write, edit]\nmode: write\nisolation: worktree"
        ),
        source: :user
      )

    {:ok, workspace_writer, _} =
      Profile.parse(
        md(
          "name: writer\ndescription: repository override\ntools: [read, bash, write, edit]\nmode: write\nisolation: worktree"
        ),
        source: :workspace
      )

    merged =
      Handbean.Agent.Subagent.ProfileRegistry.merge([
        [Profile.builtin()],
        [user_writer],
        [workspace_writer]
      ])

    writer = Enum.find(merged, &(&1.name == "writer"))
    assert writer.tools == ["read"]
    assert writer.mode == :read_only
    assert writer.isolation == :shared
  end

  test "host filtering drops bash without a shell and hides worktree profiles" do
    {:ok, profile, _} =
      Profile.parse(md("name: a\ndescription: x\ntools: [read, bash]"))

    assert Profile.host_tools(profile, shell?: false) == ["read"]

    {:ok, writer, _} =
      Profile.parse(md("name: writer\ndescription: writes\nmode: write\nisolation: worktree"))

    refute Profile.available?(writer, shell?: false, git?: true)
    refute Profile.available?(writer, shell?: true, git?: false)
    assert Profile.available?(writer, shell?: true, git?: true)
    assert Profile.available?(profile, shell?: false, git?: false)
  end
end
