defmodule Handbean.MCP.OAuth.Store do
  @moduledoc false

  # Separate from ordinary configuration. Encryption prevents accidental plaintext
  # exports; possession of this directory and its key permits decryption.
  def directory do
    path =
      Application.get_env(:handbean, :mcp_oauth_directory) ||
        Path.join([Handbean.Home.path(), ".handbean", "mcp-oauth"])

    if Enum.take(Path.split(Path.expand(path)), -2) == [".handbean", "mcp-oauth"],
      do: path,
      else: raise(ArgumentError, "OAuth storage must use a .handbean/mcp-oauth directory")
  end

  def lock(id, fun) do
    case :global.trans({{__MODULE__, directory(), id}, self()}, fun, [node()]) do
      :aborted -> {:error, :oauth_busy}
      result -> result
    end
  end

  def get(id) do
    with {:ok, key} <- key(),
         {:ok, bytes} <- private_read(path(id)),
         <<iv::binary-size(12), tag::binary-size(16), cipher::binary>> <- bytes,
         plain when is_binary(plain) <-
           :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, cipher, id, tag, false),
         {:ok, data} when is_map(data) <- Handbean.JSON.decode(plain) do
      {:ok, data}
    else
      {:error, :enoent} -> {:error, :not_found}
      _ -> {:error, :oauth_storage_failed}
    end
  end

  def put(id, data) do
    with {:ok, key} <- key() do
      iv = :crypto.strong_rand_bytes(12)

      {cipher, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, Handbean.JSON.encode!(data), id, true)

      atomic_write(path(id), iv <> tag <> cipher)
    end
  end

  def delete(id) do
    case File.rm(path(id)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      _ -> {:error, :oauth_storage_failed}
    end
  end

  def digest(value),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(value)) |> Base.url_encode64(padding: false)

  defp path(id), do: Path.join(directory(), digest(id) <> ".enc")

  defp key do
    lock(:key, fn ->
      dir = directory()
      file = Path.join(dir, "key")

      with :ok <- File.mkdir_p(dir),
           {:ok, %{type: :directory}} <- File.lstat(dir),
           :ok <- File.chmod(dir, 0o700) do
        case private_read(file) do
          {:ok, key} when byte_size(key) == 32 ->
            {:ok, key}

          {:error, :enoent} ->
            key = :crypto.strong_rand_bytes(32)
            with :ok <- create_key(file, key), do: {:ok, key}

          _ ->
            {:error, :oauth_storage_failed}
        end
      else
        _ -> {:error, :oauth_storage_failed}
      end
    end)
  end

  defp private_read(file) do
    with {:ok, %{type: :regular, mode: mode}} <- File.lstat(file),
         true <- Bitwise.band(mode, 0o077) == 0 do
      File.read(file)
    else
      {:error, :enoent} -> {:error, :enoent}
      _ -> {:error, :oauth_storage_failed}
    end
  end

  # Exclusive creation prevents another instance from replacing an established key.
  defp create_key(file, key) do
    with {:ok, io} <- File.open(file, [:write, :binary, :exclusive]) do
      result =
        with :ok <- File.chmod(file, 0o600), :ok <- IO.binwrite(io, key), do: :file.sync(io)

      File.close(io)
      result
    end
  end

  defp atomic_write(file, bytes) do
    temp = file <> "." <> Ecto.UUID.generate() <> ".tmp"

    try do
      with {:ok, io} <- File.open(temp, [:write, :binary, :exclusive]) do
        result =
          with :ok <- File.chmod(temp, 0o600),
               :ok <- IO.binwrite(io, bytes),
               :ok <- :file.sync(io),
               do: :ok

        File.close(io)
        with :ok <- result, do: File.rename(temp, file)
      end
      |> case do
        :ok -> :ok
        _ -> {:error, :oauth_storage_failed}
      end
    after
      File.rm(temp)
    end
  end
end
