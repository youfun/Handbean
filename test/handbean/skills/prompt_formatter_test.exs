defmodule Handbean.Skills.PromptFormatterTest do
  @moduledoc """
  Tests for the Skills Prompt Formatter.

  Covers:
    - Format available skills as XML per Agent Skills standard
    - Skills with disable_model_invocation: true excluded
    - XML escape (& < > " ')
    - Relative path instruction present in output
    - Empty skills list returns empty string
    - Does not read SKILL.md body
  """

  use ExUnit.Case, async: true

  alias Handbean.Skills.{Skill, PromptFormatter}

  # ── Helpers ──

  defp build_skill(attrs \\ []) do
    defaults = [
      name: "test-skill",
      description: "A test skill",
      location: "/abs/path/test-skill/SKILL.md",
      base_dir: "/abs/path/test-skill",
      source: :user,
      disable_model_invocation: false,
      metadata: %{}
    ]

    struct!(Skill, Keyword.merge(defaults, attrs))
  end

  # ── Basic formatting ──

  describe "format_available_skills/1" do
    test "formats single skill" do
      skill = build_skill()
      result = PromptFormatter.format_available_skills([skill])

      assert result =~ "The following skills provide specialized instructions"
      assert result =~ "Use the skill tool with the skill's name and optional arguments"
      refute result =~ "Use the read tool to load"
      assert result =~ "untrusted guidance"
      assert result =~ "<available_skills>"
      assert result =~ "<name>test-skill</name>"
      assert result =~ "<description>A test skill</description>"
      assert result =~ "<location>/abs/path/test-skill/SKILL.md</location>"
      assert result =~ "</available_skills>"
    end

    test "formats multiple skills" do
      skill1 =
        build_skill(name: "code-review", description: "Review code", location: "/abs/cr/SKILL.md")

      skill2 =
        build_skill(
          name: "data-analyzer",
          description: "Analyze data",
          location: "/abs/da/SKILL.md"
        )

      result = PromptFormatter.format_available_skills([skill1, skill2])

      assert result =~ "<name>code-review</name>"
      assert result =~ "<name>data-analyzer</name>"
      assert result =~ "<description>Review code</description>"
      assert result =~ "<description>Analyze data</description>"
    end

    test "returns empty string for empty skills list" do
      assert PromptFormatter.format_available_skills([]) == ""
    end

    test "does not include SKILL.md body content" do
      skill = build_skill()
      result = PromptFormatter.format_available_skills([skill])

      refute result =~ "# Code Review"
      refute result =~ "This is the body content"
    end
  end

  # ── disable_model_invocation filtering ──

  describe "disable_model_invocation exclusion" do
    test "excludes skills with disable_model_invocation: true" do
      normal = build_skill(name: "normal", disable_model_invocation: false)
      disabled = build_skill(name: "disabled", disable_model_invocation: true)

      result = PromptFormatter.format_available_skills([normal, disabled])

      assert result =~ "normal"
      refute result =~ "disabled"
    end

    test "returns empty string when all skills are disabled" do
      skill = build_skill(disable_model_invocation: true)
      result = PromptFormatter.format_available_skills([skill])

      assert result == ""
    end
  end

  # ── XML escaping ──

  describe "XML escape" do
    test "escapes & character" do
      skill =
        build_skill(
          name: "security--amp",
          description: "Security & auth",
          location: "/abs/a--b/SKILL.md"
        )

      result = PromptFormatter.format_available_skills([skill])

      assert result =~ "&amp;"
      refute result =~ " & "
    end

    test "escapes < character" do
      skill =
        build_skill(name: "less-than", description: "Check x < y", location: "/abs/lt/SKILL.md")

      result = PromptFormatter.format_available_skills([skill])

      assert result =~ "&lt;"
      refute result =~ " < "
    end

    test "escapes > character" do
      skill =
        build_skill(name: "greater", description: "Compare x > y", location: "/abs/gt/SKILL.md")

      result = PromptFormatter.format_available_skills([skill])

      assert result =~ "&gt;"
      refute result =~ " x > "
    end

    test "escapes double quote" do
      skill =
        build_skill(
          name: "quote",
          description: ~s(Use "strict" mode),
          location: "/abs/q/SKILL.md"
        )

      result = PromptFormatter.format_available_skills([skill])

      assert result =~ "&quot;"
      refute result =~ "\"strict\""
    end

    test "escapes single quote" do
      skill =
        build_skill(name: "squote", description: "Don't panic", location: "/abs/sq/SKILL.md")

      result = PromptFormatter.format_available_skills([skill])

      assert result =~ "&apos;"
      refute result =~ "Don't panic"
    end

    test "combination of escapable characters handled" do
      skill =
        build_skill(
          name: "combo",
          description: ~s(Use "file" <pattern> & config's 'key'),
          location: "/abs/combo/SKILL.md"
        )

      result = PromptFormatter.format_available_skills([skill])

      assert result =~ "&quot;file&quot;"
      assert result =~ "&lt;pattern&gt;"
      assert result =~ "&amp;"
      assert result =~ "&apos;key&apos;"
    end
  end

  # ── Relative path instruction ──

  describe "relative path instruction" do
    test "explains resource base directory without expanding read permissions" do
      skill = build_skill()
      result = PromptFormatter.format_available_skills([skill])

      assert result =~ "References are relative to the returned resource base directory"
      assert result =~ "loads the body only"
      assert result =~ "read remains workspace-only"
      assert result =~ "cannot access global skill resources outside the workspace"
    end
  end
end
