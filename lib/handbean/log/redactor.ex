defmodule Handbean.Log.Redactor do
  @moduledoc """
  Recursive sensitive-data redactor.

  Walks maps, lists, strings, and tuples, replacing values associated with
  sensitive keys (case-insensitive), credential assignments, common credential
  token shapes, and bearer-token strings with `"[REDACTED]"`.

  ## Covered sensitive keys

    * `api_key`, `apikey`, `token`, `authorization`, `cookie`,
      `secret`, `password`, `pass`, `OPENAI_API_KEY`

  These are matched **case-insensitively** (both string and atom keys).

  ## Bearer token strings

  Any string matching `~r/bearer\\s+\\S+/i` has the token portion replaced.

  ## Usage

      iex> Redactor.redact(%{"api_key" => "sk-abc"})
      %{"api_key" => "[REDACTED]"}
  """

  @sensitive_keys ~w(
    api_key apikey token authorization cookie
    secret password pass OPENAI_API_KEY
  )

  @sensitive_set MapSet.new(@sensitive_keys, &String.downcase/1)

  @bearer_regex ~r/(bearer)\s+\S+/i

  @authorization_assignment_regex ~r/((?:["']?)authorization(?:["']?)\s*[:=]\s*)(?:["'][^"'\r\n]*["']|(?:basic|bearer)\s+\S+|[^\s,;&}\]]+)/i
  @cookie_assignment_regex ~r/((?:["']?)cookie(?:["']?)\s*[:=]\s*)[^,\r\n}]+/i

  @sensitive_assignment_regex ~r/((?:["']?)(?:api[\s_-]?key|apikey|auth[\s_-]?token|access[\s_-]?token|refresh[\s_-]?token|token|secret|password|pass)(?:["']?)\s*[:=]\s*)(?:["'][^"'\r\n]*["']|[^\s,;&}\]]+)/i

  @credential_token_regex ~r/\b(?:AKIA[0-9A-Z]{16}|sk-[A-Za-z0-9_-]{20,})\b/

  @redacted "[REDACTED]"

  @doc """
  Recursively redact sensitive data from the given term.

  Returns a clean copy — the original is never mutated.
  """
  @spec redact(term()) :: term()
  def redact(%{__struct__: _} = struct) do
    struct
    |> Map.from_struct()
    |> redact()
  end

  def redact(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      {key, redact_value(key, value)}
    end)
  end

  def redact(list) when is_list(list) do
    Enum.map(list, &redact/1)
  end

  def redact(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&redact/1)
    |> List.to_tuple()
  end

  def redact(string) when is_binary(string) do
    redact_bearer(string)
  end

  def redact(other), do: other

  # ── Private helpers ──

  defp redact_value(key, value) when is_binary(value) do
    if sensitive_key?(key) do
      @redacted
    else
      redact_bearer(value)
    end
  end

  defp redact_value(key, value) do
    if sensitive_key?(key) do
      @redacted
    else
      redact(value)
    end
  end

  defp sensitive_key?(key) when is_binary(key),
    do: MapSet.member?(@sensitive_set, String.downcase(key))

  defp sensitive_key?(key) when is_atom(key),
    do: key |> Atom.to_string() |> String.downcase() |> then(&MapSet.member?(@sensitive_set, &1))

  defp sensitive_key?(_), do: false

  defp redact_bearer(string) when is_binary(string) do
    string
    |> String.replace(@authorization_assignment_regex, "\\1#{@redacted}")
    |> String.replace(@cookie_assignment_regex, "\\1#{@redacted}")
    |> String.replace(@sensitive_assignment_regex, "\\1#{@redacted}")
    |> String.replace(@bearer_regex, "\\1 #{@redacted}")
    |> String.replace(@credential_token_regex, @redacted)
  end
end
