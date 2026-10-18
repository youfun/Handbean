defmodule ExFff.QueryTest do
  use ExUnit.Case, async: true

  alias ExFff.Query

  describe "parse/1" do
    test "parses empty string" do
      result = Query.parse("")
      assert result.terms == []
      assert result.include_patterns == []
      assert result.exclude_patterns == []
      assert result.limit == 0
    end

    test "parses single term" do
      result = Query.parse("schema")
      assert result.terms == ["schema"]
      assert result.include_patterns == []
      assert result.exclude_patterns == []
    end

    test "parses glob pattern (*.ex)" do
      result = Query.parse("*.ex")
      assert result.terms == []
      assert result.include_patterns == [".ex"]
      assert result.exclude_patterns == []
    end

    test "parses glob pattern (*.exs)" do
      result = Query.parse("*.exs")
      assert result.include_patterns == [".exs"]
    end

    test "parses a basename glob instead of a suffix filter" do
      result = Query.parse("*test")
      assert result.include_patterns == []
      assert result.terms == []
      assert [%{basename?: true, regex: regex}] = result.globs
      assert Regex.match?(regex, "user_test")
      refute Regex.match?(regex, "user_test.exs")
      refute Regex.match?(regex, "test/user.ex")
    end

    test "parses a contains-glob against the basename" do
      result = Query.parse("*schedules*")
      assert [%{basename?: true, regex: regex}] = result.globs
      assert Regex.match?(regex, "20260718000000_create_schedules.exs")
      refute Regex.match?(regex, "schedules/readme.md")
    end

    test "parses a path glob containing ** against the full path" do
      result = Query.parse("desktop/macos **/*Conversation*")
      assert result.terms == ["desktop/macos"]
      assert [%{basename?: false, regex: regex}] = result.globs
      assert Regex.match?(regex, "desktop/macos/ui/ConversationPanel.swift")
      refute Regex.match?(regex, "desktop/macos/Other.swift")
    end

    test "parses exclusion pattern" do
      result = Query.parse("!test/")
      assert result.terms == []
      assert result.include_patterns == []
      assert result.exclude_patterns == ["test/"]
    end

    test "parses exclusion pattern without slash" do
      result = Query.parse("!_build")
      assert result.exclude_patterns == ["_build"]
    end

    test "parses multi-term AND" do
      result = Query.parse("user controller")
      assert result.terms == ["user", "controller"]
    end

    test "parses mixed pattern" do
      result = Query.parse("user controller *.ex !test/")
      assert result.terms == ["user", "controller"]
      assert result.include_patterns == [".ex"]
      assert result.exclude_patterns == ["test/"]
    end

    test "parses trim whitespace" do
      result = Query.parse("  user   controller  ")
      assert result.terms == ["user", "controller"]
    end
  end
end
