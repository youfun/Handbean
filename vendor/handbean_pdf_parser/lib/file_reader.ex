defmodule NativeElixirPdfUtilities.FileReader do
  @moduledoc false

  alias NativeElixirPdfUtilities.Validators.FileValidator
  alias NativeElixirPdfUtilities.Diagnostics

  @doc "Reads at most the allowed bytes from an opened regular file. Path authorization belongs to the caller."
  @spec read(String.t(), pos_integer()) ::
          {:ok, binary()} | {:error, File.posix() | {atom(), Diagnostics.diagnostic()}}
  def read(path, maximum_bytes) do
    with :ok <- FileValidator.validate_read(path, maximum_bytes),
         {:ok, info} <- File.stat(path),
         :ok <- FileValidator.validate_info(info, maximum_bytes, path),
         {:ok, file} <- :file.open(path, [:raw, :binary, :read]) do
      try do
        with {:ok, info} <- :file.read_file_info(file),
             :ok <- FileValidator.validate_info(File.Stat.from_record(info), maximum_bytes, path) do
          result =
            case :file.read(file, maximum_bytes + 1) do
              :eof -> {:ok, ""}
              result -> result
            end

          with {:ok, bytes} <- result,
               :ok <- FileValidator.validate_size(byte_size(bytes), maximum_bytes, path) do
            {:ok, bytes}
          end
        end
      after
        :file.close(file)
      end
    end
  end
end
