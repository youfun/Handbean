defmodule Handbean.Log.RedactorTest do
  @moduledoc """
  Tests for Handbean.Log.Redactor — recursive sensitive data redaction.
  """
  use ExUnit.Case, async: true

  alias Handbean.Log.Redactor

  describe "redact/1 — sensitive keys in maps" do
    test "redacts known sensitive keys" do
      sensitive_keys = [
        "api_key",
        "apikey",
        "token",
        "authorization",
        "cookie",
        "secret",
        "password",
        "pass",
        "OPENAI_API_KEY"
      ]

      for key <- sensitive_keys do
        input = %{key => "my-super-secret-value-12345"}
        result = Redactor.redact(input)
        assert result[key] == "[REDACTED]", "expected key '#{key}' to be redacted"
      end
    end

    test "redacts sensitive keys case-insensitively" do
      input = %{"API_KEY" => "secret123"}
      result = Redactor.redact(input)
      assert result["API_KEY"] == "[REDACTED]"
    end

    test "leaves non-sensitive keys intact" do
      input = %{"name" => "Alice", "age" => 30, "model" => "claude"}
      result = Redactor.redact(input)
      assert result == %{"name" => "Alice", "age" => 30, "model" => "claude"}
    end

    test "handles string keys" do
      input = %{"api_key" => "secret"}
      result = Redactor.redact(input)
      assert result["api_key"] == "[REDACTED]"
    end

    test "handles atom keys" do
      input = %{api_key: "secret"}
      result = Redactor.redact(input)
      assert result[:api_key] == "[REDACTED]"
    end
  end

  describe "redact/1 — bearer token strings" do
    test "redacts bearer token in flat string" do
      result = Redactor.redact("Bearer sk-abc123secret456")
      assert result == "Bearer [REDACTED]"
    end

    test "redacts bearer token case-insensitively" do
      result = Redactor.redact("bearer SK-TOKEN-VALUE")
      assert result == "bearer [REDACTED]"
    end

    test "redacts bearer token inside map values" do
      input = %{"authorization" => "Bearer token-value-here"}
      result = Redactor.redact(input)
      # authorization is also a sensitive key, so gets redacted at key level
      assert result["authorization"] == "[REDACTED]"
    end

    test "redacts bearer token in non-sensitive key values" do
      input = %{"header" => "Bearer my-token-123"}
      result = Redactor.redact(input)
      assert result["header"] == "Bearer [REDACTED]"
    end
  end

  describe "redact/1 — credential strings" do
    test "redacts assignments in plain and JSON-like text" do
      input =
        ~s(request api_key=sk-live-value-1234567890 password: hunter2 {"auth_token":"token-value"})

      result = Redactor.redact(input)

      refute result =~ "sk-live-value"
      refute result =~ "hunter2"
      refute result =~ "token-value"
      assert result =~ "api_key=[REDACTED]"
      assert result =~ "password: [REDACTED]"
      assert result =~ ~s("auth_token":[REDACTED])
    end

    test "redacts authorization, cookie, and standalone credential token shapes" do
      input =
        "Authorization: Basic dXNlcjpwYXNz Cookie: session=abc; csrf=def " <>
          "AKIA1234567890ABCDEF sk-abcdefghijklmnopqrstuvwxyz"

      result = Redactor.redact(input)

      refute result =~ "dXNlcjpwYXNz"
      refute result =~ "session=abc"
      refute result =~ "AKIA1234567890ABCDEF"
      refute result =~ "sk-abcdefghijklmnopqrstuvwxyz"
      assert result =~ "Authorization: [REDACTED]"
      assert result =~ "Cookie: [REDACTED]"
    end
  end

  describe "redact/1 — nested data structures" do
    test "recursively redacts nested maps" do
      input = %{
        "config" => %{
          "api_key" => "nested-secret",
          "name" => "my-config"
        }
      }

      result = Redactor.redact(input)

      assert result["config"]["api_key"] == "[REDACTED]"
      assert result["config"]["name"] == "my-config"
    end

    test "recursively redacts within lists of maps" do
      input = [
        %{"name" => "entry1", "token" => "t1"},
        %{"name" => "entry2", "token" => "t2"}
      ]

      result = Redactor.redact(input)

      assert Enum.at(result, 0)["token"] == "[REDACTED]"
      assert Enum.at(result, 1)["token"] == "[REDACTED]"
      assert Enum.at(result, 0)["name"] == "entry1"
      assert Enum.at(result, 1)["name"] == "entry2"
    end

    test "recursively redacts deeply nested structures" do
      input = %{
        "level1" => %{
          "level2" => [
            %{"level3" => %{"password" => "deep-secret", "data" => "ok"}}
          ]
        }
      }

      result = Redactor.redact(input)
      deep = result["level1"]["level2"] |> Enum.at(0) |> Map.get("level3")
      assert deep["password"] == "[REDACTED]"
      assert deep["data"] == "ok"
    end
  end

  describe "redact/1 — edge cases" do
    test "handles empty map" do
      assert Redactor.redact(%{}) == %{}
    end

    test "handles empty list" do
      assert Redactor.redact([]) == []
    end

    test "handles plain string without secrets" do
      assert Redactor.redact("hello world") == "hello world"
    end

    test "handles nil" do
      assert Redactor.redact(nil) == nil
    end

    test "handles numbers" do
      assert Redactor.redact(42) == 42
    end

    test "handles atoms" do
      assert Redactor.redact(:ok) == :ok
    end

    test "does not crash on arbitrary terms" do
      assert Redactor.redact({:tuple, %{"api_key" => "x"}}) ==
               {:tuple, %{"api_key" => "[REDACTED]"}}
    end
  end

  describe "redact/1 — metadata submap usage" do
    test "redacts sensitive keys inside metadata" do
      input = %{
        "kind" => "provider",
        "metadata" => %{
          "request" => %{
            "headers" => %{
              "Authorization" => "Bearer secret-token",
              "Content-Type" => "application/json"
            }
          }
        }
      }

      result = Redactor.redact(input)
      assert result["metadata"]["request"]["headers"]["Authorization"] == "[REDACTED]"
      assert result["metadata"]["request"]["headers"]["Content-Type"] == "application/json"
    end
  end
end
