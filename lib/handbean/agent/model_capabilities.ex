defmodule Handbean.Agent.ModelCapabilities do
  @moduledoc "Input capabilities from normalized model metadata, independent of providers and UI."

  @type support :: :supported | :unsupported | :unknown

  @supported_input_types ["text", "image", "audio"]

  @spec supported_input_types() :: [String.t()]
  def supported_input_types, do: @supported_input_types

  @spec input_support(map() | nil, String.t()) :: support()
  def input_support(%{input: inputs}, type) when is_list(inputs) and inputs != [] do
    if type in inputs, do: :supported, else: :unsupported
  end

  # Existing text-only configurations may predate explicit input metadata.
  def input_support(_model, "text"), do: :supported
  def input_support(_model, _type), do: :unknown

  @spec validate_inputs(map() | nil, [String.t()]) ::
          :ok | {:error, {:model_input, String.t(), :unsupported | :unknown}}
  def validate_inputs(model, inputs) do
    Enum.reduce_while(Enum.uniq(inputs), :ok, fn type, :ok ->
      case input_support(model, type) do
        :supported -> {:cont, :ok}
        status -> {:halt, {:error, {:model_input, type, status}}}
      end
    end)
  end
end
