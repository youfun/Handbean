defmodule Handbean.Memory.PromptPolicyTest do
  @moduledoc """
  Tests for Handbean.Memory.PromptPolicy — system prompt section generation.

  Covers:
    - balanced profile prompt contains all four memory tool names
    - strict profile emphasizes security / forbids auto-saving sensitive info
    - minimal profile is shorter but still contains recall/learn basics
    - invalid profile returns error or fallback, behavior is fixed
    - generated prompt does NOT contain real secrets
  """

  use Handbean.DataCase

  alias Handbean.Memory.{Policy, PromptPolicy}

  describe "generate/1 — balanced profile" do
    test "contains all four memory tool names" do
      {:ok, policy} = Policy.new(profile: :balanced)
      prompt = PromptPolicy.generate(policy)

      assert prompt =~ "mem_recall"
      assert prompt =~ "mem_learn"
      assert prompt =~ "mem_reinforce"
      assert prompt =~ "mem_associate"
    end

    test "includes guidance on when to recall" do
      {:ok, policy} = Policy.new(profile: :balanced)
      prompt = PromptPolicy.generate(policy)

      assert prompt =~ "recall"
    end

    test "includes guidance on when to learn" do
      {:ok, policy} = Policy.new(profile: :balanced)
      prompt = PromptPolicy.generate(policy)

      assert prompt =~ "learn"
    end

    test "mentions short-term vs long-term distinction" do
      {:ok, policy} = Policy.new(profile: :balanced)
      prompt = PromptPolicy.generate(policy)

      assert prompt =~ "short-term" or prompt =~ "short term"
    end

    test "includes a workflow or deterministic usage instruction" do
      {:ok, policy} = Policy.new(profile: :balanced)
      prompt = PromptPolicy.generate(policy)

      # Should contain instruction-like text about memory workflow
      assert prompt =~ "should" or prompt =~ "use" or prompt =~ "call"
    end

    test "does not contain real secret patterns" do
      {:ok, policy} = Policy.new(profile: :balanced)
      prompt = PromptPolicy.generate(policy)

      # Must not contain any actual API keys or credentials
      refute prompt =~ ~r/api[_-]?key\s*[=:]\s*\w{10,}/
      refute prompt =~ ~r/Bearer\s+\w{10,}/
      refute prompt =~ ~r/password\s*[=:]\s*\w+/
      refute prompt =~ ~r/secret\s*[=:]\s*\w{5,}/
      refute prompt =~ ~r/AKIA[0-9A-Z]{16}/
    end
  end

  describe "generate/1 — strict profile" do
    test "emphasizes prohibition against auto-saving sensitive information" do
      {:ok, policy} = Policy.new(profile: :strict)
      prompt = PromptPolicy.generate(policy)

      # Should emphasize security concerns more strongly
      assert prompt =~ "never" or prompt =~ "do not" or prompt =~ "forbid"
    end

    test "still contains all four memory tool names" do
      {:ok, policy} = Policy.new(profile: :strict)
      prompt = PromptPolicy.generate(policy)

      assert prompt =~ "mem_recall"
      assert prompt =~ "mem_learn"
      assert prompt =~ "mem_reinforce"
      assert prompt =~ "mem_associate"
    end

    test "explicitly forbids storing secrets or credentials" do
      {:ok, policy} = Policy.new(profile: :strict)
      prompt = PromptPolicy.generate(policy)

      assert prompt =~ "secret" or prompt =~ "credential" or prompt =~ "PII" or
               prompt =~ "sensitive"
    end
  end

  describe "generate/1 — minimal profile" do
    test "is shorter than balanced prompt" do
      {:ok, balanced} = Policy.new(profile: :balanced)
      {:ok, minimal} = Policy.new(profile: :minimal)

      balanced_prompt = PromptPolicy.generate(balanced)
      minimal_prompt = PromptPolicy.generate(minimal)

      assert String.length(minimal_prompt) < String.length(balanced_prompt)
    end

    test "contains mem_recall and mem_learn" do
      {:ok, policy} = Policy.new(profile: :minimal)
      prompt = PromptPolicy.generate(policy)

      assert prompt =~ "mem_recall"
      assert prompt =~ "mem_learn"
    end

    test "is not empty" do
      {:ok, policy} = Policy.new(profile: :minimal)
      prompt = PromptPolicy.generate(policy)

      assert String.length(prompt) > 0
    end
  end

  describe "generate/1 — invalid profile fallback" do
    test "invalid profile struct raises or returns fallback" do
      # If someone constructs a policy with an invalid profile atom
      # bypassing new/1, the generate function should handle it gracefully

      # Create a struct directly with invalid profile
      invalid_policy = %Policy{profile: :nonexistent}

      # Should either raise (contract violation) or return a fallback prompt
      result =
        try do
          {:ok, PromptPolicy.generate(invalid_policy)}
        rescue
          _ -> :raised
        end

      # Both outcomes are acceptable — as long as behavior is fixed
      assert result == :raised or
               (is_binary(elem(result, 1)) and String.length(elem(result, 1)) > 0)
    end
  end

  describe "generate/1 — output structure" do
    test "generated prompt is a non-empty string" do
      {:ok, policy} = Policy.new(profile: :balanced)
      prompt = PromptPolicy.generate(policy)

      assert is_binary(prompt)
      assert String.length(prompt) > 50
    end

    test "each profile produces deterministic identical output" do
      {:ok, p1} = Policy.new(profile: :balanced)
      {:ok, p2} = Policy.new(profile: :balanced)

      assert PromptPolicy.generate(p1) == PromptPolicy.generate(p2)
    end
  end
end
