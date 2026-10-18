defmodule HandbeanWeb.GitSettingsLiveTest do
  use HandbeanWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    root = Path.join(System.tmp_dir!(), "handbean_git_live_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    config_path = Path.join(root, "git.json")
    previous = Application.get_env(:handbean, :git_user_config_path)
    Application.put_env(:handbean, :git_user_config_path, config_path)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:handbean, :git_user_config_path, previous),
        else: Application.delete_env(:handbean, :git_user_config_path)

      File.rm_rf(root)
    end)

    :ok
  end

  test "saves identity and an account without rendering the token", %{conn: conn} do
    {:ok, _workspace} = Handbean.WorkspaceStore.ensure_default!()
    {:ok, view, _html} = live(conn, "/settings?tab=git")
    git = find_live_child(view, "settings-git")

    assert has_element?(git, "#git-empty")

    render_submit(element(git, "#git-identity"), %{
      "identity" => %{"name" => "Ada", "email" => "ada@example.com"}
    })

    render_click(element(git, "#git-add"))

    render_submit(element(git, "#git-account-form"), %{
      "account" => %{
        "id" => "github",
        "name" => "GitHub",
        "username" => "ada",
        "endpoint" => "https://github.com",
        "password" => "ghp_secret_token"
      }
    })

    html = render(git)
    assert html =~ "GitHub"
    assert html =~ "default"
    refute html =~ "ghp_secret_token"

    {:ok, cred} = Handbean.Git.Settings.lookup("github")
    assert cred[:password] == "ghp_secret_token"
  end
end
