defmodule Handbean.Agent.Tool.ExecutorTestSupport do
  @moduledoc false

  def ensure_registered(mod) do
    case Handbean.Tool.Registry.get(mod.name()) do
      {:ok, _} -> :ok
      :error -> Handbean.Tool.Registry.register(mod)
    end
  end
end
