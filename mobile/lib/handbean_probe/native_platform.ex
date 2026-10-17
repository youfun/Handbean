defmodule HandbeanProbe.NativePlatform do
  @moduledoc """
  Which native renderer is hosting HandbeanProbe.

  Mix tests never load `mob_nif`, so the default is `:android` (the Compose
  host the tests assert against). The device sets this once in `App.on_start`.
  """

  @type t :: :android | :ios

  @spec put!(t()) :: :ok
  def put!(platform) when platform in [:android, :ios] do
    Application.put_env(:handbean_probe, :native_platform, platform)
  end

  @spec get() :: t()
  def get, do: Application.get_env(:handbean_probe, :native_platform) || detect()

  @spec ios?() :: boolean()
  def ios?, do: get() == :ios

  @spec android?() :: boolean()
  def android?, do: get() == :android

  @spec detect() :: t()
  def detect do
    try do
      case :mob_nif.platform() do
        :ios -> :ios
        _ -> :android
      end
    rescue
      ArgumentError -> :android
      ErlangError -> :android
    catch
      :error, :undef -> :android
      :error, {:nif_not_loaded, _} -> :android
      :error, {:load_failed, _} -> :android
    end
  end

  @spec dist_node(t()) :: atom()
  def dist_node(:ios), do: :"handbean_probe_ios@127.0.0.1"
  def dist_node(_), do: :"handbean_probe_android@127.0.0.1"
end
