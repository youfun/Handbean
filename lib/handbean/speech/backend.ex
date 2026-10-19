defmodule Handbean.Speech.Backend do
  @moduledoc false

  @type model :: term()

  @callback available?() :: boolean()
  @callback load_model(Path.t()) :: {:ok, model()} | {:error, term()}
  @callback transcribe(model(), binary(), keyword()) :: {:ok, String.t()} | {:error, term()}
end
