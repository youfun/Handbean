defmodule Handbean.Browser.RedactorTest do
  @moduledoc """
  Tests for browser argv and result redaction.

  Cookie, header, password, and proxy values must not reach transcript
  or model-facing details.
  """

  use ExUnit.Case, async: true

  alias Handbean.Browser.Redactor

  describe "redact_args/1" do
    test "masks values of sensitive flags" do
      args = [
        "open",
        "https://example.com",
        "--headers",
        "Authorization: Bearer secret-token",
        "--proxy",
        "http://user:pass@proxy.local",
        "--password",
        "hunter2"
      ]

      redacted = Redactor.redact_args(args)

      assert redacted == [
               "open",
               "https://example.com",
               "--headers",
               "[REDACTED]",
               "--proxy",
               "[REDACTED]",
               "--password",
               "[REDACTED]"
             ]
    end

    test "masks cookies set and storage set trailing values" do
      assert Redactor.redact_args(["cookies", "set", "sid", "abc123"]) ==
               ["cookies", "set", "sid", "[REDACTED]"]

      assert Redactor.redact_args(["storage", "local", "set", "token", "xyz"]) ==
               ["storage", "local", "set", "token", "[REDACTED]"]
    end

    test "leaves ordinary navigation args intact" do
      args = ["open", "https://example.com", "--headed"]
      assert Redactor.redact_args(args) == args
    end
  end

  describe "redact_data/1" do
    test "redacts cookie and password fields in structured data" do
      data = %{"cookie" => "sid=abc", "url" => "https://example.com", "password" => "x"}

      assert Redactor.redact_data(data) == %{
               "cookie" => "[REDACTED]",
               "url" => "https://example.com",
               "password" => "[REDACTED]"
             }
    end
  end
end
