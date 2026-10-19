defmodule Handbean.Skills.BundledSkillsTest do
  use ExUnit.Case, async: true

  alias Handbean.Skills.Loader

  @moduletag :tmp_dir
  @bundled_name "developing-handbean-extensions"
  @max_skill_bytes 65_536

  setup %{tmp_dir: tmp} do
    workspace = Path.join(tmp, "workspace")
    home = Path.join(tmp, "home")
    File.mkdir_p!(workspace)
    File.mkdir_p!(home)
    {:ok, workspace: workspace, home: home, opts: [workspace: workspace, user_home: home]}
  end

  test "release priv skills are loadable as bundled", c do
    assert {:ok, skill, content} = Loader.load_named(@bundled_name, c.opts)
    assert skill.source == :bundled
    assert skill.name == @bundled_name
    assert skill.disable_model_invocation == false
    assert content =~ "ext__"
    assert content =~ ".handbean/extensions"
    assert byte_size(content) <= @max_skill_bytes
  end

  test "project skill of the same name wins over bundled", c do
    dir = Path.join([c.workspace, ".handbean", "skills", @bundled_name])
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "SKILL.md"),
      """
      ---
      name: #{@bundled_name}
      description: Override bundled plugin skill
      ---

      project override body
      """
    )

    assert {:ok, skill, content} = Loader.load_named(@bundled_name, c.opts)
    assert skill.source == :project
    assert content =~ "project override body"
    refute content =~ "Write a **Handbean plugin"
  end

  test "shipped SKILL.md stays within the loader size cap" do
    path =
      Path.join([
        Application.app_dir(:handbean, "priv/skills"),
        @bundled_name,
        "SKILL.md"
      ])

    assert {:ok, %{size: size}} = File.stat(path)
    assert size <= @max_skill_bytes
  end

  test "a real priv/skills directory is a bundled root", %{tmp_dir: tmp} do
    priv = Path.join(tmp, "priv")
    skills = Path.join(priv, "skills")
    File.mkdir_p!(Path.join(skills, "demo"))
    write_named_skill(Path.join(skills, "demo"), "demo", "real layout")
    {:ok, canonical_skills} = Handbean.Security.PathValidator.canonicalize(skills)

    assert Loader.bundled_dirs_from_priv(priv) == [{canonical_skills, :bundled}]
  end

  if match?({:unix, _}, :os.type()) do
    test "a skills root that redirects outside priv is rejected", %{tmp_dir: tmp} do
      priv = Path.join(tmp, "priv")
      File.mkdir_p!(priv)
      outside = Path.join(tmp, "outside-skills")
      File.mkdir_p!(Path.join(outside, "evil"))
      write_named_skill(Path.join(outside, "evil"), "evil", "should not load")
      assert :ok = File.ln_s(outside, Path.join(priv, "skills"))
      assert Loader.bundled_dirs_from_priv(priv) == []
    end

    test "a Mix-style priv symlink still loads skills under the canonical priv", %{tmp_dir: tmp} do
      real_priv = Path.join(tmp, "real-priv")
      skills = Path.join(real_priv, "skills")
      File.mkdir_p!(skills)
      app_dir = Path.join(tmp, "app")
      File.mkdir_p!(app_dir)
      linked_priv = Path.join(app_dir, "priv")
      assert :ok = File.ln_s(real_priv, linked_priv)
      {:ok, canonical_skills} = Handbean.Security.PathValidator.canonicalize(skills)

      assert Loader.bundled_dirs_from_priv(linked_priv) == [{canonical_skills, :bundled}]
    end

    test "symlink children under a real skills root are not loaded", %{tmp_dir: tmp} do
      priv = Path.join(tmp, "priv")
      skills = Path.join(priv, "skills")
      File.mkdir_p!(Path.join(skills, "ok"))
      write_named_skill(Path.join(skills, "ok"), "ok", "real skill")

      outside = Path.join(tmp, "outside")
      File.mkdir_p!(Path.join(outside, "secret"))
      write_named_skill(Path.join(outside, "secret"), "secret", "outside secret")
      assert :ok = File.ln_s(Path.join(outside, "secret"), Path.join(skills, "linked-dir"))

      linked_file_dir = Path.join(skills, "linked-file")
      File.mkdir_p!(linked_file_dir)

      assert :ok =
               File.ln_s(
                 Path.join(outside, "secret/SKILL.md"),
                 Path.join(linked_file_dir, "SKILL.md")
               )

      [{root, :bundled}] = Loader.bundled_dirs_from_priv(priv)
      result = Loader.load_from_dir(root, :bundled)
      names = Enum.map(result.skills, & &1.name)
      assert names == ["ok"]
      refute "secret" in names
    end
  end

  defp write_named_skill(dir, name, body) do
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "SKILL.md"),
      """
      ---
      name: #{name}
      description: #{name}
      ---

      #{body}
      """
    )
  end
end
