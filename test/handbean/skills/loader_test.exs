defmodule Handbean.Skills.LoaderTest do
  @moduledoc """
  Tests for the Skills Loader.

  Covers:
    - Loading SKILL.md from explicit skill dir
    - Recursive discovery of SKILL.md in workspace .handbean/skills
    - Missing description: not loaded, diagnostic returned
    - Invalid name: loaded with warning diagnostic
    - Duplicate name: first retained, second gets collision diagnostic
    - disable-model-invocation: true flag set on skill
    - Frontmatter parsing: name, description, disable-model-invocation, unknown fields
    - Name validation (character rules, length, hyphen rules)
    - Description length validation
    - Hidden directory / node_modules skipping
    - Loader does not read skill body content
  """

  use ExUnit.Case, async: true

  alias Handbean.Skills

  {:ok, canonical_tmp} = Handbean.Security.PathValidator.canonicalize(System.tmp_dir!())

  @tmp_base Path.join(
              canonical_tmp,
              "sigil_skills_test_#{System.unique_integer([:positive])}"
            )

  setup do
    File.mkdir_p!(@tmp_base)

    on_exit(fn ->
      File.rm_rf!(@tmp_base)
    end)

    {:ok, tmp: @tmp_base}
  end

  # ── Helpers ──

  defp write_skill(dir, name \\ nil, desc \\ nil, extra_frontmatter \\ []) do
    File.mkdir_p!(dir)

    parts =
      extra_frontmatter ++
        [
          if(name, do: "name: #{name}"),
          if(desc, do: "description: #{desc}")
        ]

    parts = parts |> Enum.reject(&is_nil/1) |> Enum.join("\n")

    content = """
    ---
    #{parts}
    ---

    # #{name || "Skill"}

    This is the body content.
    """

    path = Path.join(dir, "SKILL.md")
    File.write!(path, content)
    path
  end

  # ── Explicit skill dir loading ──

  describe "load_from_dir/2 explicit dir" do
    test "loads a valid SKILL.md from a skill directory" do
      skill_dir = Path.join(@tmp_base, "code-review")
      write_skill(skill_dir, "code-review", "Review code for bugs")

      result = Skills.Loader.load_from_dir(skill_dir, :explicit)

      assert length(result.skills) == 1
      skill = List.first(result.skills)
      assert skill.name == "code-review"
      assert skill.description == "Review code for bugs"
      assert skill.source == :explicit
      assert skill.disable_model_invocation == false
      assert String.ends_with?(skill.location, "code-review/SKILL.md")
      assert String.ends_with?(skill.base_dir, "code-review")
      assert result.diagnostics == []
    end

    test "does not raise for non-existent directory" do
      result = Skills.Loader.load_from_dir(Path.join(@tmp_base, "nonexistent"), :explicit)
      assert result.skills == []
      assert result.diagnostics == []
    end

    test "stops recursion at SKILL.md — does not recurse further" do
      parent = Path.join(@tmp_base, "parent")
      write_skill(parent, "parent-skill", "Parent description")

      child = Path.join(parent, "child")
      write_skill(child, "child-skill", "Child description")

      result = Skills.Loader.load_from_dir(parent, :explicit)

      # Only parent SKILL.md found; child directory is not recursed into
      assert length(result.skills) == 1
      assert hd(result.skills).name == "parent-skill"
    end
  end

  # ── Recursive discovery ──

  describe "recursive discovery" do
    test "finds SKILL.md in subdirectories when root has no SKILL.md" do
      root = Path.join(@tmp_base, "skills-root")
      File.mkdir_p!(root)

      sub = Path.join(root, "my-skill")
      write_skill(sub, "my-skill", "My skill desc")

      result = Skills.Loader.load_from_dir(root, :project)

      assert length(result.skills) == 1
      assert hd(result.skills).name == "my-skill"
    end

    test "finds multiple skills via recursive discovery" do
      root = Path.join(@tmp_base, "multi-skills")
      File.mkdir_p!(root)

      a = Path.join(root, "a")
      b = Path.join(root, "b")
      write_skill(a, "skill-a", "Description A")
      write_skill(b, "skill-b", "Description B")

      result = Skills.Loader.load_from_dir(root, :project)

      assert length(result.skills) == 2
      names = Enum.map(result.skills, & &1.name)
      assert "skill-a" in names
      assert "skill-b" in names
    end
  end

  # ── Description validation ──

  describe "description validation" do
    test "missing description: skill not loaded, diagnostic returned" do
      dir = Path.join(@tmp_base, "no-desc")
      write_skill(dir, "no-desc", nil)

      result = Skills.Loader.load_from_dir(dir, :explicit)

      assert result.skills == []
      assert length(result.diagnostics) == 1
      assert hd(result.diagnostics).type == :error
      assert hd(result.diagnostics).message =~ "description"
    end

    test "empty description: skill not loaded" do
      dir = Path.join(@tmp_base, "empty-desc")
      write_skill(dir, "empty-desc", "")

      result = Skills.Loader.load_from_dir(dir, :explicit)

      assert result.skills == []
      assert length(result.diagnostics) == 1
    end

    test "whitespace-only description: skill not loaded" do
      dir = Path.join(@tmp_base, "ws-desc")
      write_skill(dir, "ws-desc", "   ")

      result = Skills.Loader.load_from_dir(dir, :explicit)

      assert result.skills == []
      assert length(result.diagnostics) == 1
    end

    test "description exceeds 1024 chars: loaded with warning" do
      dir = Path.join(@tmp_base, "long-desc")
      long_desc = String.duplicate("x", 2048)
      write_skill(dir, "long-desc", long_desc)

      result = Skills.Loader.load_from_dir(dir, :explicit)

      assert length(result.skills) == 1
      assert length(result.diagnostics) == 1
      assert hd(result.diagnostics).type == :warning
      assert hd(result.diagnostics).message =~ "1024"
    end
  end

  # ── Name validation ──

  describe "name validation" do
    test "name matches parent dir: no warning" do
      dir = Path.join(@tmp_base, "valid-name")
      write_skill(dir, "valid-name", "Valid description")

      result = Skills.Loader.load_from_dir(dir, :explicit)
      assert result.diagnostics == []
    end

    test "name mismatches parent dir: warning, skill still loaded" do
      dir = Path.join(@tmp_base, "dir-name")
      write_skill(dir, "mismatched-name", "Description")

      result = Skills.Loader.load_from_dir(dir, :explicit)

      assert length(result.skills) == 1
      assert hd(result.skills).name == "mismatched-name"
      assert length(result.diagnostics) == 1
      assert hd(result.diagnostics).type == :warning
      assert hd(result.diagnostics).message =~ "does not match"
    end

    test "name fallback to parent dir when frontmatter has no name" do
      dir = Path.join(@tmp_base, "fallback-name")
      File.mkdir_p!(dir)

      File.write!(Path.join(dir, "SKILL.md"), """
      ---
      description: Fallback description
      ---

      # Content
      """)

      result = Skills.Loader.load_from_dir(dir, :explicit)

      assert length(result.skills) == 1
      assert hd(result.skills).name == "fallback-name"
      # Name matches parent dir so no warning
      assert Enum.empty?(result.diagnostics)
    end

    test "uppercase letters: warning" do
      dir = Path.join(@tmp_base, "UpCase")
      write_skill(dir, "UpCase", "Description")

      result = Skills.Loader.load_from_dir(dir, :explicit)

      assert length(result.skills) == 1
      assert length(result.diagnostics) >= 1
      assert Enum.any?(result.diagnostics, &(&1.message =~ "invalid characters"))
    end

    test "starts with hyphen: warning" do
      dir = Path.join(@tmp_base, "-start")
      write_skill(dir, "-start", "Description")

      result = Skills.Loader.load_from_dir(dir, :explicit)

      assert length(result.skills) == 1
      assert length(result.diagnostics) >= 1
      assert Enum.any?(result.diagnostics, &(&1.message =~ "start or end with"))
    end

    test "ends with hyphen: warning" do
      dir = Path.join(@tmp_base, "end-")
      write_skill(dir, "end-", "Description")

      result = Skills.Loader.load_from_dir(dir, :explicit)

      assert length(result.skills) == 1
      assert length(result.diagnostics) >= 1
    end

    test "consecutive hyphens: warning" do
      dir = Path.join(@tmp_base, "a--b")
      write_skill(dir, "a--b", "Description")

      result = Skills.Loader.load_from_dir(dir, :explicit)

      assert length(result.skills) == 1
      assert length(result.diagnostics) >= 1
      assert Enum.any?(result.diagnostics, &(&1.message =~ "consecutive"))
    end

    test "name exceeds 64 chars: warning" do
      long_name = String.duplicate("a", 65)
      dir = Path.join(@tmp_base, long_name)
      write_skill(dir, long_name, "Description")

      result = Skills.Loader.load_from_dir(dir, :explicit)

      assert length(result.skills) == 1
      assert length(result.diagnostics) >= 1
      assert Enum.any?(result.diagnostics, &(&1.message =~ "64"))
    end

    test "valid chars: lower, digits, hyphens accepted" do
      dir = Path.join(@tmp_base, "skill-v2")
      write_skill(dir, "skill-v2", "Description")

      result = Skills.Loader.load_from_dir(dir, :explicit)
      assert hd(result.skills).name == "skill-v2"
      assert result.diagnostics == []
    end

    test "underscore in name: warning" do
      dir = Path.join(@tmp_base, "my_skill")
      write_skill(dir, "my_skill", "Description")

      result = Skills.Loader.load_from_dir(dir, :explicit)

      assert length(result.skills) == 1
      assert length(result.diagnostics) >= 1
      assert Enum.any?(result.diagnostics, &(&1.message =~ "invalid characters"))
    end
  end

  # ── Duplicate handling ──

  describe "duplicate name" do
    test "first skill of duplicate name retained, second gets collision diagnostic" do
      skills_dir = Path.join(@tmp_base, ".handbean/skills")
      a_dir = Path.join(skills_dir, "dup-a")
      b_dir = Path.join(skills_dir, "dup-b")
      write_skill(a_dir, "dup-name", "Description first")
      write_skill(b_dir, "dup-name", "Description second")

      # Load via workspace to trigger collision detection
      result = Skills.Loader.load(workspace: @tmp_base, user_home: Path.join(@tmp_base, "home"))

      skills_named_dup = Enum.filter(result.skills, &(&1.name == "dup-name"))

      assert length(skills_named_dup) == 1
      assert hd(skills_named_dup).description == "Description first"

      collisions = Enum.filter(result.diagnostics, &(&1.type == :collision))
      assert length(collisions) >= 1
      assert hd(collisions).message =~ "dup-name"
    end
  end

  # ── disable-model-invocation ──

  describe "disable_model_invocation" do
    test "true sets flag on skill" do
      dir = Path.join(@tmp_base, "disabled-skill")
      write_skill(dir, "disabled-skill", "Description", ["disable-model-invocation: true"])

      result = Skills.Loader.load_from_dir(dir, :explicit)

      assert length(result.skills) == 1
      assert hd(result.skills).disable_model_invocation == true
    end

    test "false (default) sets flag to false" do
      dir = Path.join(@tmp_base, "enabled-skill")
      write_skill(dir, "enabled-skill", "Description", ["disable-model-invocation: false"])

      result = Skills.Loader.load_from_dir(dir, :explicit)

      assert hd(result.skills).disable_model_invocation == false
    end

    test "not specified defaults to false" do
      dir = Path.join(@tmp_base, "default-invoke")
      write_skill(dir, "default-invoke", "Description")

      result = Skills.Loader.load_from_dir(dir, :explicit)
      assert hd(result.skills).disable_model_invocation == false
    end
  end

  # ── Unknown frontmatter fields ──

  describe "unknown frontmatter fields" do
    test "unknown fields go into metadata" do
      dir = Path.join(@tmp_base, "extra-fields")
      File.mkdir_p!(dir)

      File.write!(Path.join(dir, "SKILL.md"), """
      ---
      name: extra-fields
      description: Has extra fields
      custom-tag: experimental
      version: "1.0"
      ---

      # Content
      """)

      result = Skills.Loader.load_from_dir(dir, :explicit)

      assert length(result.skills) == 1
      skill = hd(result.skills)
      assert skill.metadata["custom-tag"] == "experimental"
      assert skill.metadata["version"] == "1.0"
    end
  end

  # ── Hidden / node_modules skipping ──

  describe "directory skipping" do
    test "skips hidden directories (starting with dot)" do
      root = Path.join(@tmp_base, "skip-root")
      File.mkdir_p!(root)

      hidden = Path.join(root, ".hidden")
      write_skill(hidden, "hidden-skill", "Hidden description")

      normal = Path.join(root, "normal")
      write_skill(normal, "normal-skill", "Normal description")

      result = Skills.Loader.load_from_dir(root, :project)

      names = Enum.map(result.skills, & &1.name)
      assert "normal-skill" in names
      refute "hidden-skill" in names
    end

    test "skips node_modules directory" do
      root = Path.join(@tmp_base, "nm-root")
      File.mkdir_p!(root)

      nm = Path.join(root, "node_modules")
      write_skill(nm, "nm-skill", "NM description")

      normal = Path.join(root, "normal")
      write_skill(normal, "normal-skill", "Normal description")

      result = Skills.Loader.load_from_dir(root, :project)

      names = Enum.map(result.skills, & &1.name)
      assert "normal-skill" in names
      refute "nm-skill" in names
    end
  end

  # ── High-level loader ──

  describe "load/1" do
    test "loads from workspace .handbean/skills directory" do
      workspace = Path.join(@tmp_base, "ws")
      skills_dir = Path.join(workspace, ".handbean/skills")
      File.mkdir_p!(skills_dir)

      sub = Path.join(skills_dir, "ws-skill")
      write_skill(sub, "ws-skill", "Workspace skill")

      result = Skills.Loader.load(workspace: workspace, user_home: Path.join(@tmp_base, "home"))

      assert length(result.skills) >= 1
      names = Enum.map(result.skills, & &1.name)
      assert "ws-skill" in names
    end

    test "loads from workspace .agents/skills directory" do
      workspace = Path.join(@tmp_base, "ws2")
      skills_dir = Path.join(workspace, ".agents/skills")
      File.mkdir_p!(skills_dir)

      sub = Path.join(skills_dir, "agent-skill")
      write_skill(sub, "agent-skill", "Agent skill")

      result = Skills.Loader.load(workspace: workspace, user_home: Path.join(@tmp_base, "home"))

      assert length(result.skills) >= 1
      names = Enum.map(result.skills, & &1.name)
      assert "agent-skill" in names
    end

    test "loads global skills from ~/.handbean/skills and ~/.agents/skills" do
      workspace = Path.join(@tmp_base, "ws-global")
      home = Path.join(@tmp_base, "home-global")

      sigil_skill_dir = Path.join(home, ".handbean/skills/global-sigil")
      agents_skill_dir = Path.join(home, ".agents/skills/global-agents")

      write_skill(sigil_skill_dir, "global-sigil", "Global Handbean skill")
      write_skill(agents_skill_dir, "global-agents", "Global Agents skill")

      result = Skills.Loader.load(workspace: workspace, user_home: home)

      names = Enum.map(result.skills, & &1.name)
      assert "global-sigil" in names
      assert "global-agents" in names
      assert Enum.find(result.skills, &(&1.name == "global-sigil")).source == :user
      assert Enum.find(result.skills, &(&1.name == "global-agents")).source == :user
    end

    test "project skill wins over global skill with same name" do
      workspace = Path.join(@tmp_base, "ws-project-wins")
      home = Path.join(@tmp_base, "home-project-wins")

      write_skill(
        Path.join(workspace, ".handbean/skills/shared-skill"),
        "shared-skill",
        "Project description"
      )

      write_skill(
        Path.join(home, ".handbean/skills/shared-skill"),
        "shared-skill",
        "Global description"
      )

      result = Skills.Loader.load(workspace: workspace, user_home: home)

      skill = Enum.find(result.skills, &(&1.name == "shared-skill"))
      assert skill.description == "Project description"
      assert skill.source == :project

      assert Enum.any?(
               result.diagnostics,
               &(&1.type == :collision and &1.winner_path == skill.location)
             )
    end
  end

  # ── Loader does not read skill body into prompt ──

  describe "no body content in skill struct" do
    test "skill struct has no body/content field" do
      dir = Path.join(@tmp_base, "no-body")
      write_skill(dir, "no-body", "Description", ["disable-model-invocation: true"])

      result = Skills.Loader.load_from_dir(dir, :explicit)

      skill = hd(result.skills)
      refute Map.has_key?(Map.from_struct(skill), :body)
      refute Map.has_key?(Map.from_struct(skill), :content)
      refute Map.has_key?(Map.from_struct(skill), :instructions)
    end
  end
end
