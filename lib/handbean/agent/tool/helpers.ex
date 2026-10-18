defmodule Handbean.Agent.Tool.Helpers do
  @moduledoc """
  Shared helpers for builtin tool implementations.
  """

  @doc """
  Expands a tilde-prefixed path to the user's home directory.

  ## Examples

      iex> expand_tilde("~/foo/bar.txt")
      "/home/user/foo/bar.txt"

      iex> expand_tilde("/absolute/path")
      "/absolute/path"

      iex> expand_tilde("relative/path")
      "relative/path"
  """
  @spec expand_tilde(String.t()) :: String.t()
  def expand_tilde("~" <> rest), do: Path.join(Handbean.Home.path(), rest)
  def expand_tilde(path), do: path
end
