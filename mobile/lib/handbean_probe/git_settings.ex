defmodule HandbeanProbe.GitSettings do
  @moduledoc "Native state and rendering for Git identity and HTTPS accounts."

  use Gettext, backend: HandbeanProbe.Gettext
  import HandbeanProbe.NativeUI

  def empty do
    %{
      identity: %{"name" => "", "email" => ""},
      accounts: [],
      default_account: nil,
      form: nil,
      original: nil,
      loading?: false,
      busy?: false,
      error: nil,
      confirm: nil
    }
  end

  def loaded(state, {:ok, %{identity: identity, accounts: accounts, default_account: default}}) do
    %{
      state
      | identity: identity,
        accounts: accounts,
        default_account: default,
        loading?: false,
        error: nil
    }
  end

  def loaded(state, {:error, reason}), do: %{state | loading?: false, error: to_string(reason)}

  def open_new(state) do
    form = Handbean.Git.Settings.new_form()
    %{state | form: form, original: form, error: nil, confirm: nil}
  end

  def open_edit(state, {:ok, form}),
    do: %{state | form: form, original: form, error: nil, confirm: nil}

  def open_edit(state, {:error, reason}), do: %{state | error: to_string(reason)}

  def change_identity(state, field, value),
    do: %{state | identity: Map.put(state.identity, Atom.to_string(field), value), error: nil}

  def change(%{form: form} = state, field, value) when is_map(form) do
    %{state | form: Map.put(form, Atom.to_string(field), value), error: nil}
  end

  def dirty?(%{form: nil}), do: false
  def dirty?(state), do: state.form != state.original

  def saved(state, {:ok, _id}), do: %{state | form: nil, original: nil, error: nil}
  def saved(state, :ok), do: %{state | error: nil}
  def saved(state, {:error, reason}), do: %{state | error: to_string(reason)}

  def render(state) do
    children =
      cond do
        state.loading? -> [text(gettext("Loading Git settings…"), padding_top: 24)]
        state.form -> editor(state)
        true -> list(state)
      end

    scroll(children ++ [confirm_sheet(state)], id: "git-settings")
  end

  defp list(state) do
    [
      settings_caption(
        gettext(
          "Commit author and HTTPS accounts. The default account is used when the agent omits a credential name."
        )
      ),
      error_text(state.error),
      settings_section(gettext("Commit identity")),
      settings_group([
        field(gettext("Name"), state.identity["name"], {:git_identity, :name}),
        field(gettext("Email"), state.identity["email"], {:git_identity, :email}),
        settings_nav_row(gettext("Save identity"), "", :git_save_identity)
      ]),
      settings_section(gettext("Accounts")),
      settings_group([settings_nav_row(gettext("Add"), "", :git_add)])
    ] ++ account_rows(state)
  end

  defp account_rows(%{accounts: []}) do
    [settings_caption(gettext("No Git accounts yet."))]
  end

  defp account_rows(state) do
    Enum.map(state.accounts, fn account ->
      subtitle =
        [
          account.endpoint,
          if(account.username != "", do: account.username),
          if(account.default?, do: gettext("default"))
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(" · ")

      settings_group([
        settings_value_row(account.name, subtitle),
        if(not account.default?,
          do: settings_nav_row(gettext("Default"), "", {:git_default, account.id})
        ),
        settings_nav_row(gettext("Edit"), "", {:git_edit, account.id})
      ])
    end)
  end

  defp editor(state) do
    form = state.form
    editing? = form["id"] not in [nil, ""]

    [
      settings_section(
        if(editing?, do: gettext("Edit Git account"), else: gettext("Add Git account"))
      ),
      error_text(state.error),
      settings_group([
        if(editing?,
          do: settings_value_row(gettext("Id"), form["id"]),
          else: field(gettext("Id"), form["id"], {:git_field, :id}, placeholder: "github")
        ),
        field(gettext("Display name"), form["name"], {:git_field, :name}),
        field(gettext("Username"), form["username"], {:git_field, :username}),
        field(gettext("HTTPS endpoint"), form["endpoint"], {:git_field, :endpoint},
          placeholder: "https://github.com"
        ),
        field(gettext("Password or token"), form["password"], {:git_field, :password},
          secure: true,
          placeholder:
            if(form["has_password"], do: gettext("Leave blank to keep the saved token"), else: "")
        )
      ]),
      settings_group([
        settings_nav_row(gettext("Save"), "", :git_save),
        settings_nav_row(gettext("Cancel"), "", :git_cancel, quiet: true),
        if(editing?, do: settings_nav_row(gettext("Delete"), "", :git_ask_delete, danger: true))
      ])
    ]
  end

  defp confirm_sheet(%{confirm: nil}), do: nil

  defp confirm_sheet(%{confirm: :delete}) do
    sheet(
      [
        text(gettext("Delete this Git account?"), text_size: 16),
        actions_row([
          danger_button(gettext("Delete"), :git_delete),
          quiet_button(gettext("Keep"), :git_dismiss_confirm)
        ])
      ],
      dismiss: :git_dismiss_confirm,
      id: "git-delete-confirm"
    )
  end

  defp confirm_sheet(%{confirm: :discard}) do
    sheet(
      [
        text(gettext("Discard unsaved changes?"), text_size: 16),
        actions_row([
          danger_button(gettext("Discard"), :git_discard),
          quiet_button(gettext("Keep editing"), :git_dismiss_confirm)
        ])
      ],
      dismiss: :git_dismiss_confirm,
      id: "git-discard-confirm"
    )
  end

  defp error_text(nil), do: nil

  defp error_text(error),
    do: text(error, text_color: color(:danger), padding_top: 8, padding_bottom: 8)
end
