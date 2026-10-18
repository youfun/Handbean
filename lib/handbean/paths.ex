defmodule Handbean.Paths do
  @moduledoc """
  Locations for priv/ and static assets.

  Hosts that unpack a flat OTP tree set `:priv_dir` on `Handbean.Host`.
  """

  @spec priv_dir() :: String.t()
  def priv_dir, do: Handbean.Host.priv_dir()

  @spec static_root() :: String.t()
  def static_root, do: Path.join(priv_dir(), "static")

  @spec migrations_dir() :: String.t()
  def migrations_dir, do: Path.join(priv_dir(), "repo/migrations")
end
