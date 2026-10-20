defmodule Handbean.CodeIndex.Location do
  @moduledoc """
  Chooses a checkout-specific SQLite directory beneath a workspace-owned index
  namespace, falling back to host data for imported or unwritable roots.
  """

  alias Handbean.{CheckoutScope, Host}

  @imported "imported_workspaces"

  @spec resolve(Path.t(), String.t(), keyword()) :: {:ok, Path.t()} | {:error, term()}
  def resolve(checkout_root, workspace_id, opts \\ [])

  def resolve(checkout_root, workspace_id, opts)
      when is_binary(checkout_root) and is_binary(workspace_id) do
    with true <- workspace_id != "" or {:error, :missing_workspace_id},
         {:ok, checkout} <- CheckoutScope.resolve(checkout_root) do
      if Keyword.get(opts, :storage) == :host_data do
        {:ok, fallback_dir(workspace_id, checkout.key)}
      else
        owner = workspace_owner(workspace_id, checkout.path)

        if imported?(checkout.path) or not writable_workspace?(owner) do
          {:ok, fallback_dir(workspace_id, checkout.key)}
        else
          prefer_workspace_dir(owner, workspace_id, checkout.key)
        end
      end
    end
  end

  def resolve(_, _, _), do: {:error, :invalid_workspace}

  @spec fallback_dir(String.t()) :: Path.t()
  def fallback_dir(workspace_id),
    do: Path.join([Host.data_dir(), ".handbean", "code-index", workspace_id])

  @spec fallback_dir(String.t(), String.t()) :: Path.t()
  def fallback_dir(workspace_id, checkout_key),
    do: Path.join([fallback_dir(workspace_id), checkout_key])

  @spec imported?(Path.t()) :: boolean()
  def imported?(root), do: root |> Path.split() |> Enum.any?(&(&1 == @imported))

  defp workspace_owner(workspace_id, checkout_root) do
    case Handbean.WorkspaceStore.get(workspace_id) do
      {:ok, %{"path" => path}} when is_binary(path) -> path
      _ -> checkout_root
    end
  end

  defp prefer_workspace_dir(root, workspace_id, checkout_key) do
    dir = Path.join([root, ".handbean", "code-index", checkout_key])

    case ensure_writable(dir) do
      :ok -> {:ok, dir}
      {:error, _} -> {:ok, ensure_fallback!(workspace_id, checkout_key)}
    end
  end

  defp writable_workspace?(root) do
    case File.lstat(root) do
      {:ok, %File.Stat{type: :directory, access: access}} when access in [:read_write, :write] ->
        true

      {:ok, %File.Stat{type: :directory}} ->
        probe_write(root)

      _ ->
        false
    end
  end

  defp probe_write(root) do
    probe = Path.join(root, ".handbean-index-write-probe")

    case File.write(probe, "") do
      :ok ->
        File.rm(probe)
        true

      {:error, _} ->
        false
    end
  end

  defp ensure_writable(dir) do
    with :ok <- File.mkdir_p(dir) do
      probe = Path.join(dir, ".write-probe")

      case File.write(probe, "") do
        :ok ->
          File.rm(probe)
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp ensure_fallback!(workspace_id, checkout_key) do
    dir = fallback_dir(workspace_id, checkout_key)
    File.mkdir_p!(dir)
    dir
  end
end
