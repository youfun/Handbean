defmodule Handbean.Memory.PolicyTest do
  @moduledoc """
  Tests for Handbean.Memory.Policy — memory policy struct and candidate validation.

  Covers:
    - Policy creation with valid profiles (:minimal, :balanced, :strict)
    - Invalid profile returns error or falls back to :balanced
    - validate_candidate_memory/1 rejection logic:
      * empty/nil content
      * suspected secrets (api_key, token, password, bearer)
      * too short content
      * pure path noise
      * transient command output / log noise
    - Durable user preferences accepted
  """

  use Handbean.DataCase

  alias Handbean.Memory.Policy

  describe "new/1 — policy creation" do
    test "creates a policy with default :balanced profile" do
      {:ok, policy} = Policy.new([])
      assert policy.profile == :balanced
    end

    test "accepts :minimal profile" do
      {:ok, policy} = Policy.new(profile: :minimal)
      assert policy.profile == :minimal
    end

    test "accepts :balanced profile explicitly" do
      {:ok, policy} = Policy.new(profile: :balanced)
      assert policy.profile == :balanced
    end

    test "accepts :strict profile" do
      {:ok, policy} = Policy.new(profile: :strict)
      assert policy.profile == :strict
    end

    test "invalid profile returns error" do
      {:error, reason} = Policy.new(profile: :nonexistent)
      assert reason =~ "Invalid profile"
      assert reason =~ "minimal"
      assert reason =~ "balanced"
      assert reason =~ "strict"
    end

    test "invalid profile as string returns error" do
      {:error, reason} = Policy.new(profile: "minimal")
      assert reason =~ "Invalid profile"
    end

    test "atom profile matching string is accepted" do
      {:ok, policy} = Policy.new(profile: :balanced)
      assert %Policy{profile: :balanced} = policy
    end
  end

  describe "validate_candidate_memory/1 — content validation" do
    test "rejects empty string" do
      {:error, reason} = Policy.validate_candidate_memory("")
      assert reason =~ "empty"
    end

    test "rejects nil content" do
      {:error, reason} = Policy.validate_candidate_memory(nil)
      assert reason =~ "empty"
    end

    test "rejects content with api_key pattern" do
      {:error, reason} = Policy.validate_candidate_memory("my api_key is abc123")
      assert reason =~ "sensitive"
    end

    test "rejects content with token pattern" do
      {:error, reason} = Policy.validate_candidate_memory("auth token: xyz789")
      assert reason =~ "sensitive"
    end

    test "rejects content with password pattern" do
      {:error, reason} = Policy.validate_candidate_memory("database password is secret123")
      assert reason =~ "sensitive"
    end

    test "rejects content with bearer token" do
      {:error, reason} = Policy.validate_candidate_memory("Bearer eyJhbGciOiJIUzI1NiJ9.abc")
      assert reason =~ "sensitive"
    end

    test "rejects content with secret pattern" do
      {:error, reason} = Policy.validate_candidate_memory("the secret is 42")
      assert reason =~ "sensitive"
    end

    test "rejects content with credential pattern" do
      {:error, reason} = Policy.validate_candidate_memory("aws credentials: AKIA...")
      assert reason =~ "sensitive"
    end

    test "rejects content that is too short" do
      {:error, reason} = Policy.validate_candidate_memory("ok")
      assert reason =~ "short"
    end

    test "accepts concise CJK user preference" do
      assert {:ok, "用户喜欢吃粤菜。"} = Policy.validate_candidate_memory("用户喜欢吃粤菜。")
    end

    test "rejects short CJK text without preference or durable context" do
      {:error, reason} = Policy.validate_candidate_memory("天气不错。")
      assert reason =~ "short"
    end

    test "rejects single word without context" do
      {:error, reason} = Policy.validate_candidate_memory("Phoenix")
      assert reason =~ "short"
    end

    test "rejects pure file path noise" do
      {:error, reason} =
        Policy.validate_candidate_memory("/Users/example/project/lib/handbean/memory/engram.ex")

      assert reason =~ "noise"
    end

    test "rejects pure log line noise" do
      {:error, reason} =
        Policy.validate_candidate_memory("[info] GET /api/users 200 OK in 12ms")

      assert reason =~ "noise"
    end

    test "rejects stdout-only command output" do
      {:error, reason} =
        Policy.validate_candidate_memory(
          "total 24\ndrwxr-xr-x  5 user  staff  160 May 14 10:00 lib"
        )

      assert reason =~ "noise"
    end

    test "accepts a durable user preference" do
      {:ok, _} =
        Policy.validate_candidate_memory(
          "User prefers snake_case naming for Elixir modules and functions"
        )
    end

    test "accepts a design decision" do
      {:ok, _} =
        Policy.validate_candidate_memory(
          "The project uses SQLite3 via ecto_sqlite3 instead of PostgreSQL for zero-config local development"
        )
    end

    test "accepts a workflow rule" do
      {:ok, _} =
        Policy.validate_candidate_memory(
          "Before committing, always run mix format and mix test to ensure code quality"
        )
    end

    test "accepts a project convention" do
      {:ok, _} =
        Policy.validate_candidate_memory(
          "All LiveView modules live under HandbeanWeb and follow the naming pattern WorkspaceLive"
        )
    end

    test "accepts content mentioning token in a safe context" do
      # "token" used as a technical concept, not a secret
      {:ok, _} =
        Policy.validate_candidate_memory(
          "JWT token authentication is handled by the Guardian library in the auth pipeline"
        )
    end

    test "accepts content with min-length boundary" do
      {:ok, _} = Policy.validate_candidate_memory("User prefers spaces over tabs for indentation")
    end
  end
end
