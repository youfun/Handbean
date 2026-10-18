defmodule Handbean.Home do
  @moduledoc """
  Writable home for `~/.handbean/...` paths.

  Uses `Handbean.Host.data_dir/0` when the host configured it; otherwise HOME.
  """

  @spec path() :: String.t()
  def path, do: Handbean.Host.data_dir()

  @spec expand(String.t()) :: String.t()
  def expand("~/" <> rest), do: Path.join(path(), rest)
  def expand("~"), do: path()
  def expand(path) when is_binary(path), do: Path.expand(path, path())
end
