defmodule Handbean.Platform.FileManager do
  @moduledoc """
  Host-declared desktop file-manager integration.

  Callers provide a workspace path that has already been validated by the
  workspace owner. This module selects the injected backend; it never infers a
  backend from the operating system or UI surface.
  """

  alias Handbean.Host

  @type kind :: :finder | :explorer | :file_manager

  @callback available?() :: boolean()
  @callback kind() :: kind()
  @callback reveal(String.t()) :: :ok | {:error, term()}

  @spec available?() :: boolean()
  def available? do
    case Host.file_manager_backend() do
      nil ->
        false

      backend when is_atom(backend) ->
        Code.ensure_loaded?(backend) and function_exported?(backend, :reveal, 1) and
          (not function_exported?(backend, :available?, 0) or backend.available?())

      backend when is_function(backend, 1) ->
        true
    end
  end

  @spec kind() :: kind() | nil
  def kind do
    case Host.file_manager_backend() do
      nil ->
        nil

      backend when is_atom(backend) ->
        if Code.ensure_loaded?(backend) and function_exported?(backend, :kind, 0),
          do: backend.kind(),
          else: :file_manager

      backend when is_function(backend, 1) ->
        :file_manager
    end
  end

  @spec reveal(String.t()) :: :ok | {:error, term()}
  def reveal(path) when is_binary(path) do
    case Host.file_manager_backend() do
      nil ->
        {:error, :unavailable}

      backend when is_atom(backend) ->
        if available?(), do: backend.reveal(path), else: {:error, :unavailable}

      backend when is_function(backend, 1) ->
        backend.(path)
    end
  end
end
