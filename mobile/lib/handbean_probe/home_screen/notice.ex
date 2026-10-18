defmodule HandbeanProbe.HomeScreen.Notice do
  @moduledoc """
  The single user-facing message channel of the native shell.

  A notice is `%{kind: kind, text: String.t(), at: ms}` or `nil`. `kind` is
  `:error` for failures, `:info` for confirmations (system UI outcomes), and
  `:share` for the durable "send outcome unknown" banner that survives a
  refresh until the intake is resolved.

  Every writer goes through this module so `HomeScreen` collaborators can
  work on a `%Mob.Socket{}` or on a bare `%{assigns: map}` test socket.
  """

  @type kind :: :error | :info | :share
  @type t :: %{kind: kind(), text: String.t(), at: integer()} | nil

  @spec error(String.t() | nil) :: t()
  def error(nil), do: nil
  def error(text) when is_binary(text), do: new(:error, text)

  @spec info(String.t() | nil, kind()) :: t()
  def info(text, kind \\ :info)
  def info(nil, _kind), do: nil
  def info(text, kind) when is_binary(text), do: new(kind, text)

  @spec text(t()) :: String.t() | nil
  def text(%{text: text}), do: text
  def text(_), do: nil

  @doc "Text only when the notice is an error; the approval dialog shows these."
  @spec error_text(t()) :: String.t() | nil
  def error_text(%{kind: :error, text: text}), do: text
  def error_text(_), do: nil

  @doc "Drop the notice when it is of `kind`; keep anything else."
  @spec clear_kind(t(), kind()) :: t()
  def clear_kind(%{kind: kind}, kind), do: nil
  def clear_kind(notice, _kind), do: notice

  @spec put_error(socket, String.t() | nil) :: socket when socket: term()
  def put_error(socket, text), do: put(socket, error(text))

  @spec put_info(socket, String.t() | nil, kind()) :: socket when socket: term()
  def put_info(socket, text, kind \\ :info), do: put(socket, info(text, kind))

  @spec clear(socket) :: socket when socket: term()
  def clear(socket), do: put(socket, nil)

  @spec put(socket, t()) :: socket when socket: term()
  def put(%Mob.Socket{} = socket, notice), do: Mob.Socket.assign(socket, :notice, notice)

  def put(%{assigns: assigns} = socket, notice),
    do: %{socket | assigns: Map.put(assigns, :notice, notice)}

  defp new(kind, text), do: %{kind: kind, text: text, at: System.system_time(:millisecond)}
end
