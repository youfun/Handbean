defmodule Handbean.Attachments.Type do
  @moduledoc """
  Single Elixir classification at the local-file boundary.
  Images require magic. Binary containers are never text. Declared image
  without magic is rejected.
  """

  @image_types ~w(image/png image/jpeg image/gif image/webp)
  @text_types ~w(text/plain text/markdown application/json text/csv text/x-source)
  @text_exts ~w(.txt .md .markdown .json .csv .ex .exs .erl .hrl .js .ts .tsx .jsx .py .rb .go .rs .c .h .cpp .hpp .java .kt .kts .swift .sh .xml .yml .yaml .toml .html .css .sql)

  def image_types, do: @image_types
  def text_types, do: @text_types

  @spec classify(binary() | nil, String.t() | nil, String.t() | nil) ::
          {:ok, String.t()} | {:error, :unsupported_type}
  def classify(head, display_name, _declared_mime \\ nil) do
    ext = display_name |> to_string() |> Path.extname() |> String.downcase()

    cond do
      binary_magic?(head) ->
        {:error, :unsupported_type}

      match?({:ok, _}, image_magic(head)) ->
        image_magic(head)

      utf8_text?(head) and ext in @text_exts ->
        {:ok, text_canonical(ext)}

      true ->
        {:error, :unsupported_type}
    end
  end

  @spec match(String.t(), String.t(), binary()) :: :ok | {:error, :type_mismatch}
  def match(canonical, _display_name, head) when canonical in @image_types do
    case image_magic(head) do
      {:ok, ^canonical} -> :ok
      _ -> {:error, :type_mismatch}
    end
  end

  def match(canonical, display_name, head) when canonical in @text_types do
    ext = display_name |> to_string() |> Path.extname() |> String.downcase()

    if not binary_magic?(head) and utf8_text?(head) and
         (ext in @text_exts or canonical == "text/plain") do
      :ok
    else
      {:error, :type_mismatch}
    end
  end

  def match(_, _, _), do: {:error, :type_mismatch}

  defp image_magic(<<0x89, 0x50, 0x4E, 0x47, _::binary>>), do: {:ok, "image/png"}
  defp image_magic(<<0xFF, 0xD8, 0xFF, _::binary>>), do: {:ok, "image/jpeg"}
  defp image_magic(<<"GIF8", _::binary>>), do: {:ok, "image/gif"}
  defp image_magic(<<"RIFF", _::binary-size(4), "WEBP", _::binary>>), do: {:ok, "image/webp"}
  defp image_magic(_), do: :error

  defp binary_magic?(<<"%PDF", _::binary>>), do: true
  defp binary_magic?(<<"PK", _::binary>>), do: true
  defp binary_magic?(<<0xD0, 0xCF, 0x11, 0xE0, _::binary>>), do: true
  defp binary_magic?(<<0x7F, "ELF", _::binary>>), do: true
  defp binary_magic?(_), do: false

  defp utf8_text?(nil), do: false

  defp utf8_text?(bin) when is_binary(bin) do
    sample = binary_part(bin, 0, min(byte_size(bin), 4096))
    :binary.match(sample, <<0>>) == :nomatch and valid_utf8_prefix?(sample)
  end

  defp valid_utf8_prefix?(bin), do: do_utf8(bin)

  defp do_utf8(<<>>), do: true
  defp do_utf8(<<b, rest::binary>>) when b <= 0x7F, do: do_utf8(rest)

  defp do_utf8(<<b, rest::binary>>) when b in 0xC2..0xDF do
    case rest do
      <<c, more::binary>> when c in 0x80..0xBF -> do_utf8(more)
      <<>> -> true
      _ -> false
    end
  end

  defp do_utf8(<<b, rest::binary>>) when b in 0xE0..0xEF do
    case rest do
      <<c, d, more::binary>> when c in 0x80..0xBF and d in 0x80..0xBF -> do_utf8(more)
      <<c>> when c in 0x80..0xBF -> true
      <<>> -> true
      _ -> false
    end
  end

  defp do_utf8(<<b, rest::binary>>) when b in 0xF0..0xF4 do
    case rest do
      <<c, d, e, more::binary>>
      when c in 0x80..0xBF and d in 0x80..0xBF and e in 0x80..0xBF ->
        do_utf8(more)

      <<c, d>> when c in 0x80..0xBF and d in 0x80..0xBF ->
        true

      <<c>> when c in 0x80..0xBF ->
        true

      <<>> ->
        true

      _ ->
        false
    end
  end

  defp do_utf8(_), do: false

  defp text_canonical(".md"), do: "text/markdown"
  defp text_canonical(".markdown"), do: "text/markdown"
  defp text_canonical(".json"), do: "application/json"
  defp text_canonical(".csv"), do: "text/csv"

  defp text_canonical(ext) when ext in @text_exts,
    do: if(ext in [".txt"], do: "text/plain", else: "text/x-source")

  defp text_canonical(_), do: "text/plain"
end
