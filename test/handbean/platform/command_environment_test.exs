defmodule Handbean.Platform.CommandEnvironmentTest do
  use ExUnit.Case, async: false

  alias Handbean.Platform.CommandEnvironment

  test "sanitizes release and desktop internals without deleting project Phoenix values" do
    environment = %{
      "PATH" => "/usr/bin",
      "ROOTDIR" => "/app/release",
      "HANDBEAN_COMPUTER_TOKEN" => "desktop-secret",
      "PHX_SERVER" => "true",
      "PORT" => "4100"
    }

    assert CommandEnvironment.sanitize(environment) == %{
             "PATH" => "/usr/bin",
             "PHX_SERVER" => "true",
             "PORT" => "4100"
           }
  end

  test "empty workspace environments still clear backend launch values" do
    environment = Map.new(CommandEnvironment.port_env(%{}))

    assert environment["PHX_SERVER"] == false
    assert environment["PORT"] == false
    assert environment["SECRET_KEY_BASE"] == false
    assert environment["HANDBEAN_COMPUTER_TOKEN"] == false
    assert environment["ROOTDIR"] == false
  end

  test "captured and explicit project values override backend unsets" do
    captured = Map.new(CommandEnvironment.port_env(%{"PATH" => "/usr/bin", "PORT" => "4100"}))
    explicit = Map.new(CommandEnvironment.child_port_env(%{"PORT" => "4200"}))

    assert captured["PORT"] == "4100"
    assert captured["PHX_SERVER"] == false
    assert explicit["PORT"] == "4200"
    assert explicit["PHX_SERVER"] == false
  end
end
