defmodule Handbean.Agent.CliAgent.Registry do
  @moduledoc """
  Maps a CLI backend id to the module that owns that loop.

  Adding a later CLI is a new module plus `register/1`. Turn, Coordinator,
  and Provider do not change. Handbean's own provider loop is not an entry
  here; this registry only lists external loop owners.
  """

  alias Handbean.Agent.CliAgent
  alias Handbean.Agent.CliAgent.{Droid, Grok}

  @default [Droid, Grok]

  @doc "Built-in backends. Tests may add more with `register/1`."
  @spec backends() :: [module()]
  def backends do
    extra = Application.get_env(:handbean, :cli_agent_backends, [])
    @default ++ List.wrap(extra)
  end

  @doc "Register an additional backend module for this runtime. Does not touch Droid."
  @spec register(module()) :: :ok
  def register(module) when is_atom(module) do
    extra = Application.get_env(:handbean, :cli_agent_backends, [])
    Application.put_env(:handbean, :cli_agent_backends, Enum.uniq(extra ++ [module]))
    :ok
  end

  @doc "Drop test registrations. Built-in backends stay."
  @spec reset() :: :ok
  def reset do
    Application.delete_env(:handbean, :cli_agent_backends)
    :ok
  end

  @doc "Resolve a backend id to its module."
  @spec fetch(String.t()) :: {:ok, module()} | {:error, :unknown_backend}
  def fetch(id) when is_binary(id) do
    case Enum.find(backends(), &(backend_id(&1) == id)) do
      nil -> {:error, :unknown_backend}
      module -> {:ok, module}
    end
  end

  @default_capabilities %{
    attachments: false,
    approvals: false,
    ask_user: false,
    reasoning: false,
    session_resume: true,
    streaming: true,
    model_list: true,
    interrupt: true
  }

  @doc """
  Backends the UI may offer.

  `available?/0` decides whether a CLI is selectable. A missing executable is
  disabled, never installed.
  """
  @spec selectable() :: [
          %{
            id: String.t(),
            available: boolean(),
            module: module(),
            capabilities: CliAgent.capabilities()
          }
        ]
  def selectable do
    Enum.map(backends(), fn module ->
      %{
        id: backend_id(module),
        available: available?(module),
        module: module,
        capabilities: module_capabilities(module)
      }
    end)
  end

  @doc "List models for a selected CLI. Unknown ids are rejected before any spawn."
  @spec list_models(String.t(), keyword()) :: {:ok, [CliAgent.model()]} | {:error, term()}
  def list_models(id, opts \\ []) when is_binary(id) do
    with {:ok, module} <- fetch(id) do
      if available?(module) do
        module.list_models(opts)
      else
        {:error, :not_available}
      end
    end
  end

  @doc "Return explicitly declared backend capabilities. Missing declarations fail closed."
  @spec capabilities(String.t()) :: {:ok, CliAgent.capabilities()} | {:error, :unknown_backend}
  def capabilities(id) when is_binary(id) do
    with {:ok, module} <- fetch(id) do
      {:ok, module_capabilities(module)}
    end
  end

  @doc "Whether a backend explicitly accepts prepared attachment-bearing messages."
  @spec attachments?(String.t()) :: boolean()
  def attachments?(id) when is_binary(id) do
    match?({:ok, %{attachments: true}}, capabilities(id))
  end

  defp module_capabilities(module) do
    declared =
      if Code.ensure_loaded?(module) and function_exported?(module, :capabilities, 0),
        do: module.capabilities(),
        else: %{}

    @default_capabilities
    |> Map.merge(declared)
    |> Map.update(:attachments, false, &(&1 == true))
  end

  defp available?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :available?, 0) and
      module.available?()
  end

  defp backend_id(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :id, 0) do
      module.id()
    end
  end
end
