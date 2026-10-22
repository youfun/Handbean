defmodule Handbean.Tool.Builtin.Grep.ByteBudget do
  @moduledoc false

  @max_line_bytes 2_000
  @max_page_bytes 48_000

  @spec max_line_bytes() :: pos_integer()
  def max_line_bytes, do: @max_line_bytes

  @spec bound_hit(map()) :: map()
  def bound_hit(hit), do: %{hit | text: safe_text(hit.text || "")}

  @spec line_text(term()) :: String.t()
  def line_text(line) when is_binary(line) do
    binary_part(line, 0, min(byte_size(line), @max_line_bytes))
  end

  def line_text(_line), do: ""

  @spec safe_text(String.t()) :: String.t()
  def safe_text(text) do
    text
    |> String.replace_invalid("�")
    |> take_utf8_bytes(@max_line_bytes)
  end

  @spec fit_page([map()]) :: [map()]
  def fit_page(hits) do
    {kept, _bytes} =
      Enum.reduce_while(hits, {[], 0}, fn hit, {acc, bytes} ->
        next = bytes + byte_size(hit.text || "") + byte_size(hit.path || "") + 16

        if acc != [] and next > @max_page_bytes do
          {:halt, {acc, bytes}}
        else
          {:cont, {[hit | acc], next}}
        end
      end)

    Enum.reverse(kept)
  end

  defp take_utf8_bytes(text, max_bytes) when byte_size(text) <= max_bytes, do: text

  defp take_utf8_bytes(text, max_bytes) do
    prefix = binary_part(text, 0, max_bytes)

    case :unicode.characters_to_binary(prefix, :utf8, :utf8) do
      valid when is_binary(valid) -> valid
      {:incomplete, valid, _rest} -> IO.iodata_to_binary(valid)
      {:error, valid, _rest} -> IO.iodata_to_binary(valid)
    end
  end
end
