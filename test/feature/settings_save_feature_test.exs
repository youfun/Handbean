defmodule HandbeanWeb.Feature.SettingsSaveFeatureTest do
  @moduledoc """
  Saving Git identity and a named account persists both. Reloading settings
  shows the identity and account name, never the token.

  Run: mix test --include e2e test/feature/settings_save_feature_test.exs
  """

  use HandbeanWeb.FeatureCase, async: false

  alias Handbean.Git.Settings
  alias Handbean.TestSupport.E2EHarness

  @moduletag :e2e

  test "saved Git identity and account survive a reload without showing the token", %{conn: conn} do
    %{home: home} = E2EHarness.isolate_home!("settings-save")
    git_path = Path.join(home, ".handbean/git.json")
    File.mkdir_p!(Path.dirname(git_path))
    previous = Application.get_env(:handbean, :git_user_config_path)
    Application.put_env(:handbean, :git_user_config_path, git_path)

    ExUnit.Callbacks.on_exit(fn ->
      if previous,
        do: Application.put_env(:handbean, :git_user_config_path, previous),
        else: Application.delete_env(:handbean, :git_user_config_path)
    end)

    {:ok, _workspace} = Handbean.WorkspaceStore.ensure_default!()

    conn
    |> visit("/settings?tab=git")
    |> within("#settings-git", fn session ->
      session
      |> fill_in("#git-identity input[name='identity[name]']", "Name", with: "Ada", exact: false)
      |> fill_in("#git-identity input[name='identity[email]']", "Email",
        with: "ada@example.com",
        exact: false
      )
      |> click_button("#git-identity button[type='submit']", "Save identity")
      |> click_button("#git-add", "")
      |> fill_in("#git-account-form input[name='account[id]']", "Id",
        with: "github",
        exact: false
      )
      |> fill_in("#git-account-form input[name='account[name]']", "Display name",
        with: "GitHub",
        exact: false
      )
      |> fill_in("#git-account-form input[name='account[username]']", "Username",
        with: "ada",
        exact: false
      )
      |> fill_in("#git-account-form input[name='account[endpoint]']", "HTTPS endpoint",
        with: "https://github.com",
        exact: false
      )
      |> fill_in("#git-account-form input[name='account[password]']", "Password or token",
        with: "ghp_secret_token",
        exact: false
      )
      |> click_button("#git-account-form button[type='submit']", "Save account")
      |> assert_has("#git-settings", "GitHub", timeout: 2_000)
      |> refute_has("#git-settings", "ghp_secret_token")
    end)

    assert Settings.identity() == [name: "Ada", email: "ada@example.com"]
    assert {:ok, cred} = Settings.lookup("github")
    assert cred[:password] == "ghp_secret_token"

    conn
    |> visit("/settings?tab=git")
    |> within("#settings-git", fn session ->
      session
      |> assert_has("#git-identity input[name='identity[name]'][value='Ada']")
      |> assert_has("#git-settings", "GitHub")
      |> refute_has("#git-settings", "ghp_secret_token")
    end)
  end
end
