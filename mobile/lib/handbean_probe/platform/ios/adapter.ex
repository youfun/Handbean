defmodule HandbeanProbe.Platform.IOS.Adapter do
  @moduledoc """
  Injectable iOS host adapter for `HandbeanProbe.Platform.IOS`.

  The default talks to stock Mob NIFs (`open_url` / `share_text` / `files_pick`)
  and the project `handbean_ios` NIF for file present. Tests replace this module
  via `:ios_platform_adapter`. Returning `:ok` means the OS call was
  **submitted**; it is not a claim that the user finished the UI.
  """

  @callback open_url(String.t()) :: :ok | {:error, term()}
  @callback share_text(String.t()) :: :ok | {:error, term()}
  @callback pick_images() :: :ok | {:error, term()}
  @callback present_file(String.t(), :open | :share) :: :ok | {:error, term()}

  @spec current() :: module()
  def current do
    Application.get_env(:handbean_probe, :ios_platform_adapter, __MODULE__.Nif)
  end
end
