defmodule HandbeanProbe.GitSettingsTest do
  use ExUnit.Case, async: true

  alias HandbeanProbe.GitSettings

  setup do
    Gettext.put_locale(HandbeanProbe.Gettext, "en")
    :ok
  end

  test "renders identity, empty accounts, and editor without the saved token" do
    empty = inspect(GitSettings.render(GitSettings.empty()), limit: :infinity)
    assert empty =~ "No Git accounts yet"

    state =
      GitSettings.loaded(GitSettings.empty(), {
        :ok,
        %{
          identity: %{"name" => "Ada", "email" => "ada@example.com"},
          default_account: "github",
          accounts: [
            %{
              id: "github",
              name: "GitHub",
              username: "ada",
              endpoint: "https://github.com",
              default?: true,
              has_password: true
            }
          ]
        }
      })

    listed = inspect(GitSettings.render(state), limit: :infinity)
    assert listed =~ "Ada"
    assert listed =~ "GitHub"
    assert listed =~ "https://github.com"
    refute listed =~ "ghp_"

    form = %{
      "id" => "github",
      "name" => "GitHub",
      "username" => "ada",
      "endpoint" => "https://github.com",
      "password" => "",
      "has_password" => true
    }

    editing = GitSettings.open_edit(state, {:ok, form})
    rendered = inspect(GitSettings.render(editing), limit: :infinity)
    assert rendered =~ "Leave blank to keep the saved token"
    assert rendered =~ "secure: true"
  end
end
