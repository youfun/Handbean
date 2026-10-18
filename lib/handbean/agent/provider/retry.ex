defmodule Handbean.Agent.Provider.Retry do
  @moduledoc """
  Retry classification and exponential backoff logic for HTTP providers.

  Pure functions — no Process.sleep, no side effects.
  The caller is responsible for sleeping and re-issuing the request.

  ## Usage

      config = %{max_retries: 3, retry_delay_base_ms: 500}
      if Retry.should_retry?(429, attempt, config) do
        Process.sleep(Retry.next_delay_ms(attempt, config))
        # ... retry request ...
      end
  """

  @retryable_statuses [429, 500, 502, 503, 504, 520, 524]
  @default_max_retries 3
  @default_retry_delay_base_ms 500

  # ── Retry classification ──────────────────────────────────────────────

  @doc """
  Check whether an error reason string is retryable.

  Handles HTTP status errors, Anthropic rate_limit/overloaded errors,
  OpenAI server errors, Gemini errors, and network failures (econnrefused,
  closed, timeout, unprocessed).

  Returns `true` if the error is transient and worth retrying.
  """
  @spec retryable?(term()) :: boolean()

  def retryable?("HTTP 408:" <> _), do: true
  def retryable?("HTTP 429:" <> _), do: true
  def retryable?("HTTP 500:" <> _), do: true
  def retryable?("HTTP 502:" <> _), do: true
  def retryable?("HTTP 503:" <> _), do: true
  def retryable?("HTTP 504:" <> _), do: true
  def retryable?("HTTP 520:" <> _), do: true
  def retryable?("HTTP 524:" <> _), do: true

  def retryable?("rate_limit_error:" <> _), do: true
  def retryable?("rate_limit_exceeded:" <> _), do: true
  def retryable?("overloaded_error:" <> _), do: true
  def retryable?("server_error:" <> _), do: true

  def retryable?("RESOURCE_EXHAUSTED:" <> _), do: true
  def retryable?("INTERNAL:" <> _), do: true
  def retryable?("UNAVAILABLE:" <> _), do: true

  def retryable?("HTTP request failed: " <> rest) do
    String.contains?(rest, "econnrefused") or
      String.contains?(rest, "closed") or
      String.contains?(rest, "timeout") or
      String.contains?(rest, "unprocessed")
  end

  def retryable?(:timeout), do: true

  def retryable?(%{status: status}) when is_integer(status), do: retryable_status?(status)

  def retryable?(%{reason: reason}) when is_binary(reason), do: retryable?(reason)

  def retryable?(_), do: false

  @doc """
  Check whether a given HTTP status code is retryable.

  Returns `true` for 429 (rate limit) and 5xx (server errors).
  Returns `false` for 4xx (client errors, excluding 429) and 2xx.
  """
  @spec retryable_status?(non_neg_integer()) :: boolean()
  def retryable_status?(status) when status in @retryable_statuses, do: true
  def retryable_status?(_status), do: false

  @doc """
  Check whether to retry given the status, current attempt, and config.

  Returns `{:retry, delay_ms}` if retry is recommended, or `:exhausted`.
  """
  @spec should_retry?(non_neg_integer(), non_neg_integer(), map()) ::
          {:retry, pos_integer()} | :exhausted
  def should_retry?(status, attempt, config \\ %{})

  def should_retry?(status, attempt, config) do
    max_value = Map.get(config, :max_retries, @default_max_retries)

    cond do
      attempt >= max_value ->
        :exhausted

      retryable_status?(status) ->
        delay = next_delay_ms(attempt, config)
        {:retry, delay}

      true ->
        :exhausted
    end
  end

  @doc """
  Check whether to retry a provider error reason.

  This is used by the agent turn loop, where providers normalize transport
  failures and provider errors into `{:error, reason}`.
  """
  @spec should_retry_error?(term(), non_neg_integer(), map()) ::
          {:retry, pos_integer()} | :exhausted
  def should_retry_error?(reason, attempt, config \\ %{}) do
    max_value = Map.get(config, :max_retries, @default_max_retries)

    cond do
      attempt >= max_value ->
        :exhausted

      retryable?(reason) ->
        delay = next_delay_ms(attempt, config)
        {:retry, delay}

      true ->
        :exhausted
    end
  end

  # ── Exponential backoff ─────────────────────────────────────────────

  @doc """
  Calculate the delay in milliseconds for a given attempt number (0-based).

  Uses exponential backoff with base delay (default 500ms):
    attempt=0 → base
    attempt=1 → base * 2
    attempt=2 → base * 4
    ...
    Capped at 30 seconds.
  """
  @spec next_delay_ms(non_neg_integer(), map()) :: pos_integer()
  def next_delay_ms(attempt, config \\ %{}) do
    base = Map.get(config, :retry_delay_base_ms, @default_retry_delay_base_ms)
    delay = trunc(base * :math.pow(2, attempt))
    cap = Map.get(config, :retry_delay_cap_ms, 30_000)
    jitter = Map.get(config, :jitter_ms, 0)
    min(delay + jitter, cap)
  end

  @doc """
  Delay that honors a server Retry-After when it is longer than the backoff cap.

  `retry_after_ms` is milliseconds already parsed from seconds or an HTTP date.
  The wait never exceeds the remaining run budget. A cap must not retry earlier
  than the server asked.
  """
  @spec delay_ms(non_neg_integer(), map(), keyword()) :: pos_integer() | :budget_exceeded
  def delay_ms(attempt, config \\ %{}, opts \\ []) do
    requested = max(next_delay_ms(attempt, config), Keyword.get(opts, :retry_after_ms, 0))
    remaining = Keyword.get(opts, :remaining_ms)

    cond do
      is_integer(remaining) and requested > remaining -> :budget_exceeded
      true -> requested
    end
  end

  def parse_retry_after(value) when is_integer(value), do: value * 1_000

  def parse_retry_after(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} ->
        seconds * 1_000

      _ ->
        case :httpd_util.convert_request_date(String.to_charlist(value)) do
          {{_, _, _}, {_, _, _}} = date ->
            seconds =
              :calendar.datetime_to_gregorian_seconds(date) -
                :calendar.datetime_to_gregorian_seconds(:calendar.universal_time())

            max(seconds, 0) * 1_000

          _ ->
            0
        end
    end
  end

  @doc """
  Calculate all delay values for a config.

  Returns a list of `{attempt, delay_ms}` tuples up to max_retries.
  Useful for testing and debugging.
  """
  @spec delay_sequence(map()) :: [{non_neg_integer(), pos_integer()}]
  def delay_sequence(config \\ %{}) do
    max_value = Map.get(config, :max_retries, @default_max_retries)

    0..(max_value - 1)
    |> Enum.map(fn attempt -> {attempt, next_delay_ms(attempt, config)} end)
  end

  @doc """
  Return the list of retryable HTTP status codes.
  """
  @spec retryable_statuses() :: [non_neg_integer()]
  def retryable_statuses, do: @retryable_statuses
end
