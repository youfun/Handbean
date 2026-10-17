defmodule Handbean.EndpointAdapter do
  @moduledoc """
  Boundary for the configured presentation endpoint.

  The concrete Phoenix endpoint is selected by the application composition
  config. Core modules use this boundary for URL generation and signed cursors
  without depending on a presentation-layer module.
  """

  @config_key :endpoint_adapter

  @spec implementation() :: module()
  def implementation do
    Application.fetch_env!(:handbean, @config_key)
  end

  @spec url() :: String.t()
  def url do
    implementation().url()
  end

  @spec server?() :: boolean()
  def server? do
    Application.get_env(:handbean, implementation(), [])
    |> Keyword.get(:server, false)
    |> Kernel.==(true)
  end

  @spec sign(String.t(), term()) :: String.t()
  def sign(salt, value) when is_binary(salt) do
    Phoenix.Token.sign(implementation(), salt, value)
  end

  @spec verify(String.t(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def verify(salt, token, opts \\ []) when is_binary(salt) and is_binary(token) do
    Phoenix.Token.verify(implementation(), salt, token, opts)
  end

  @spec config_change(keyword(), [atom()]) :: :ok
  def config_change(changed, removed) do
    implementation().config_change(changed, removed)
  end
end
