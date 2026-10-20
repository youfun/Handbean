#!/usr/bin/env elixir

repo_root = Path.expand("../..", __DIR__)
mobile_root = Path.expand("..", __DIR__)

for relative <- [
      "lib/handbean/json_safe.ex",
      "lib/handbean/json.ex"
    ] do
  Code.require_file(Path.join(repo_root, relative))
end

mix_shell_source = Path.join(repo_root, "lib/handbean/workspace/mix_shell.ex")
[{Handbean.Workspace.MixShell, mix_shell_beam}] = Code.compile_file(mix_shell_source)

temporary =
  Path.join(System.tmp_dir!(), "handbean-mix-shell-#{System.unique_integer([:positive])}")

beam_path = Path.join(temporary, "Elixir.Handbean.Workspace.MixShell.beam")
File.mkdir_p!(temporary)
File.write!(beam_path, mix_shell_beam)
:code.purge(Handbean.Workspace.MixShell)
:code.delete(Handbean.Workspace.MixShell)

{:module, Handbean.Workspace.MixShell} =
  :code.load_abs(beam_path |> Path.rootname() |> String.to_charlist())

Code.require_file(Path.join(repo_root, "lib/handbean/workspace/mix_toolchain.ex"))

destination = Path.join(repo_root, "priv/mix_toolchain")
mobile_destination = Path.join(mobile_root, "priv/mix_toolchain")

try do
  Handbean.Workspace.MixToolchain.sync_to!(destination)
  File.rm_rf!(mobile_destination)
  File.cp_r!(destination, mobile_destination)

  IO.puts(
    "Packed mobile Mix toolchain with Elixir #{System.version()} / " <>
      "OTP #{:erlang.system_info(:otp_release)}"
  )
after
  File.rm_rf!(temporary)
end
