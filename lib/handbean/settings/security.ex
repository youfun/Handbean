defmodule Handbean.Settings.Security do
  @moduledoc """
  Global security settings whose read failures must not silently disable protection.
  """

  alias Handbean.Settings

  @section "security"
  @setting "secret_masking"

  @spec secret_masking_enabled?(keyword()) :: {:ok, boolean()} | {:error, term()}
  def secret_masking_enabled?(opts \\ []) do
    with {:ok, settings} <- Settings.load_global_strict(opts) do
      case Map.get(settings, @section) do
        nil -> {:ok, false}
        section when is_map(section) -> enabled_value(section)
        _other -> {:error, :invalid_security_settings}
      end
    end
  end

  @spec set_secret_masking(boolean(), keyword()) :: :ok | {:error, term()}
  def set_secret_masking(enabled, opts \\ []) when is_boolean(enabled) do
    Settings.save_global_section(@section, %{@setting => enabled}, opts)
  end

  defp enabled_value(section) do
    case Map.get(section, @setting) do
      nil -> {:ok, false}
      enabled when is_boolean(enabled) -> {:ok, enabled}
      _other -> {:error, :invalid_secret_masking_setting}
    end
  end
end
