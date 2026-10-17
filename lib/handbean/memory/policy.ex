defmodule Handbean.Memory.Policy do
  @moduledoc """
  Memory policy — controls memory tool usage strategy and candidate content validation.

  Defines which profile governs memory behavior:
    - `:minimal`  — recall/learn only, short prompt
    - `:balanced` — full four-tool workflow (default)
    - `:strict`   — emphasizes security, forbids auto-saving sensitive info

  Also provides `validate_candidate_memory/1` for lightweight pre-store rejection
  of empty content, suspected secrets, transient noise, and obvious facts.
  """

  @type t :: %__MODULE__{
          profile: :minimal | :balanced | :strict
        }

  @valid_profiles [:minimal, :balanced, :strict]

  defstruct profile: :balanced

  @doc """
  Creates a new Policy struct from keyword options.

  ## Options
    - `:profile` — `:minimal`, `:balanced` (default), or `:strict`

  ## Examples

      iex> {:ok, policy} = Policy.new(profile: :balanced)
      iex> policy.profile
      :balanced

      iex> {:error, reason} = Policy.new(profile: :nonexistent)
      iex> reason =~ "Invalid profile"
      true
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, String.t()}
  def new(opts \\ []) do
    profile = Keyword.get(opts, :profile, :balanced)

    if profile in @valid_profiles do
      {:ok, %__MODULE__{profile: profile}}
    else
      {:error,
       "Invalid profile: #{inspect(profile)}. Valid profiles: #{inspect(@valid_profiles)}"}
    end
  end

  @doc """
  Validates whether candidate content is suitable for memory storage.

  Performs lightweight local checks. Does NOT inspect the DB or call external services.

  Returns `{:ok, content}` if the content passes all checks,
  or `{:error, reason}` with a human-readable rejection reason.

  ## Rejection rules

    1. Empty or nil content
    2. Content too short (< minimum meaningful length)
    3. Content matching secret/credential patterns (api_key, token, password, bearer, secret, credential)
    4. Pure path noise (looks like a bare file path with no context)
    5. Transient command output / log-line noise

  ## Examples

      iex> Policy.validate_candidate_memory("User prefers snake_case naming for Elixir")
      {:ok, "User prefers snake_case naming for Elixir"}

      iex> Policy.validate_candidate_memory("")
      {:error, "Candidate memory is empty"}

      iex> Policy.validate_candidate_memory("api_key = sk-abc123")
      {:error, "Candidate memory contains sensitive data"}
  """
  @spec validate_candidate_memory(String.t() | nil) :: {:ok, String.t()} | {:error, String.t()}
  def validate_candidate_memory(nil), do: {:error, "Candidate memory is empty"}
  def validate_candidate_memory(""), do: {:error, "Candidate memory is empty"}

  def validate_candidate_memory(content) when is_binary(content) do
    trimmed = String.trim(content)

    cond do
      trimmed == "" ->
        {:error, "Candidate memory is empty"}

      too_short?(trimmed) and durable_cjk_memory?(trimmed) ->
        {:ok, trimmed}

      too_short?(trimmed) ->
        {:error, "Candidate memory is too short (minimum 10 characters)"}

      contains_sensitive_pattern?(trimmed) ->
        {:error, "Candidate memory contains sensitive data"}

      looks_like_noise?(trimmed) ->
        {:error, "Candidate memory appears to be transient noise"}

      true ->
        {:ok, trimmed}
    end
  end

  defp too_short?(content), do: String.length(content) < 10

  defp durable_cjk_memory?(content) do
    Regex.match?(~r/\p{Han}/u, content) and
      Regex.match?(~r/(用户|我|本人).*(喜欢|偏好|不喜欢|讨厌|倾向|习惯|常用|希望)/u, content)
  end

  # ── Private: sensitive pattern detection ──────────────────────────────

  @secret_patterns [
    ~r/api[\s_-]?key/i,
    ~r/auth[\s_-]?token/i,
    ~r/bearer\s+/i,
    ~r/password/i,
    ~r/secret[\s_-]*(key|token|value)?/i,
    ~r/credential/i,
    ~r/AKIA[0-9A-Z]{16}/,
    ~r/sk-[a-zA-Z0-9_-]{20,}/
  ]

  defp contains_sensitive_pattern?(content) do
    Enum.any?(@secret_patterns, &Regex.match?(&1, content))
  end

  # ── Private: noise detection ──────────────────────────────────────────

  @noise_patterns [
    # Bare file paths (starts with / and has extension, no sentence structure)
    ~r/^(\/[^\s]+\/)+[^\s]+\.[a-z]{1,6}$/,
    # Log lines: timestamp + level + message
    ~r/^\[(info|error|warn|debug|trace)\]\s/i,
    # Typical command output: starts with "total" (ls -l), or is a directory listing
    ~r/^total\s+\d+/,
    # Pure file listing (multiple lines of drwx/rw-)
    ~r/^[d-][rwx-]{9}\s/,
    # Stack trace lines
    ~r/^\s+at\s+.+:\d+:\d+$/,
    ~r/^\s+from\s+.+:\d+:\d+$/
  ]

  defp looks_like_noise?(content) do
    # Check single-line noise patterns
    first_line = content |> String.split("\n", trim: true) |> List.first("") |> String.trim()

    first_line != "" and Enum.any?(@noise_patterns, &Regex.match?(&1, first_line))
  end
end
