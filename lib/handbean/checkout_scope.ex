defmodule Handbean.CheckoutScope do
  @moduledoc false

  @spec resolve(Path.t()) :: {:ok, %{path: String.t(), key: String.t()}} | {:error, term()}
  def resolve(path) when is_binary(path) do
    with {:ok, canonical} <- Handbean.RepoIdentity.canonical_directory(path) do
      {:ok, %{path: canonical, key: key(canonical)}}
    end
  end

  def resolve(_path), do: {:error, :invalid_checkout_path}

  @spec key(Path.t()) :: String.t()
  def key(canonical_path) when is_binary(canonical_path) do
    :crypto.hash(:sha256, canonical_path)
    |> Base.encode16(case: :lower)
  end

  @spec terminal_topic(String.t(), String.t()) :: String.t()
  def terminal_topic(workspace_id, checkout_key) do
    "terminal:#{workspace_id}:#{checkout_key}"
  end
end
