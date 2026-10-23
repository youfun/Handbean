defmodule NativeElixirPdfUtilities.Validators.FileValidator do
  @moduledoc false

  alias NativeElixirPdfUtilities.Diagnostics

  @doc false
  @spec validate_read(term(), term()) :: :ok | {:error, {atom(), Diagnostics.diagnostic()}}
  def validate_read(path, maximum_bytes) do
    case is_binary(path) and path != "" and is_integer(maximum_bytes) and maximum_bytes > 0 do
      true ->
        :ok

      false ->
        Diagnostics.error(
          :file,
          :invalid_options,
          "bounded file reads require a path and a positive byte limit"
        )
    end
  end

  @doc false
  @spec validate_info(
          File.Stat.t() | %{type: atom(), size: non_neg_integer()},
          pos_integer(),
          String.t()
        ) ::
          :ok | {:error, {atom(), Diagnostics.diagnostic()}}
  def validate_info(info, maximum_bytes, path) do
    case info.type do
      :regular ->
        validate_size(info.size, maximum_bytes, path)

      _ ->
        Diagnostics.error(:file, :invalid_document, "approved input must be a regular file",
          source: path
        )
    end
  end

  @doc false
  @spec validate_size(non_neg_integer(), pos_integer(), String.t()) ::
          :ok | {:error, {atom(), Diagnostics.diagnostic()}}
  def validate_size(size, maximum_bytes, path) do
    case size <= maximum_bytes do
      true ->
        :ok

      false ->
        Diagnostics.error(
          :file,
          :resource_limit_exceeded,
          "file exceeds the configured #{maximum_bytes}-byte read limit",
          source: path
        )
    end
  end
end
