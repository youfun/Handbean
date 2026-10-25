defmodule Handbean.Settings.SecurityTest do
  use ExUnit.Case, async: true

  alias Handbean.Settings.Security

  setup do
    global_dir =
      Path.join(
        System.tmp_dir!(),
        "handbean-security-settings-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(global_dir)
    on_exit(fn -> File.rm_rf!(global_dir) end)
    %{global_dir: global_dir, path: Path.join(global_dir, "settings.json")}
  end

  test "defaults to disabled and persists explicit values", %{global_dir: global_dir} do
    assert {:ok, false} = Security.secret_masking_enabled?(global_dir: global_dir)
    assert :ok = Security.set_secret_masking(true, global_dir: global_dir)
    assert {:ok, true} = Security.secret_masking_enabled?(global_dir: global_dir)
    assert :ok = Security.set_secret_masking(false, global_dir: global_dir)
    assert {:ok, false} = Security.secret_masking_enabled?(global_dir: global_dir)
  end

  test "rejects malformed sections and non-boolean values", %{path: path, global_dir: global_dir} do
    File.write!(path, Handbean.JSON.encode!(%{"security" => "on"}))

    assert {:error, :invalid_security_settings} =
             Security.secret_masking_enabled?(global_dir: global_dir)

    File.write!(path, Handbean.JSON.encode!(%{"security" => %{"secret_masking" => "yes"}}))

    assert {:error, :invalid_secret_masking_setting} =
             Security.secret_masking_enabled?(global_dir: global_dir)
  end
end
