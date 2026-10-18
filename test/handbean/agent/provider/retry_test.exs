defmodule Handbean.Agent.Provider.RetryTest do
  use ExUnit.Case, async: true

  alias Handbean.Agent.Provider.Retry

  describe "retryable?/1" do
    # HTTP status errors
    test "408 request timeout is retryable" do
      assert Retry.retryable?("HTTP 408: Request Timeout")
    end

    test "429 rate limit is retryable" do
      assert Retry.retryable?("HTTP 429: Too Many Requests")
    end

    test "500 server error is retryable" do
      assert Retry.retryable?("HTTP 500: Internal Server Error")
    end

    test "502 bad gateway is retryable" do
      assert Retry.retryable?("HTTP 502: Bad Gateway")
    end

    test "503 service unavailable is retryable" do
      assert Retry.retryable?("HTTP 503: Service Unavailable")
    end

    test "504 gateway timeout is retryable" do
      assert Retry.retryable?("HTTP 504: Gateway Timeout")
    end

    test "Cloudflare 520 and 524 gateway failures are retryable" do
      assert Retry.retryable?("HTTP 520: Unknown Error")
      assert Retry.retryable?("HTTP 524: A Timeout Occurred")
    end

    test "400 bad request is not retryable" do
      refute Retry.retryable?("HTTP 400: Bad Request")
    end

    test "401 unauthorized is not retryable" do
      refute Retry.retryable?("HTTP 401: Unauthorized")
    end

    # Provider-specific error formats
    test "Anthropic rate_limit_error is retryable" do
      assert Retry.retryable?("rate_limit_error: rate limited")
    end

    test "OpenAI rate_limit_exceeded is retryable" do
      assert Retry.retryable?("rate_limit_exceeded: quota exceeded")
    end

    test "Anthropic overloaded_error is retryable" do
      assert Retry.retryable?("overloaded_error: model overloaded")
    end

    test "OpenAI server_error is retryable" do
      assert Retry.retryable?("server_error: internal error")
    end

    # Google Gemini errors
    test "Gemini RESOURCE_EXHAUSTED is retryable" do
      assert Retry.retryable?("RESOURCE_EXHAUSTED: quota exceeded")
    end

    test "Gemini INTERNAL is retryable" do
      assert Retry.retryable?("INTERNAL: server error")
    end

    test "Gemini UNAVAILABLE is retryable" do
      assert Retry.retryable?("UNAVAILABLE: service down")
    end

    # Network failures
    test "econnrefused is retryable" do
      assert Retry.retryable?("HTTP request failed: econnrefused")
    end

    test "connection closed is retryable" do
      assert Retry.retryable?("HTTP request failed: closed")
    end

    test "timeout in HTTP request is retryable" do
      assert Retry.retryable?("HTTP request failed: timeout")
    end

    test "unprocessed in HTTP request is retryable" do
      assert Retry.retryable?("HTTP request failed: unprocessed")
    end

    test "atom :timeout is retryable" do
      assert Retry.retryable?(:timeout)
    end

    # Non-retryable
    test "unknown string error is not retryable" do
      refute Retry.retryable?("unknown error")
    end

    test "atom :badarg is not retryable" do
      refute Retry.retryable?(:badarg)
    end

    test "nil is not retryable" do
      refute Retry.retryable?(nil)
    end
  end

  describe "retryable_status?/1" do
    test "429 is retryable" do
      assert Retry.retryable_status?(429)
    end

    test "500 is retryable" do
      assert Retry.retryable_status?(500)
    end

    test "502 is retryable" do
      assert Retry.retryable_status?(502)
    end

    test "503 is retryable" do
      assert Retry.retryable_status?(503)
    end

    test "504 is retryable" do
      assert Retry.retryable_status?(504)
    end

    test "Cloudflare 520 and 524 are retryable" do
      assert Retry.retryable_status?(520)
      assert Retry.retryable_status?(524)
    end

    test "200 is not retryable" do
      refute Retry.retryable_status?(200)
    end

    test "400 is not retryable" do
      refute Retry.retryable_status?(400)
    end

    test "401 is not retryable" do
      refute Retry.retryable_status?(401)
    end

    test "403 is not retryable" do
      refute Retry.retryable_status?(403)
    end
  end

  describe "should_retry?/3" do
    test "returns :exhausted when max_retries reached" do
      assert Retry.should_retry?(500, 3, %{max_retries: 3}) == :exhausted
    end

    test "returns {:retry, delay} for retryable status below max" do
      assert {:retry, delay} = Retry.should_retry?(500, 0, %{max_retries: 3})
      assert delay == 500
    end

    test "returns :exhausted for non-retryable status" do
      assert Retry.should_retry?(400, 0) == :exhausted
    end
  end

  describe "next_delay_ms/2" do
    test "base delay for attempt 0" do
      assert Retry.next_delay_ms(0) == 500
    end

    test "doubles each attempt" do
      assert Retry.next_delay_ms(0) == 500
      assert Retry.next_delay_ms(1) == 1000
      assert Retry.next_delay_ms(2) == 2000
    end

    test "respects custom base delay" do
      assert Retry.next_delay_ms(1, %{retry_delay_base_ms: 100}) == 200
    end

    test "caps at 30 seconds" do
      assert Retry.next_delay_ms(20) == 30_000
    end
  end

  describe "delay_sequence/1" do
    test "returns sequence of delays up to max_retries" do
      seq = Retry.delay_sequence(%{max_retries: 3, retry_delay_base_ms: 100})

      assert seq == [{0, 100}, {1, 200}, {2, 400}]
    end
  end
end
