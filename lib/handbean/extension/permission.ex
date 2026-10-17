defmodule Handbean.Extension.Permission do
  @moduledoc """
  Permission model for extensions.

  Structure only. Does NOT enforce permissions.
  """

  alias Handbean.Extension.Diagnostic

  @valid_filesystem_values ["none", "workspace", "read-only"]

  @spec default() :: map()
  def default do
    %{"network" => [], "filesystem" => "none", "tools" => []}
  end

  @spec validate(map()) :: :ok | {:error, Diagnostic.t()}
  def validate(permissions) when is_map(permissions) do
    checks = [&validate_filesystem/1, &validate_network/1, &validate_tools/1]

    Enum.reduce_while(checks, :ok, fn check, :ok ->
      case check.(permissions) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  def validate(_) do
    {:error, %Diagnostic{type: :validation_error, message: "permissions must be a map"}}
  end

  @spec valid_filesystem?(String.t()) :: boolean()
  def valid_filesystem?(value) when value in @valid_filesystem_values, do: true
  def valid_filesystem?(_), do: false

  defp validate_filesystem(%{"filesystem" => value}) do
    if valid_filesystem?(value) do
      :ok
    else
      {:error,
       %Diagnostic{
         type: :validation_error,
         message:
           "invalid filesystem permission: #{inspect(value)}. Allowed: #{inspect(@valid_filesystem_values)}"
       }}
    end
  end

  defp validate_filesystem(_), do: :ok

  defp validate_network(%{"network" => networks}) when is_list(networks) do
    if "*" in networks do
      {:error,
       %Diagnostic{type: :validation_error, message: "network wildcard \"*\" is not allowed"}}
    else
      :ok
    end
  end

  defp validate_network(%{"network" => _}) do
    {:error,
     %Diagnostic{type: :validation_error, message: "network permission must be a list of URLs"}}
  end

  defp validate_network(_), do: :ok

  defp validate_tools(%{"tools" => tools}) when is_list(tools), do: :ok

  defp validate_tools(%{"tools" => _}) do
    {:error, %Diagnostic{type: :validation_error, message: "tools permission must be a list"}}
  end

  defp validate_tools(_), do: :ok
end
