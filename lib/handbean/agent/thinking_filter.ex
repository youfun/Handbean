defmodule Handbean.Agent.ThinkingFilter do
  @moduledoc """
  Splits provider-emitted `<think>...</think>` wrappers from user-visible text.

  Some local providers stream reasoning as ordinary text chunks wrapped in
  tags. The UI can display the reasoning separately, but conversation
  persistence must never store those wrappers as assistant text.
  """

  @doc """
  Strip `<think>...</think>` and `<thinking>...</thinking>` blocks.

  Returns `{thinking_text, clean_text, new_buffer}`. Pass `new_buffer` into the
  next call to handle tags split across streaming chunk boundaries.
  """
  @spec strip(String.t(), String.t()) :: {String.t(), String.t(), String.t()}
  def strip(buffer, chunk) when is_binary(buffer) and is_binary(chunk) do
    {state, partial} =
      if String.starts_with?(buffer, "<in>") do
        {:inside, String.replace_leading(buffer, "<in>", "")}
      else
        {:outside, buffer}
      end

    combined = partial <> chunk
    {thinking, clean, leftover_state, leftover_partial} = do_strip(combined, [], [], state, "")

    new_buffer =
      if leftover_state == :inside do
        "<in>" <> leftover_partial
      else
        leftover_partial
      end

    {thinking, clean, new_buffer}
  end

  def strip(buffer, chunk), do: strip(to_string(buffer || ""), to_string(chunk || ""))

  defp do_strip("", thinking, clean, :outside, partial) do
    if partial != "" and
         (String.starts_with?("<think>", partial) or
            String.starts_with?("<thinking>", partial)) do
      {build_binary(thinking), build_binary(clean), :outside, partial}
    else
      {build_binary(thinking), build_binary([partial | clean]), :outside, ""}
    end
  end

  defp do_strip("", thinking, clean, :inside, partial) do
    if partial != "" and potential_close?(partial) do
      {build_binary(thinking), build_binary(clean), :inside, partial}
    else
      {build_binary([partial | thinking]), build_binary(clean), :inside, ""}
    end
  end

  defp do_strip(rest, thinking, clean, :inside, partial) do
    partial = partial <> String.first(rest)
    rest = String.slice(rest, 1..-1//1)

    cond do
      String.ends_with?(partial, "</think>") ->
        stripped = String.replace_suffix(partial, "</think>", "")
        do_strip(rest, [stripped | thinking], clean, :outside, "")

      String.ends_with?(partial, "</thinking>") ->
        stripped = String.replace_suffix(partial, "</thinking>", "")
        do_strip(rest, [stripped | thinking], clean, :outside, "")

      potential_close?(partial) ->
        do_strip(rest, thinking, clean, :inside, partial)

      true ->
        do_strip(rest, [partial | thinking], clean, :inside, "")
    end
  end

  defp do_strip(rest, thinking, clean, :outside, partial) do
    partial = partial <> String.first(rest)
    rest = String.slice(rest, 1..-1//1)

    cond do
      partial == "<think>" ->
        do_strip(rest, thinking, clean, :inside, "")

      partial == "<thinking>" ->
        do_strip(rest, thinking, clean, :inside, "")

      String.starts_with?("<think>", partial) ->
        do_strip(rest, thinking, clean, :outside, partial)

      String.starts_with?("<thinking>", partial) ->
        do_strip(rest, thinking, clean, :outside, partial)

      true ->
        do_strip(rest, thinking, [partial | clean], :outside, "")
    end
  end

  defp build_binary(parts), do: parts |> Enum.reverse() |> IO.iodata_to_binary()

  defp potential_close?(""), do: false
  defp potential_close?("<"), do: true
  defp potential_close?("</"), do: true

  defp potential_close?(partial) do
    String.starts_with?("</think>", partial) or String.starts_with?("</thinking>", partial)
  end
end
