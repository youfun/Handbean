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
        state.form -> [editor(state)]
        true -> list(state)
      end

    scroll(children ++ [confirm_sheet(state)], id: "git-settings")
  end

  defp list(state) do
    [
      text(gettext("Git"), text_size: 16, font_weight: "bold"),
      text(
        gettext(
          "Commit author and HTTPS accounts. The default account is used when the agent omits a credential name."
        ),
        text_size: 13,
        text_color: color(:muted),
        padding_top: 6,
        padding_bottom: 8
      ),
      error_text(state.error),
      card([
        text(gettext("Commit identity"), text_size: 15, font_weight: "bold", padding_bottom: 8),
        field(gettext("Name"), state.identity["name"], {:git_identity, :name}),
        field(gettext("Email"), state.identity["email"], {:git_identity, :email}),
        primary_button(gettext("Save identity"), :git_save_identity)
      ]),
      row([
        text(gettext("Accounts"), text_size: 15, font_weight: "bold", weight: 1),
        primary_button(gettext("Add"), :git_add)
      ])
    ] ++ account_cards(state)
  end

  defp account_cards(%{accounts: []}) do
    [card([text(gettext("No Git accounts yet."))])]
  end

  defp account_cards(state) do
    Enum.map(state.accounts, fn account ->
      subtitle =
        [
          account.endpoint,
          if(account.username != "", do: account.username),
          if(account.default?, do: gettext("default"))
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(" · ")

      card([
        text(account.name, font_weight: "bold"),
        text(subtitle, text_size: 12, text_color: color(:muted), padding_top: 4),
        actions_row(
          [
            if(not account.default?,
              do: secondary_button(gettext("Default"), {:git_default, account.id})
            ),
            secondary_button(gettext("Edit"), {:git_edit, account.id})
          ]
          |> Enum.reject(&is_nil/1)
        )
      ])
    end)
  end

  defp editor(state) do
    form = state.form
    editing? = form["id"] not in [nil, ""]

    [
      actions_row([
        primary_button(gettext("Save"), :git_save),
        secondary_button(gettext("Cancel"), :git_cancel)
      ]),
      text(if(editing?, do: gettext("Edit Git account"), else: gettext("Add Git account")),
        text_size: 16,
        font_weight: "bold"
      ),
      error_text(state.error),
      if(editing?,
        do: text(gettext("Id: %{id}", id: form["id"]), padding_bottom: 8),
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
      ),
      actions_row([
        primary_button(gettext("Save"), :git_save),
        quiet_button(gettext("Cancel"), :git_cancel)
      ]),
      if(editing?, do: actions_row([danger_button(gettext("Delete"), :git_ask_delete)]))
    ]
    |> List.flatten()
    |> card()
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
