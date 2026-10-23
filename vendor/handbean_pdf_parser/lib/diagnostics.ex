defmodule NativeElixirPdfUtilities.Diagnostics do
  @moduledoc """
  Builds consistent diagnostics for public API errors.

  Public operations return diagnostic errors as `{:error, {reason, diagnostic}}`
  when the library can explain why an operation cannot continue. The diagnostic
  map always includes `:stage`, `:reason`, and `:message`, and may include
  actionable context such as `:operation`, `:module`, `:line`, `:column`, or
  `:source`.

  The shared shape lets callers use one error handler across the library. The
  outer reason supports programmatic decisions, while the diagnostic provides
  context for logs and investigation.
  """

  @type diagnostic_option ::
          {:operation, atom()}
          | {:module, module()}
          | {:line, pos_integer()}
          | {:column, pos_integer()}
          | {:source, String.t()}
          | {:source, nil}
  @type diagnostic :: %{
          required(:stage) => atom(),
          required(:reason) => atom(),
          required(:message) => String.t(),
          optional(:operation) => atom(),
          optional(:module) => module(),
          optional(:line) => pos_integer(),
          optional(:column) => pos_integer(),
          optional(:source) => String.t()
        }
  @type detailed_error :: {atom(), diagnostic()}

  @doc """
  Builds a diagnostic map for a public API failure.
  """
  @spec diagnostic(atom(), atom(), String.t(), [diagnostic_option()]) :: diagnostic()
  def diagnostic(stage, reason, message, opts \\ []) do
    %{
      stage: stage,
      reason: reason,
      message: message
    }
    |> maybe_put(:operation, Keyword.get(opts, :operation))
    |> maybe_put(:module, Keyword.get(opts, :module))
    |> maybe_put(:line, Keyword.get(opts, :line))
    |> maybe_put(:column, Keyword.get(opts, :column))
    |> maybe_put(:source, Keyword.get(opts, :source))
  end

  @doc """
  Adds operation, module, or source context to an existing diagnostic map.
  """
  @spec with_context(diagnostic(), [diagnostic_option()]) :: diagnostic()
  def with_context(diagnostic, opts \\ []) do
    case diagnostic do
      diagnostic when is_map(diagnostic) ->
        diagnostic
        |> maybe_put_missing(:operation, Keyword.get(opts, :operation))
        |> maybe_put_missing(:module, Keyword.get(opts, :module))
        |> maybe_put_missing(:source, Keyword.get(opts, :source))

      _ ->
        diagnostic(:unknown, :unknown_error, "operation failed", opts)
    end
  end

  @doc """
  Builds a standard `{:error, {reason, diagnostic}}` result.
  """
  @spec error(atom(), atom(), String.t(), [diagnostic_option()]) :: {:error, detailed_error()}
  def error(stage, reason, message, opts \\ []) do
    {:error, {reason, diagnostic(stage, reason, message, opts)}}
  end

  defp maybe_put(map, key, value) do
    case value do
      nil -> map
      value -> Map.put(map, key, value)
    end
  end

  defp maybe_put_missing(map, key, value) do
    case value do
      nil -> map
      value -> Map.put_new(map, key, value)
    end
  end
end
