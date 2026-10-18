defmodule Handbean.Skills.ExpanderTest do
  @moduledoc """
  Tests for the Skills Expander.

  Covers:
  - /skill:name expands to <skill> XML block with body
  - /skill:name with args appends args after skill block
  - Plain text passes through unchanged
  - /skill: not at start of text passes through
  - Unknown skill passes through unchanged
  - SKILL.md read failure passes through with warning
  - Empty skill name does not match
  - /skill: alone does not match
  """

  use ExUnit.Case, async: true

  alias Handbean.Skills.{Skill, Expander}

  @tmp_base Path.join(
              System.tmp_dir!(),
              "sigil_expander_test_#{System.unique_integer([:positive])}"
            )

  setup do
    File.mkdir_p!(@tmp_base)

    on_exit(fn ->
      File.rm_rf!(@tmp_base)
    end)

    :ok
  end

  # ── Helpers ──

  defp write_skill_file(dir, name, description, body) do
    File.mkdir_p!(dir)
    path = Path.join(dir, "SKILL.md")

    File.write!(path, """
    ---
    name: #{name}
    description: #{description}
    ---

    #{body}
    """)

    path
  end

  defp build_skill(name, location, base_dir) do
    %Skill{
      name: name,
      description: "A #{name} skill",
      location: location,
      base_dir: base_dir,
      source: :explicit,
      disable_model_invocation: false,
      metadata: %{}
    }
  end

  # ── Basic expansion ──

  describe "expand/2 — basic cases" do
    test "expands /skill:name into <skill> XML block" do
      skill_dir = Path.join(@tmp_base, "review")
      skill_body = "# Code Review\n\nReview code for bugs and style issues."
      write_skill_file(skill_dir, "review", "Review code", skill_body)

      skill = build_skill("review", Path.join(skill_dir, "SKILL.md"), skill_dir)

      result = Expander.expand("/skill:review", [skill])

      assert result =~ ~r{<skill name="review"}
      assert result =~ ~r{References are relative to}
      assert result =~ "Code Review"
      assert result =~ "Review code for bugs and style issues."
      assert result =~ ~r{</skill>}
    end

    test "appends args after skill block" do
      skill_dir = Path.join(@tmp_base, "review")
      write_skill_file(skill_dir, "review", "Review code", "Body content.")

      skill = build_skill("review", Path.join(skill_dir, "SKILL.md"), skill_dir)

      result = Expander.expand("/skill:review fix all bugs", [skill])

      assert result =~ ~r{<skill name="review"}
      assert result =~ "Body content."
      assert result =~ "fix all bugs"
      # Ensure args are after the closing tag
      assert String.contains?(result, "</skill>\n\nfix all bugs")
    end

    test "plain text passes through unchanged" do
      text = "hello world, nothing special here"
      assert Expander.expand(text, []) == text
    end

    test "/skill: prefix only returns original text unchanged (no body in skill list)" do
      # With no matching skill, it passes through
      result = Expander.expand("/skill:unknown", [])
      assert result == "/skill:unknown"
    end
  end

  # ── No-match cases ──

  describe "expand/2 — no match cases" do
    test "text not starting with /skill: passes through" do
      text = "use the /skill:review skill"
      assert Expander.expand(text, []) == text
    end

    test "/skill: not followed by anything returns original" do
      # /skill: alone (no name after) — our parser returns :no_match for bare prefix
      result = Expander.expand("/skill:", [])
      assert result == "/skill:"
    end

    test "/skill: followed by space and then name returns original (empty name)" do
      # /skill:  name — first token after colon is empty string
      result = Expander.expand("/skill:  name", [])
      # "name" would be the first non-empty token after split
      # Actually "/skill:  name" -> rest = " name" -> split(" ", 2) -> ["", "name"] -> :no_match (empty first token)
      assert result == "/skill:  name"
    end
  end

  # ── Unknown skill ──

  describe "expand/2 — unknown skill" do
    test "unknown skill passes through unchanged" do
      skill = build_skill("review", "/some/path/SKILL.md", "/some/path")
      result = Expander.expand("/skill:nonexistent", [skill])
      assert result == "/skill:nonexistent"
    end

    test "unknown skill with args passes through unchanged" do
      skill = build_skill("review", "/some/path/SKILL.md", "/some/path")
      result = Expander.expand("/skill:nonexistent do something", [skill])
      assert result == "/skill:nonexistent do something"
    end
  end

  # ── File read failure ──

  describe "expand/2 — read failure" do
    test "missing SKILL.md passes through unchanged" do
      skill = %Skill{
        name: "missing",
        description: "A missing skill",
        location: Path.join(@tmp_base, "nonexistent") |> Path.join("SKILL.md"),
        base_dir: Path.join(@tmp_base, "nonexistent"),
        source: :explicit,
        disable_model_invocation: false,
        metadata: %{}
      }

      result = Expander.expand("/skill:missing", [skill])
      assert result == "/skill:missing"
    end
  end

  # ── Frontmatter stripping ──

  describe "expand/2 — frontmatter" do
    test "strips YAML frontmatter from SKILL.md" do
      skill_dir = Path.join(@tmp_base, "fm-skill")
      write_skill_file(skill_dir, "fm-skill", "Has frontmatter", "This is the body.")

      skill = build_skill("fm-skill", Path.join(skill_dir, "SKILL.md"), skill_dir)

      result = Expander.expand("/skill:fm-skill", [skill])

      assert result =~ "This is the body."
      refute result =~ "---"
      refute result =~ "name: fm-skill"
    end
  end

  # ── Empty args ──

  describe "expand/2 — args edge cases" do
    test "skill name with hyphen works" do
      skill_dir = Path.join(@tmp_base, "review-helper")
      write_skill_file(skill_dir, "review-helper", "Helper skill", "Body.")

      skill = build_skill("review-helper", Path.join(skill_dir, "SKILL.md"), skill_dir)

      result = Expander.expand("/skill:review-helper check PR #42", [skill])

      assert result =~ ~r{<skill name="review-helper"}
      assert result =~ "check PR #42"
    end
  end

  # ── parse_skill_command ──

  describe "parse_skill_command/1" do
    test "matches /skill:name" do
      assert Expander.parse_skill_command("/skill:review") == {:match, "review", ""}
    end

    test "matches /skill:name with args" do
      assert Expander.parse_skill_command("/skill:review fix bugs") ==
               {:match, "review", "fix bugs"}
    end

    test "does not match plain text" do
      assert Expander.parse_skill_command("hello world") == :no_match
    end

    test "does not match /skill: not at start" do
      assert Expander.parse_skill_command("use /skill:review") == :no_match
    end

    test "does not match bare /skill:" do
      assert Expander.parse_skill_command("/skill:") == :no_match
    end

    test "does not match empty string" do
      assert Expander.parse_skill_command("") == :no_match
    end
  end
end
