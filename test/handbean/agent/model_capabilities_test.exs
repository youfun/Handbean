defmodule Handbean.Agent.ModelCapabilitiesTest do
  use ExUnit.Case, async: true
  alias Handbean.Agent.ModelCapabilities

  test "supported input types are the shared normalization boundary" do
    assert ModelCapabilities.supported_input_types() == ["text", "image", "audio"]
  end

  test "capabilities come from input metadata, never model or provider names" do
    model = %{id: "arbitrary/text-only", input: ["text", "image"]}
    assert :ok = ModelCapabilities.validate_inputs(model, ["image", "image"])

    assert {:error, {:model_input, "audio", :unsupported}} =
             ModelCapabilities.validate_inputs(model, ["audio"])

    assert {:error, {:model_input, "image", :unsupported}} =
             ModelCapabilities.validate_inputs(%{id: "vision", input: ["text"]}, ["image"])
  end

  test "undeclared non-text capability is unknown, not implicitly supported" do
    for model <- [nil, %{}, %{input: []}, %{input: nil}] do
      assert :ok = ModelCapabilities.validate_inputs(model, ["text"])

      assert {:error, {:model_input, "image", :unknown}} =
               ModelCapabilities.validate_inputs(model, ["image"])
    end
  end
end
