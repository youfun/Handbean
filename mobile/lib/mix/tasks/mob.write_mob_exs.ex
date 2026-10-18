defmodule Mix.Tasks.Mob.WriteMobExs do
  @shortdoc "Write gitignored mob.exs from the checked-in template"
  @moduledoc false

  use Mix.Task

  @template "config/mob.exs.template"
  @dest "mob.exs"

  @impl Mix.Task
  def run(_args) do
    dest = write!()
    Mix.shell().info("#{dest} ready (existing configuration preserved)")
  end

  @doc false
  def template_path, do: Path.expand(@template)

  @doc false
  def dest_path, do: Path.expand(@dest)

  @doc false
  def write! do
    template = template_path()

    unless File.exists?(template) do
      Mix.raise("missing #{@template}")
    end

    dest = dest_path()
    unless File.exists?(dest), do: File.write!(dest, File.read!(template))
    dest
  end
end
