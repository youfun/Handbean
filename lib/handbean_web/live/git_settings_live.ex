defmodule HandbeanWeb.GitSettingsLive do
  @moduledoc "Git identity and HTTPS account settings, embedded in Settings."

  use HandbeanWeb, :live_view

  alias Handbean.Git.Settings

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:identity, %{"name" => "", "email" => ""})
     |> assign(:accounts, [])
     |> assign(:default_account, nil)
     |> assign(:form, nil)
     |> assign(:form_error, nil)
     |> assign(:identity_error, nil)
     |> assign(:load_error, nil)
     |> assign(:delete_target, nil)
     |> reload()}
  end

  @impl true
  def handle_event("save_identity", %{"identity" => params}, socket) do
    case Settings.save_identity(params) do
      :ok ->
        {:noreply, socket |> assign(:identity_error, nil) |> reload()}

      {:error, reason} ->
        {:noreply, assign(socket, :identity_error, reason)}
    end
  end

  def handle_event("new_account", _params, socket) do
    {:noreply, socket |> assign(:form_error, nil) |> assign(:form, Settings.new_form())}
  end

  def handle_event("edit_account", %{"id" => id}, socket) do
    case Settings.edit(id) do
      {:ok, form} ->
        {:noreply, socket |> assign(:form_error, nil) |> assign(:form, form)}

      {:error, reason} ->
        {:noreply, assign(socket, :load_error, reason)}
    end
  end

  def handle_event("cancel_account", _params, socket) do
    {:noreply, assign(socket, form: nil, form_error: nil)}
  end

  def handle_event("save_account", %{"account" => params}, socket) do
    form = Map.merge(socket.assigns.form || %{}, params)

    case Settings.save_account(form) do
      {:ok, _id} ->
        {:noreply, socket |> assign(form: nil, form_error: nil) |> reload()}

      {:error, reason} ->
        {:noreply, socket |> assign(:form, form) |> assign(:form_error, reason)}
    end
  end

  def handle_event("set_default", %{"id" => id}, socket) do
    case Settings.set_default(id) do
      :ok -> {:noreply, reload(socket)}
      {:error, reason} -> {:noreply, assign(socket, :load_error, reason)}
    end
  end

  def handle_event("confirm_delete", %{"id" => id}, socket) do
    {:noreply, assign(socket, :delete_target, id)}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :delete_target, nil)}
  end

  def handle_event("delete_account", %{"id" => id}, socket) do
    case Settings.delete_account(id) do
      :ok ->
        {:noreply, socket |> assign(:delete_target, nil) |> reload()}

      {:error, reason} ->
        {:noreply, assign(socket, :load_error, reason)}
    end
  end

  defp reload(socket) do
    case Settings.load() do
      {:ok, %{identity: identity, accounts: accounts, default_account: default}} ->
        socket
        |> assign(:identity, identity)
        |> assign(:accounts, accounts)
        |> assign(:default_account, default)
        |> assign(:load_error, nil)

      {:error, reason} ->
        assign(socket, :load_error, reason)
    end
  end
end
