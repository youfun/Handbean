#!/usr/bin/env elixir

[target, release_dir] =
  case System.argv() do
    [target, release_dir] -> [target, Path.expand(release_dir)]
    _ -> raise "usage: elixir scripts/package_browser_runtime.exs TARGET RELEASE_DIR"
  end

root = Path.expand("..", __DIR__)
version_file = Path.join(root, "version.properties")

version =
  version_file
  |> File.read!()
  |> String.split("\n", trim: true)
  |> Enum.find_value(fn line ->
    case String.split(line, "=", parts: 2) do
      ["version", version] -> String.trim(version)
      _ -> nil
    end
  end)

if is_nil(version), do: raise("missing version in #{version_file}")

{source_name, destination_name} =
  case target do
    "linux-x86_64" -> {"agent-browser-linux-x64", "agent-browser"}
    "linux-arm64" -> {"agent-browser-linux-arm64", "agent-browser"}
    "macos-arm64" -> {"agent-browser-darwin-arm64", "agent-browser"}
    "windows-amd64" -> {"agent-browser-win32-x64.exe", "agent-browser.exe"}
    other -> raise "unsupported browser runtime target: #{other}"
  end

package_dir = Path.join([root, "node_modules", "agent-browser"])
package_json = File.read!(Path.join(package_dir, "package.json"))
root_package_json = File.read!(Path.join(root, "package.json"))

package_version =
  case Regex.run(~r/"version"\s*:\s*"([^"]+)"/, package_json) do
    [_, version] -> version
    _ -> raise "agent-browser package has no version"
  end

pinned_version =
  case Regex.run(~r/"agent-browser"\s*:\s*"([^"]+)"/, root_package_json) do
    [_, version] -> version
    _ -> raise "package.json does not pin agent-browser"
  end

unless package_version == pinned_version,
  do: raise("agent-browser package #{package_version} does not match pin #{pinned_version}")

source_binary = Path.join([package_dir, "bin", source_name])
priv_dir = Path.join([release_dir, "lib", "handbean-#{version}", "priv"])
runtime_dir = Path.join(priv_dir, "browser-runtime")
destination_binary = Path.join(runtime_dir, destination_name)

unless File.regular?(source_binary),
  do: raise("agent-browser #{source_name} is missing; run npm ci before packaging")

unless File.dir?(priv_dir),
  do: raise("Handbean release priv directory is missing: #{priv_dir}")

File.rm_rf!(runtime_dir)
File.mkdir_p!(runtime_dir)
File.cp!(source_binary, destination_binary)

unless String.ends_with?(destination_name, ".exe"),
  do: File.chmod!(destination_binary, 0o755)

license_dir = Path.join(runtime_dir, "licenses")
File.mkdir_p!(license_dir)

for {source, destination} <- [
      {"LICENSE", "LICENSE-agent-browser"},
      {"cli/src/native/a11y/LICENSE-axe-core.txt", "LICENSE-axe-core"},
      {"cli/src/native/a11y/LICENSE-axe-core-THIRD-PARTY.txt", "LICENSE-axe-core-THIRD-PARTY"}
    ] do
  source_path = Path.join(package_dir, source)

  unless File.regular?(source_path),
    do: raise("agent-browser license file is missing: #{source_path}")

  File.cp!(source_path, Path.join(license_dir, destination))
end

{version_output, exit_status} =
  System.cmd(destination_binary, ["--version"], stderr_to_stdout: true)

unless exit_status == 0 and
         String.trim(version_output) == "agent-browser #{pinned_version}" do
  raise "bundled agent-browser verification failed: #{inspect({exit_status, version_output})}"
end

extension_source = Path.join([root, "desktop", "chrome-extension"])
extension_destination = Path.join(priv_dir, "chrome-extension")

unless File.regular?(Path.join(extension_source, "manifest.json")),
  do: raise("Chrome extension source is missing: #{extension_source}")

File.rm_rf!(extension_destination)
File.cp_r!(extension_source, extension_destination)

IO.puts("Bundled #{String.trim(version_output)} and the unpacked Chrome extension for #{target}")
