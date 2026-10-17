defmodule Handbean.Browser.Redactor do
  @moduledoc """
  Redacts sensitive browser argv values and structured result data.

  Flag values such as `--headers` / `--password` / `--proxy` and trailing
  values for `cookies set` / `storage … set` are replaced with
  `[REDACTED]` before they can enter transcript or logs.
  """

  alias Handbean.Log.Redactor, as: LogRedactor

  @sensitive_flags MapSet.new(["--headers", "--header", "--body", "--password", "--proxy"])

  @doc "Return a copy of argv with sensitive values masked."
  @spec redact_args([String.t()]) :: [String.t()]
  def redact_args(args) when is_list(args) do
    args
    |> mask_flag_values()
    |> mask_positional_set_value()
  end

  def redact_args(other), do: other

  @doc "Redact cookie/password-like fields in structured data."
  @spec redact_data(term()) :: term()
  def redact_data(data), do: LogRedactor.redact(data)

  defp mask_flag_values(args) do
    args
    |> Enum.reduce({[], false}, fn
      _arg, {acc, true} ->
        {["[REDACTED]" | acc], false}

      arg, {acc, false} ->
        cond do
          equals_sensitive_flag?(arg) ->
            {[mask_equals_flag(arg) | acc], false}

          MapSet.member?(@sensitive_flags, arg) ->
            {[arg | acc], true}

          true ->
            {[arg | acc], false}
        end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp equals_sensitive_flag?(arg) do
    Enum.any?(@sensitive_flags, &String.starts_with?(arg, &1 <> "="))
  end

  defp mask_equals_flag(arg) do
    case String.split(arg, "=", parts: 2) do
      [flag, _value] -> flag <> "=[REDACTED]"
      _ -> arg
    end
  end

  defp mask_positional_set_value(["cookies", "set" | rest]) when rest != [] do
    ["cookies", "set" | replace_last(rest)]
  end

  defp mask_positional_set_value(["storage", scope, "set" | rest])
       when scope in ["local", "session"] and rest != [] do
    ["storage", scope, "set" | replace_last(rest)]
  end

  defp mask_positional_set_value(args), do: args

  defp replace_last(list) do
    [_last | prefix] = Enum.reverse(list)
    Enum.reverse(["[REDACTED]" | prefix])
  end
end
