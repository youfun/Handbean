defmodule Handbean.Workspace.MixShell do
  @moduledoc """
  Mix shell that captures output on the process group leader and refuses
  Mix-spawned external commands.

  This is not a sandbox: package or project code can still call `System.cmd/3`.
  """

  @behaviour Mix.Shell

  @impl true
  def print_app, do: :ok

  @impl true
  def info(message), do: IO.puts(message)

  @impl true
  def error(message), do: IO.puts(:stderr, message)

  @impl true
  def prompt(_message) do
    raise "interactive Mix prompts are not supported on this host"
  end

  @impl true
  def yes?(_message), do: false

  @impl true
  def yes?(_message, _opts), do: false

  @impl true
  def cmd(_command) do
    raise "external Mix commands are not supported on this host"
  end

  @impl true
  def cmd(_command, _opts) do
    raise "external Mix commands are not supported on this host"
  end
end
