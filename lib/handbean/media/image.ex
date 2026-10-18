defmodule Handbean.Media.Image do
  @moduledoc false

  @max_bytes 5_000_000
  @mime_extensions %{
    "image/png" => "png",
    "image/jpeg" => "jpg",
    "image/gif" => "gif",
    "image/webp" => "webp"
  }

  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @spec verify(binary(), String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def verify(bytes, declared_mime \\ nil)

  def verify(bytes, declared_mime)
      when is_binary(bytes) and byte_size(bytes) > 0 and byte_size(bytes) <= @max_bytes do
    with {:ok, detected_mime} <- detect(bytes),
         :ok <- matches_declared(detected_mime, declared_mime) do
      {:ok, detected_mime}
    end
  end

  def verify(_bytes, _declared_mime), do: {:error, :image_too_large_or_empty}

  @spec validate_filename(String.t(), String.t()) :: :ok | {:error, term()}
  def validate_filename(filename, mime_type) when is_binary(filename) do
    extension = filename |> Path.extname() |> String.downcase()

    case {mime_type, extension} do
      {_mime_type, ""} ->
        :ok

      {"image/png", ".png"} ->
        :ok

      {"image/jpeg", extension} when extension in [".jpg", ".jpeg"] ->
        :ok

      {"image/gif", ".gif"} ->
        :ok

      {"image/webp", ".webp"} ->
        :ok

      {_mime_type, extension} when extension in [".png", ".jpg", ".jpeg", ".gif", ".webp"] ->
        {:error, :type_mismatch}

      {_mime_type, _extension} ->
        {:error, :unsupported_type}
    end
  end

  def validate_filename(_filename, _mime_type), do: {:error, :invalid_filename}

  @spec extension(String.t()) :: {:ok, String.t()} | {:error, :unsupported_type}
  def extension(mime_type) do
    case Map.fetch(@mime_extensions, mime_type) do
      {:ok, extension} -> {:ok, extension}
      :error -> {:error, :unsupported_type}
    end
  end

  @spec sha256(binary()) :: String.t()
  def sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp detect(<<137, 80, 78, 71, 13, 10, 26, 10, _rest::binary>>), do: {:ok, "image/png"}
  defp detect(<<255, 216, 255, _rest::binary>>), do: {:ok, "image/jpeg"}
  defp detect(<<"GIF87a", _rest::binary>>), do: {:ok, "image/gif"}
  defp detect(<<"GIF89a", _rest::binary>>), do: {:ok, "image/gif"}
  defp detect(<<"RIFF", _size::binary-size(4), "WEBP", _rest::binary>>), do: {:ok, "image/webp"}
  defp detect(_bytes), do: {:error, :unsupported_type}

  defp matches_declared(_detected, nil), do: :ok
  defp matches_declared(detected, detected), do: :ok
  defp matches_declared(_detected, _declared), do: {:error, :type_mismatch}
end
