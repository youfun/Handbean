defmodule Handbean.Tool.Builtin.ElixirScriptHangInspect do
  @moduledoc false
  defstruct []
end

defimpl Inspect, for: Handbean.Tool.Builtin.ElixirScriptHangInspect do
  def inspect(_value, _opts) do
    receive do
      :never -> "%Handbean.Tool.Builtin.ElixirScriptHangInspect{}"
    end
  end
end
