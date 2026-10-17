defmodule Handbean.PlatformTest do
  use ExUnit.Case, async: true

  alias Handbean.Platform

  describe "windows?/0" do
    test "matches the host os type" do
      assert Platform.windows?() == match?({:win32, _}, :os.type())
    end

    test "is opposite of unix?/0" do
      assert Platform.windows?() != Platform.unix?()
    end
  end

  describe "unix?/0" do
    test "matches the host os type" do
      assert Platform.unix?() == match?({:unix, _}, :os.type())
    end
  end

  describe "path_env_key/1" do
    test "returns PATH on unix-like systems" do
      assert Platform.path_env_key(%{"PATH" => "/usr/bin"}) == "PATH"
    end

    test "handles Windows-style Path env var" do
      assert Platform.path_env_key(%{"Path" => "C:\\Windows"}) == "Path"
    end

    test "handles empty env" do
      assert Platform.path_env_key(%{}) == "PATH"
    end
  end

  describe "os_type/0" do
    test "returns known tuple" do
      assert Platform.os_type() == :os.type()
    end
  end
end
