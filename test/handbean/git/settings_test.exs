defmodule Handbean.Git.SettingsTest do
  use ExUnit.Case, async: false

  alias Handbean.Git.{Credentials, Settings}

  setup do
    root = Path.join(System.tmp_dir!(), "git-settings-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    opts = [user_config_path: Path.join(root, "git.json")]
    previous = Application.get_env(:handbean, :git_user_config_path)
    Application.put_env(:handbean, :git_user_config_path, opts[:user_config_path])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:handbean, :git_user_config_path, previous),
        else: Application.delete_env(:handbean, :git_user_config_path)

      File.rm_rf!(root)
    end)

    %{opts: opts}
  end

  test "saves identity, accounts, default, and never returns the password", %{opts: opts} do
    assert :ok =
             Settings.save_identity(%{"name" => "Ada", "email" => "ada@example.com"}, opts)

    form =
      Settings.new_form()
      |> Map.merge(%{
        "id" => "github",
        "name" => "GitHub",
        "username" => "ada",
        "endpoint" => "https://github.com/",
        "password" => "ghp_secret"
      })

    assert {:ok, "github"} = Settings.save_account(form, opts)
    assert {:ok, edit} = Settings.edit("github", opts)
    assert edit["password"] == ""
    assert edit["has_password"]
    assert edit["endpoint"] == "https://github.com"

    assert {:ok, %{accounts: [account], default_account: "github"}} = Settings.load(opts)
    refute inspect(account) =~ "ghp_secret"
    assert account.default?

    assert {:ok, cred} = Settings.lookup("github", opts)
    assert cred[:password] == "ghp_secret"
    assert cred[:endpoint] == "https://github.com"

    assert {:ok, resolved} = Credentials.resolve("github")
    assert resolved[:password] == "ghp_secret"

    assert {:ok, defaulted} = Credentials.resolve(nil)
    assert defaulted[:password] == "ghp_secret"

    assert {:ok, "github"} = Settings.save_account(%{edit | "name" => "Work"}, opts)
    assert {:ok, kept} = Settings.lookup("github", opts)
    assert kept[:password] == "ghp_secret"

    assert Bitwise.band(File.stat!(Settings.path(opts)).mode, 0o777) == 0o600
    assert :ok = Settings.delete_account("github", opts)
    assert {:ok, %{accounts: []}} = Settings.load(opts)
    assert {:ok, []} = Credentials.resolve(nil)
  end

  test "rejects a path-bearing endpoint and blank token on create", %{opts: opts} do
    form =
      Settings.new_form()
      |> Map.merge(%{
        "id" => "github",
        "endpoint" => "https://github.com/owner/repo.git",
        "password" => "secret"
      })

    assert {:error, message} = Settings.save_account(form, opts)
    assert message =~ "path"

    form = %{form | "endpoint" => "https://github.com", "password" => ""}
    assert {:error, required} = Settings.save_account(form, opts)
    assert required =~ "Password"
  end
end
