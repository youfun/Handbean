defmodule Handbean.Settings.ModelPolicy do
  @moduledoc """
  Form-shaped view of the workspace `models` policy in `.handbean/settings.jsonc`.

  `Handbean.Agent.ModelConfig.load_workspace_policy/1` returns the raw policy map;
  this module converts it to and from an editable shape:

      %{
        mode: :unrestricted | :restricted | :invalid,
        allowed: %{provider_id => MapSet.t(model_id)},
        default_model: "provider/model" | nil,
        configured?: boolean(),
        error: term()            # only when mode == :invalid
      }
  """

  alias Handbean.Agent.ModelConfig
  alias Handbean.WorkspaceSettings

  @type form :: %{
          required(:mode) => :unrestricted | :restricted | :invalid,
          required(:allowed) => %{optional(String.t()) => MapSet.t()},
          required(:default_model) => String.t() | nil,
          required(:configured?) => boolean(),
          optional(:error) => term()
        }

  @doc "Load the workspace policy as a form. Never raises on a malformed file."
  @spec form(Path.t()) :: form()
  def form(workspace_root) do
    case ModelConfig.load_workspace_policy(workspace_root) do
      :unrestricted ->
        %{mode: :unrestricted, allowed: %{}, default_model: nil, configured?: false}

      {:ok, policy} ->
        providers = allowed_providers(Map.get(policy, "allow", %{}))

        %{
          mode: if(providers == %{}, do: :unrestricted, else: :restricted),
          allowed: allowed_sets(providers),
          default_model: default_model(policy),
          configured?: true
        }

      {:error, reason} ->
        %{mode: :invalid, allowed: %{}, default_model: nil, configured?: true, error: reason}
    end
  end

  @doc """
  Persist a form as the workspace `models` policy.

  `:unrestricted` writes an empty allowlist; `:restricted` writes the checked
  models per provider (empty providers dropped) plus the optional default.
  """
  @spec save(Path.t(), map()) :: :ok | {:error, term()}
  def save(workspace_root, %{mode: :unrestricted}) do
    WorkspaceSettings.write_policy(workspace_root, %{"allow" => %{"providers" => %{}}})
  end

  def save(workspace_root, %{mode: :restricted} = policy) do
    providers =
      policy.allowed
      |> Enum.reject(fn {_provider, models} -> MapSet.size(models) == 0 end)
      |> Map.new(fn {provider, models} ->
        {provider, %{"models" => models |> MapSet.to_list() |> Enum.sort()}}
      end)

    json = %{"allow" => %{"providers" => providers}}
    json = put_default(json, Map.get(policy, :default_model))
    WorkspaceSettings.write_policy(workspace_root, json)
  end

  def save(_workspace_root, _policy), do: {:error, :invalid_policy}

  @doc "Composite `provider/model` default from a raw policy map, or `nil`."
  @spec default_model(map()) :: String.t() | nil
  def default_model(policy) when is_map(policy) do
    default = Map.get(policy, "default", %{})

    with %{} <- default,
         provider when is_binary(provider) <- Map.get(default, "provider"),
         model when is_binary(model) <- Map.get(default, "model") do
      "#{provider}/#{model}"
    else
      _ -> nil
    end
  end

  def default_model(_policy), do: nil

  defp allowed_providers(%{"providers" => providers}) when is_map(providers), do: providers
  defp allowed_providers(allow) when is_map(allow), do: allow
  defp allowed_providers(_), do: %{}

  defp allowed_sets(providers) do
    Map.new(providers, fn {provider, config} ->
      models =
        config
        |> Map.get("models", [])
        |> Enum.filter(&is_binary/1)
        |> MapSet.new()

      {provider, models}
    end)
  end

  defp put_default(json, nil), do: json

  defp put_default(json, default_model) do
    case String.split(default_model, "/", parts: 2) do
      [provider, model] -> Map.put(json, "default", %{"provider" => provider, "model" => model})
      _ -> json
    end
  end
end
