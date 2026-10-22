defmodule HandbeanProbe.ModelSettings.SubscriptionRender do
  @moduledoc """
  Subscription login section for native Model settings.

  Shows the verification URI as text, a Copy control for that URI, and Open
  in the system browser. A user code, when the provider returns one, is a
  secondary row with its own Copy control. Tokens are never rendered.
  """

  use Gettext, backend: HandbeanProbe.Gettext
  import HandbeanProbe.NativeUI

  alias HandbeanProbe.ModelSettings.Subscriptions

  def section(_state) do
    [
      settings_group([
        settings_nav_row(
          gettext("Subscription sign-in"),
          gettext("Sign in"),
          :open_subscription_login
        )
      ])
    ]
  end

  @doc "Native subscription picker or active device-login sheet."
  def modal(state, notice \\ nil)

  def modal(%{subscription_login: login} = state, notice) when is_map(login) do
    modal_frame(waiting(state, login, notice))
  end

  def modal(%{subscription_picker: true, subscription_busy?: true}, _notice) do
    modal_frame([
      text(gettext("Sign in with a subscription"), text_size: 17),
      text(gettext("Starting sign-in…"),
        text_size: 13,
        text_color: color(:hint),
        padding_top: 8,
        padding_bottom: 8
      ),
      quiet_button(gettext("Cancel"), :cancel_subscription_login, fill_width: true)
    ])
  end

  def modal(%{subscription_picker: true} = state, _notice) do
    modal_frame([
      text(gettext("Sign in with a subscription"), text_size: 17),
      text(
        gettext(
          "Choose a subscription sign-in. Subscription quota is separate from API balance."
        ),
        text_size: 12,
        text_color: color(:hint),
        padding_top: 4,
        padding_bottom: 8
      ),
      node(:column, [fill_width: true], spaced(method_buttons(state))),
      quiet_button(gettext("Cancel"), :close_subscription_login,
        fill_width: true,
        padding_top: 12
      )
    ])
  end

  def modal(_state, _notice), do: nil

  defp waiting(state, login, current_notice) do
    [
      notice(current_notice),
      text(login.login_label || gettext("Subscription sign-in"), text_size: 16),
      text(login.hint || Subscriptions.hint(login.provider_id),
        text_size: 12,
        text_color: color(:hint),
        padding_top: 4,
        padding_bottom: 8
      ),
      text(gettext("Verification link"), text_size: 13),
      text(login.verification_uri || "",
        text_size: 12,
        text_color: color(:ink),
        padding_top: 4,
        padding_bottom: 8
      ),
      row(
        spaced([
          quiet_button(gettext("Copy"), {:copy_subscription, :verification_uri}),
          secondary_button(gettext("Open link"), :open_subscription_link)
        ]),
        padding_bottom: 8
      )
    ] ++
      user_code_row(login) ++
      status_row(state, login) ++
      [quiet_button(gettext("Cancel"), :cancel_subscription_login)]
  end

  defp user_code_row(%{user_code: code}) when is_binary(code) and code != "" do
    [
      text(gettext("User code"), text_size: 13, padding_top: 4),
      text(code, text_size: 18, padding_top: 4, padding_bottom: 8),
      row(
        [quiet_button(gettext("Copy"), {:copy_subscription, :user_code})],
        padding_bottom: 8
      )
    ]
  end

  defp user_code_row(_), do: []

  defp status_row(%{subscription_busy?: true}, _login) do
    [
      text(gettext("Starting sign-in…"),
        text_size: 12,
        text_color: color(:hint),
        padding_bottom: 8
      )
    ]
  end

  defp status_row(_state, _login) do
    [
      text(gettext("Waiting for authorization…"),
        text_size: 12,
        text_color: color(:hint),
        padding_bottom: 8
      )
    ]
  end

  defp method_buttons(%{subscription_methods: methods}) when is_list(methods) do
    Enum.map(methods, fn method ->
      secondary_button(method.login_label, {:start_subscription, method.id}, fill_width: true)
    end)
  end

  defp method_buttons(_state) do
    Subscriptions.methods()
    |> Enum.map(fn method ->
      secondary_button(method.login_label, {:start_subscription, method.id}, fill_width: true)
    end)
  end

  defp modal_frame(children) do
    sheet(
      node(:column, [fill_width: true, padding: 16], children),
      id: "subscription-login",
      dismiss: :cancel_subscription_login,
      detents: [:content]
    )
  end
end
