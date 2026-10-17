defmodule Handbean.Agent.Auth.StorageTest do
  @moduledoc """
  TDD tests for ~/.handbean/auth.json credential storage.

  Shape matches pi's AuthStorage: provider-keyed oauth credentials,
  pretty JSON, file mode 0600, directory mode 0700.
  """

  use ExUnit.Case, async: false

  alias Handbean.Agent.Auth.Storage

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "sigil_auth_storage_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    auth_path = Path.join(tmp_dir, "auth.json")

    on_exit(fn -> File.rm_rf(tmp_dir) end)

    {:ok, tmp_dir: tmp_dir, auth_path: auth_path}
  end

  defp oauth_credential(overrides \\ %{}) do
    Map.merge(
      %{
        "type" => "oauth",
        "access" => "access-token",
        "refresh" => "refresh-token",
        "expires" => 1_783_630_500_000
      },
      overrides
    )
  end

  test "put writes pi-shaped oauth credentials and read returns them", %{auth_path: auth_path} do
    credential = oauth_credential()

    assert :ok = Storage.put("xai", credential, auth_path: auth_path)
    assert {:ok, ^credential} = Storage.get("xai", auth_path: auth_path)

    assert {:ok, json} = auth_path |> File.read!() |> Jason.decode()
    assert json == %{"xai" => credential}
  end

  test "get returns :error when the provider is missing", %{auth_path: auth_path} do
    assert :ok = Storage.put("xai", oauth_credential(), auth_path: auth_path)
    assert {:error, :not_found} = Storage.get("openai", auth_path: auth_path)
  end

  test "get returns :error when the file does not exist", %{auth_path: auth_path} do
    assert {:error, :not_found} = Storage.get("xai", auth_path: auth_path)
  end

  test "delete removes only the requested provider", %{auth_path: auth_path} do
    assert :ok = Storage.put("xai", oauth_credential(), auth_path: auth_path)

    assert :ok =
             Storage.put(
               "openai",
               oauth_credential(%{"access" => "other-access"}),
               auth_path: auth_path
             )

    assert :ok = Storage.delete("xai", auth_path: auth_path)
    assert {:error, :not_found} = Storage.get("xai", auth_path: auth_path)
    assert {:ok, %{"access" => "other-access"}} = Storage.get("openai", auth_path: auth_path)
  end

  test "put creates the parent directory and writes mode 0600", %{tmp_dir: tmp_dir} do
    nested = Path.join([tmp_dir, "nested", "dir", "auth.json"])

    assert :ok = Storage.put("xai", oauth_credential(), auth_path: nested)
    assert File.exists?(nested)

    %{mode: file_mode} = File.stat!(nested)
    assert Bitwise.band(file_mode, 0o777) == 0o600

    %{mode: dir_mode} = File.stat!(Path.dirname(nested))
    assert Bitwise.band(dir_mode, 0o777) == 0o700
  end

  test "put rejects a credential missing required oauth fields", %{auth_path: auth_path} do
    assert {:error, message} =
             Storage.put("xai", %{"type" => "oauth", "access" => "only-access"},
               auth_path: auth_path
             )

    assert message =~ "Invalid auth.json credential"
  end

  test "get rejects a stored credential with the wrong shape", %{auth_path: auth_path} do
    File.write!(auth_path, Jason.encode!(%{"xai" => %{"type" => "oauth", "access" => "x"}}))

    assert {:error, message} = Storage.get("xai", auth_path: auth_path)
    assert message =~ "Invalid auth.json credential"
  end
end
