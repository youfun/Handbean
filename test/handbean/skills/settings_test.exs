defmodule Handbean.Skills.SettingsTest do
  use ExUnit.Case, async: false

  alias Handbean.Plugins.Catalog
  alias Handbean.Skills.Settings

  setup do
    root = Path.join(System.tmp_dir!(), "skills-settings-#{Ecto.UUID.generate()}")
    workspace_dir = Path.join(root, "workspace")
    user_dir = Path.join(root, "user_skills")
    bundled_dir = Path.join(root, "bundled_skills")

    File.mkdir_p!(workspace_dir)
    File.mkdir_p!(user_dir)
    File.mkdir_p!(Path.join(bundled_dir, "bundled-guide"))

    File.write!(
      Path.join([bundled_dir, "bundled-guide", "SKILL.md"]),
      """
      ---
      name: bundled-guide
      description: Built-in operational guide.
      ---
      # Bundled Guide
      """
    )

    on_exit(fn -> File.rm_rf!(root) end)

    %{
      root: root,
      workspace_dir: workspace_dir,
      user_dir: user_dir,
      bundled_dir: bundled_dir,
      opts: [workspace: workspace_dir, user_home: user_dir]
    }
  end

  test "installs template, toggles model invocation on workspace skill, and protects bundled skills",
       %{opts: opts} do
    {:ok, template} = Catalog.get("cat-skill-code-review")
    assert {:ok, "code-review-checklist"} = Settings.install_template(template, "workspace", opts)

    assert {:ok, skills} = Settings.list(opts)
    ws_skill = Enum.find(skills, &(&1.name == "code-review-checklist"))
    bundled = Enum.find(skills, &(&1.source == :bundled))

    assert ws_skill.source == :project
    assert ws_skill.enabled == true
    assert ws_skill.readonly == false

    assert bundled.source == :bundled
    assert bundled.enabled == true
    assert bundled.readonly == true

    assert :ok = Settings.set_enabled("code-review-checklist", false, opts)
    assert {:ok, skills_after} = Settings.list(opts)
    assert Enum.find(skills_after, &(&1.name == "code-review-checklist")).enabled == false

    assert {:ok, %{content: content}} = Settings.inspect_skill("code-review-checklist", opts)
    assert content =~ "disable-model-invocation: true"

    assert {:error, "内置 Skill 不可直接修改"} = Settings.set_enabled(bundled.name, false, opts)
  end

  test "template install and import reject collisions without overwriting", %{
    root: root,
    opts: opts
  } do
    existing_dir = Path.join([Keyword.fetch!(opts, :workspace), ".handbean/skills/collision"])
    File.mkdir_p!(existing_dir)
    existing = "---\nname: collision\ndescription: Original.\n---\n# Original\n"
    File.write!(Path.join(existing_dir, "SKILL.md"), existing)

    template = %{
      name: "collision",
      content: "---\nname: collision\ndescription: Replacement.\n---\n# Replacement\n"
    }

    assert {:error, message} = Settings.install_template(template, "workspace", opts)
    assert message =~ "同名 Skill 已存在"
    assert File.read!(Path.join(existing_dir, "SKILL.md")) == existing

    source_dir = Path.join(root, "collision-import")
    File.mkdir_p!(source_dir)
    File.write!(Path.join(source_dir, "SKILL.md"), template.content)

    assert {:error, message} = Settings.import_from_dir(source_dir, "workspace", opts)
    assert message =~ "同名 Skill 已存在"
    assert File.read!(Path.join(existing_dir, "SKILL.md")) == existing
  end

  test "imports skill from local directory", %{root: root, opts: opts} do
    source_dir = Path.join(root, "imported-skill")
    File.mkdir_p!(source_dir)

    File.write!(
      Path.join(source_dir, "SKILL.md"),
      """
      ---
      name: imported-skill
      description: Imported local skill.
      ---
      # Imported Skill
      """
    )

    assert {:ok, "imported-skill"} = Settings.import_from_dir(source_dir, "user", opts)
    assert {:ok, skills} = Settings.list(opts)
    imported = Enum.find(skills, &(&1.name == "imported-skill"))
    assert imported.source == :user
    assert imported.enabled == true
  end
end
