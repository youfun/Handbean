defmodule Handbean.Skills.NamedLoadingTest do
  use ExUnit.Case, async: true

  alias Handbean.Skills.{Expander, Loader}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    workspace = Path.join(tmp, "workspace")
    home = Path.join(tmp, "home")
    File.mkdir_p!(workspace)
    File.mkdir_p!(home)
    {:ok, workspace: workspace, home: home, opts: [workspace: workspace, user_home: home]}
  end

  test "project overrides user and handbean precedes agents", c do
    write_skill(c.home, ".agents", "review", "user agents")
    write_skill(c.home, ".handbean", "review", "user handbean")
    write_skill(c.workspace, ".agents", "review", "project agents")
    path = write_skill(c.workspace, ".handbean", "review", "project handbean")

    assert {:ok, skill, content} = Loader.load_named("review", c.opts)
    assert skill.source == :project
    assert skill.location == path
    assert content =~ "project handbean"
    refute content =~ "project agents"
    refute content =~ "user handbean"
  end

  test "global roots work outside workspace but other home directories do not", c do
    write_skill(c.home, ".handbean", "global-one", "global body one")
    write_skill(c.home, ".agents", "global-two", "global body two")
    write_skill(c.home, ".other", "outside", "private content")

    for name <- ["global-one", "global-two"] do
      assert {:ok, %{source: :user}, _} = Loader.load_named(name, c.opts)
    end

    assert {:error, _} = Loader.load_named("outside", c.opts)
    assert {:error, _} = Loader.load_named("unknown", c.opts)
  end

  test "explicit configured sources are subordinate and confined to allowed roots", c do
    explicit = write_skill(c.workspace, "custom", "review", "explicit body")
    outside = write_skill(c.home, ".other", "outside", "private body")
    opts = Keyword.put(c.opts, :skill_paths, [Path.dirname(explicit), Path.dirname(outside)])

    assert {:ok, %{source: :explicit}, content} = Loader.load_named("review", opts)
    assert content =~ "explicit body"
    assert {:error, _} = Loader.load_named("outside", opts)

    write_skill(c.home, ".agents", "review", "default user body")
    assert {:ok, %{source: :user}, content} = Loader.load_named("review", opts)
    assert content =~ "default user body"
  end

  test "names are not interpreted as paths", c do
    for name <- ["../secret", "/etc/passwd", "a/b", "a\\b", ".", "..", "", "a\0b", nil] do
      assert {:error, "Invalid skill name"} = Loader.load_named(name, c.opts)
    end
  end

  test "rereads content and invocation flag, while explicit user expansion is retained", c do
    path = write_skill(c.workspace, ".handbean", "review", "first body")
    discovered = Loader.load(c.opts).skills
    assert {:ok, _, original} = Loader.load_named("review", c.opts)
    assert original =~ "first body"

    write_skill(c.workspace, ".handbean", "review", "更新后的正文")
    assert {:ok, _, updated} = Loader.load_named("review", c.opts)
    assert updated =~ "更新后的正文"
    refute updated =~ "first body"

    File.write!(
      path,
      "---\nname: review\ndescription: Review\ndisable-model-invocation: true\n---\nUser only"
    )

    assert {:error, reason} = Loader.load_named("review", c.opts)
    assert reason =~ "disables model invocation"

    assert Expander.expand("/skill:review 检查中文参数", discovered) =~
             "User only\n</skill>\n\n检查中文参数"

    assert Expander.expand("/skill:review 用户显式加载", Loader.load(c.opts).skills) =~ "User only"

    File.rm!(path)
    assert {:error, _} = Loader.load_named("review", c.opts)
  end

  test "disabled project skill does not fall back to enabled global duplicate", c do
    write_skill(c.home, ".handbean", "review", "global body")
    path = write_skill(c.workspace, ".handbean", "review", "project body")

    File.write!(
      path,
      "---\nname: review\ndescription: Review\ndisable-model-invocation: true\n---\nDisabled"
    )

    assert {:error, reason} = Loader.load_named("review", c.opts)
    assert reason =~ "disables model invocation"
  end

  test "file byte limit is inclusive and rejects oversized content without partial success", c do
    path = write_skill(c.workspace, ".handbean", "sized", "")
    header = File.read!(path)
    File.write!(path, header <> String.duplicate("x", 65_536 - byte_size(header)))
    assert {:ok, _, content} = Loader.load_named("sized", c.opts)
    assert byte_size(content) == 65_536

    File.write!(path, content <> "x")
    assert {:error, _} = Loader.load_named("sized", c.opts)
    assert [%{type: :error}] = Loader.load(c.opts).diagnostics
  end

  test "unreadable, nonregular, malformed metadata and invalid UTF-8 files are unavailable", c do
    path = write_skill(c.workspace, ".handbean", "bad", "body")
    File.chmod!(path, 0o000)
    assert {:error, _} = Loader.load_named("bad", c.opts)
    File.chmod!(path, 0o600)

    File.write!(path, <<255, 0>>)
    assert {:error, _} = Loader.load_named("bad", c.opts)

    File.write!(path, "---\nname: true\ndescription: false\n---\nbody")
    assert {:error, _} = Loader.load_named("bad", c.opts)
    assert [%{message: "name and description must be strings"}] = Loader.load(c.opts).diagnostics

    File.rm!(path)
    File.mkdir!(path)
    assert {:error, _} = Loader.load_named("bad", c.opts)
  end

  test "file and directory symlinks cannot import content from outside a skill root", c do
    outside = write_skill(c.home, ".other", "secret", "outside secret")
    root = Path.join(c.workspace, ".handbean/skills")
    linked_dir = Path.join(root, "linked-file")
    File.mkdir_p!(linked_dir)
    File.ln_s!(outside, Path.join(linked_dir, "SKILL.md"))
    File.ln_s!(Path.dirname(outside), Path.join(root, "linked-directory"))
    File.ln_s!(root, Path.join(root, "loop"))

    assert Enum.reject(Loader.load(c.opts).skills, &(&1.source == :bundled)) == []
    assert {:error, _} = Loader.load_named("secret", c.opts)
  end

  test "configured skill root and its parent cannot redirect to another home directory", c do
    outside = write_skill(c.home, ".other", "secret", "outside secret")
    File.ln_s!(Path.join(c.home, ".other"), Path.join(c.home, ".handbean"))
    File.mkdir_p!(Path.join(c.workspace, ".agents"))

    File.ln_s!(
      Path.join(c.home, ".other/skills"),
      Path.join(c.workspace, ".agents/skills")
    )

    assert Enum.reject(Loader.load(c.opts).skills, &(&1.source == :bundled)) == []
    assert {:error, _} = Loader.load_named("secret", c.opts)

    opts = Keyword.put(c.opts, :skill_paths, [Path.dirname(outside)])
    assert {:error, _} = Loader.load_named("secret", opts)
  end

  test "a previously discovered file replaced by an escaping symlink is rejected", c do
    path = write_skill(c.workspace, ".handbean", "review", "allowed body")
    assert {:ok, _, _} = Loader.load_named("review", c.opts)
    outside = write_skill(c.home, ".other", "review", "private replacement")
    File.rm!(path)
    File.ln_s!(outside, path)

    assert {:error, _} = Loader.load_named("review", c.opts)
  end

  defp write_skill(anchor, namespace, name, body) do
    dir = Path.join([anchor, namespace, "skills", name])
    File.mkdir_p!(dir)
    path = Path.join(dir, "SKILL.md")
    File.write!(path, "---\nname: #{name}\ndescription: Test skill\n---\n#{body}")
    path
  end
end
