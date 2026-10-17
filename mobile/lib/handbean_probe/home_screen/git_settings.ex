defmodule HandbeanProbe.HomeScreen.GitSettings do
  @moduledoc "HomeScreen controller for Git identity and account persistence."
  import Mob.Socket, only: [assign: 3]
  alias HandbeanProbe.{GitSettings, HomeScreen.Async}
  alias HandbeanProbe.HomeScreen.Requests

  @scope :git_settings

  def load(socket) do
    socket
    |> assign(:git, %{socket.assigns.git | loading?: true, error: nil})
    |> run(:git_loaded, fn -> Handbean.Git.Settings.load() end)
  end

  def handle(_event, %{assigns: %{git: %{busy?: true}}} = socket), do: socket

  def handle({:change, {:git_identity, field}, value}, socket) do
    put(socket, GitSettings.change_identity(socket.assigns.git, field, value))
  end

  def handle({:change, {:git_field, field}, value}, socket),
    do: put(socket, GitSettings.change(socket.assigns.git, field, value))

  def handle({:tap, :git_add}, socket),
    do: put(socket, GitSettings.open_new(socket.assigns.git))

  def handle({:tap, {:git_edit, id}}, socket),
    do: run(socket, :git_edited, fn -> Handbean.Git.Settings.edit(id) end)

  def handle({:tap, {:git_default, id}}, socket),
    do: run(socket, :git_default_saved, fn -> Handbean.Git.Settings.set_default(id) end)

  def handle({:tap, :git_save_identity}, socket) do
    run(socket, :git_identity_saved, fn ->
      Handbean.Git.Settings.save_identity(socket.assigns.git.identity)
    end)
  end

  def handle({:tap, :git_save}, socket),
    do:
      run(socket, :git_saved, fn ->
        Handbean.Git.Settings.save_account(socket.assigns.git.form)
      end)

  def handle({:tap, :git_cancel}, socket) do
    if GitSettings.dirty?(socket.assigns.git),
      do: put(socket, %{socket.assigns.git | confirm: :discard}),
      else: close(socket)
  end

  def handle({:tap, :git_ask_delete}, socket),
    do: put(socket, %{socket.assigns.git | confirm: :delete})

  def handle({:tap, :git_dismiss_confirm}, socket),
    do: put(socket, %{socket.assigns.git | confirm: nil})

  def handle({:dismiss, :git_dismiss_confirm}, socket),
    do: handle({:tap, :git_dismiss_confirm}, socket)

  def handle({:tap, :git_discard}, socket), do: close(socket)

  def handle({:tap, :git_delete}, socket) do
    run(socket, :git_deleted, fn ->
      Handbean.Git.Settings.delete_account(socket.assigns.git.form["id"])
    end)
  end

  def result(kind, result, socket) do
    socket = put(socket, %{socket.assigns.git | busy?: false})
    apply_result(kind, result, socket)
  end

  defp apply_result(:git_loaded, result, socket),
    do: put(socket, GitSettings.loaded(socket.assigns.git, result))

  defp apply_result(:git_edited, result, socket),
    do: put(socket, GitSettings.open_edit(socket.assigns.git, result))

  defp apply_result(:git_identity_saved, result, socket) do
    state = GitSettings.saved(socket.assigns.git, result)
    if result == :ok, do: socket |> put(state) |> load(), else: put(socket, state)
  end

  defp apply_result(:git_saved, result, socket) do
    state = GitSettings.saved(socket.assigns.git, result)
    if match?({:ok, _}, result), do: socket |> put(state) |> load(), else: put(socket, state)
  end

  defp apply_result(:git_default_saved, :ok, socket), do: load(socket)

  defp apply_result(:git_default_saved, {:error, reason}, socket),
    do: put(socket, %{socket.assigns.git | error: to_string(reason)})

  defp apply_result(:git_deleted, :ok, socket), do: socket |> close() |> load()

  defp apply_result(:git_deleted, {:error, reason}, socket),
    do: put(socket, %{socket.assigns.git | confirm: nil, error: to_string(reason)})

  defp run(socket, kind, fun) do
    {_generation, socket} = Requests.bump(socket, @scope)
    socket = put(socket, %{socket.assigns.git | busy?: kind not in [:git_loaded]})

    Async.run(
      socket,
      kind,
      fn ->
        try do
          fun.()
        rescue
          _ -> {:error, "Git settings operation failed"}
        catch
          :exit, _ -> {:error, "Git settings operation timed out or failed"}
        end
      end,
      scope: @scope
    )
  end

  defp put(socket, state), do: assign(socket, :git, state)

  defp close(socket) do
    {_generation, socket} = Requests.bump(socket, @scope)

    put(socket, %{
      socket.assigns.git
      | form: nil,
        original: nil,
        confirm: nil,
        error: nil
    })
  end
end
