defmodule HandbeanProbe.SettingsSupport do
  @moduledoc """
  UI-side parsing for the native settings forms.

  Persistence and catalog semantics live in `sigil`:
  `Handbean.Settings.ModelAIOverride`, `Handbean.Settings.ModelPolicy`,
  `Handbean.Settings.ModelRefs`, `Handbean.Settings.ModelCatalog`, and
  `Handbean.Agent.ModelConfig.read_config/0`.
  """

  @doc "Optional positive integer from a text field. Blank means `:omit`."
  @spec parse_optional_positive(String.t() | integer() | term()) ::
          {:ok, :omit | pos_integer()} | {:error, :invalid_positive}
  def parse_optional_positive(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, :omit}
      trimmed -> parse_int(trimmed, &(&1 > 0), :invalid_positive)
    end
  end

  def parse_optional_positive(n) when is_integer(n) and n > 0, do: {:ok, n}
  def parse_optional_positive(_), do: {:error, :invalid_positive}

  @doc "Optional non-negative integer from a text field. Blank means `:omit`."
  @spec parse_non_negative(String.t() | integer() | term()) ::
          {:ok, :omit | non_neg_integer()} | {:error, :invalid_non_negative}
  def parse_non_negative(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, :omit}
      trimmed -> parse_int(trimmed, &(&1 >= 0), :invalid_non_negative)
    end
  end

  def parse_non_negative(n) when is_integer(n) and n >= 0, do: {:ok, n}
  def parse_non_negative(_), do: {:error, :invalid_non_negative}

  defp parse_int(text, valid?, error) do
    case Integer.parse(text) do
      {n, ""} -> if valid?.(n), do: {:ok, n}, else: {:error, error}
      _ -> {:error, error}
    end
  end
end
