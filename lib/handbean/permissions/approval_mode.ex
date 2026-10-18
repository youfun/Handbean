defmodule Handbean.Permissions.ApprovalMode do
  @moduledoc """
  Workspace tool approval mode.
  """

  @type t :: :auto | :prompt | :deny | :yolo
  @modes [:auto, :prompt, :deny, :yolo]

  @spec parse(term(), t()) :: t()
  def parse(value, default \\ :auto)
  def parse(value, _default) when value in @modes, do: value

  def parse(value, _default) when value in ["auto", "prompt", "deny", "yolo"],
    do: String.to_existing_atom(value)

  def parse(_value, default), do: default

  @spec valid?(term()) :: boolean()
  def valid?(value), do: parse(value, :invalid) != :invalid
end
