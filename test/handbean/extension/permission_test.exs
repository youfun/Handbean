defmodule Handbean.Extension.PermissionTest do
  use Handbean.DataCase, async: true

  alias Handbean.Extension.Permission

  describe "default/0" do
    test "returns minimal permissions" do
      default = Permission.default()
      assert default == %{"network" => [], "filesystem" => "none", "tools" => []}
    end
  end

  describe "validate/1" do
    test "validates valid permissions" do
      perms = %{
        "network" => ["http://localhost:8000"],
        "filesystem" => "workspace",
        "tools" => ["read", "bash"]
      }

      assert :ok = Permission.validate(perms)
    end

    test "validates minimal permissions" do
      assert :ok = Permission.validate(%{"network" => [], "filesystem" => "none", "tools" => []})
    end

    test "rejects wildcard in network allowlist" do
      perms = %{"network" => ["*"], "filesystem" => "none", "tools" => []}
      assert {:error, diagnostic} = Permission.validate(perms)
      assert diagnostic.type == :validation_error
      assert diagnostic.message =~ "wildcard"
    end

    test "rejects invalid filesystem value" do
      perms = %{"network" => [], "filesystem" => "unrestricted", "tools" => []}
      assert {:error, diagnostic} = Permission.validate(perms)
      assert diagnostic.type == :validation_error
      assert diagnostic.message =~ "filesystem"
    end

    test "accepts all valid filesystem values" do
      for value <- ["none", "workspace", "read-only"] do
        perms = %{"network" => [], "filesystem" => value, "tools" => []}
        assert :ok = Permission.validate(perms), "filesystem '#{value}' should be valid"
      end
    end

    test "unknown permission keys are not rejected" do
      perms = %{"network" => [], "filesystem" => "none", "tools" => [], "custom" => "value"}
      assert :ok = Permission.validate(perms)
    end

    test "rejects non-map permissions" do
      assert {:error, %{message: "permissions must be a map"}} = Permission.validate("not a map")
      assert {:error, %{message: "permissions must be a map"}} = Permission.validate(nil)
    end

    test "rejects network value that is not a list" do
      perms = %{"network" => "http://localhost", "filesystem" => "none", "tools" => []}

      assert {:error, %{message: "network permission must be a list of URLs"}} =
               Permission.validate(perms)
    end

    test "rejects tools value that is not a list" do
      perms = %{"network" => [], "filesystem" => "none", "tools" => "read"}
      assert {:error, %{message: "tools permission must be a list"}} = Permission.validate(perms)
    end
  end

  describe "valid_filesystem?/1" do
    test "known values" do
      assert Permission.valid_filesystem?("none")
      assert Permission.valid_filesystem?("workspace")
      assert Permission.valid_filesystem?("read-only")
    end

    test "unknown values" do
      refute Permission.valid_filesystem?("everything")
      refute Permission.valid_filesystem?("")
    end
  end
end
