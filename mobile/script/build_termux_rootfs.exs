#!/usr/bin/env elixir

alias Handbean.JSON

repo = "https://packages.termux.dev/apt/termux-main"
index_path = "dists/stable/main/binary-aarch64/Packages"
release_index_path = "main/binary-aarch64/Packages"
lock_path = Path.expand("config/termux-rootfs.lock.json")
key_path = Path.expand("config/termux-autobuilds.asc")
assets_dir = Path.expand("android/app/src/developerSideload/assets")
build_dir = Path.expand(".build/termux-rootfs")
source_prefix = "/data/data/com.termux/files/usr"
target_prefix = "/data/data/io.hndbean/files/usr"
signing_fingerprint = "CC72CF8BA7DBFA0182877D045A897D96E57CF20C"

roots = [
  "bash",
  "coreutils",
  "elixir",
  "erlang",
  "findutils",
  "gawk",
  "git",
  "grep",
  "nodejs-lts",
  "openssh",
  "python",
  "sed",
  "termux-exec",
  "termux-tools"
]

defmodule TermuxRootfs do
  def run!(command, args, opts \\ []) do
    case System.cmd(command, args, Keyword.merge([stderr_to_stdout: true], opts)) do
      {output, 0} -> output
      {output, status} -> raise "#{command} failed (#{status}):\n#{output}"
    end
  end

  def sha256!(path) do
    path
    |> File.stream!(1_048_576, [])
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  def fetch!(url, destination) do
    File.mkdir_p!(Path.dirname(destination))

    run!("curl", [
      "--fail",
      "--location",
      "--proto",
      "=https",
      "--tlsv1.2",
      "--output",
      destination,
      url
    ])

    destination
  end

  def valid_signature_status?(status, pinned_fingerprint) do
    valid_signatures =
      status
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.starts_with?(&1, "[GNUPG:] VALIDSIG "))
      |> Enum.map(&String.split/1)

    case valid_signatures do
      [["[GNUPG:]", "VALIDSIG", signer | fields]] ->
        signer == pinned_fingerprint or List.last(fields) == pinned_fingerprint

      _ ->
        false
    end
  end

  def release_sha256!(inrelease, path) do
    section =
      case String.split(inrelease, "\nSHA256:\n", parts: 2) do
        [_, rest] -> rest |> String.split("\nSHA512:\n", parts: 2) |> hd()
        _ -> raise "signed release has no SHA256 section"
      end

    escaped = Regex.escape(path)

    case Regex.run(~r/^ ([0-9a-f]{64}) +\d+ #{escaped}$/m, section, capture: :all_but_first) do
      [sha256] -> sha256
      _ -> raise "signed release does not authenticate #{path}"
    end
  end

  def parse_packages(text) do
    text
    |> String.split(~r/\n\s*\n/, trim: true)
    |> Enum.map(&parse_paragraph/1)
    |> Enum.filter(&(&1["Package"] && &1["Filename"] && &1["SHA256"]))
  end

  defp parse_paragraph(paragraph) do
    paragraph
    |> String.split("\n")
    |> Enum.reduce({%{}, nil}, fn line, {fields, current} ->
      cond do
        String.starts_with?(line, [" ", "\t"]) and current ->
          {Map.update!(fields, current, &(&1 <> "\n" <> String.trim_leading(line))), current}

        true ->
          case String.split(line, ":", parts: 2) do
            [key, value] -> {Map.put(fields, key, String.trim(value)), key}
            _ -> {fields, current}
          end
      end
    end)
    |> elem(0)
  end

  def resolve!(packages, roots) do
    by_name = Map.new(packages, &{&1["Package"], &1})

    providers =
      Enum.reduce(packages, %{}, fn package, acc ->
        package
        |> Map.get("Provides", "")
        |> dependency_groups()
        |> List.flatten()
        |> Enum.reduce(acc, &Map.put_new(&2, &1, package["Package"]))
      end)

    {_seen, ordered} =
      Enum.reduce(roots, {MapSet.new(), []}, fn root, state ->
        resolve_package!(root, by_name, providers, state, [])
      end)

    Enum.reverse(ordered)
  end

  defp resolve_package!(name, by_name, providers, {seen, ordered}, stack) do
    actual = if Map.has_key?(by_name, name), do: name, else: providers[name]

    cond do
      is_nil(actual) ->
        raise "Termux dependency not found: #{name} (from #{Enum.join(Enum.reverse(stack), " -> ")})"

      MapSet.member?(seen, actual) ->
        {seen, ordered}

      true ->
        package = Map.fetch!(by_name, actual)
        seen = MapSet.put(seen, actual)

        dependencies =
          [package["Pre-Depends"], package["Depends"]]
          |> Enum.reject(&is_nil/1)
          |> Enum.flat_map(&dependency_groups/1)

        {seen, ordered} =
          Enum.reduce(dependencies, {seen, ordered}, fn alternatives, state ->
            selected =
              Enum.find(alternatives, fn candidate ->
                Map.has_key?(by_name, candidate) or Map.has_key?(providers, candidate)
              end)

            if selected,
              do: resolve_package!(selected, by_name, providers, state, [actual | stack]),
              else:
                raise(
                  "no available alternative for #{inspect(alternatives)} required by #{actual}"
                )
          end)

        {seen, [package | ordered]}
    end
  end

  def dependency_groups(nil), do: []
  def dependency_groups(""), do: []

  def dependency_groups(raw) do
    raw
    |> String.replace(~r/\[[^\]]+\]/, "")
    |> String.replace(~r/<[^>]+>/, "")
    |> String.split(",", trim: true)
    |> Enum.map(fn group ->
      group
      |> String.split("|", trim: true)
      |> Enum.map(fn alternative ->
        alternative
        |> String.replace(~r/\s*\([^)]*\)/, "")
        |> String.trim()
        |> String.replace(~r/:(any|native)$/, "")
      end)
      |> Enum.reject(&(&1 == ""))
    end)
  end

  def lock_package(package) do
    %{
      "name" => package["Package"],
      "version" => package["Version"],
      "architecture" => package["Architecture"],
      "filename" => package["Filename"],
      "sha256" => String.downcase(package["SHA256"]),
      "download_size" => parse_integer(package["Size"]),
      "installed_size_kib" => parse_integer(package["Installed-Size"]),
      "homepage" => package["Homepage"],
      "description" => package["Description"],
      "depends" => package["Depends"],
      "pre_depends" => package["Pre-Depends"]
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp parse_integer(nil), do: nil

  defp parse_integer(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  def extract_deb!(deb, destination, scratch) do
    case System.find_executable("dpkg-deb") do
      path when is_binary(path) ->
        run!(path, ["--extract", deb, destination])

      nil ->
        # macOS bsdtar understands the outer ar container. Extract the data member,
        # then unpack it without ever running maintainer scripts.
        File.rm_rf!(scratch)
        File.mkdir_p!(scratch)
        tar = System.find_executable("tar") || raise "tar or dpkg-deb is required"
        version = run!(tar, ["--version"])
        unless version =~ "bsdtar", do: raise("dpkg-deb is required when tar is not bsdtar")
        run!(tar, ["-xf", deb, "-C", scratch])

        data =
          Path.wildcard(Path.join(scratch, "data.tar*"))
          |> Enum.find(&File.regular?/1)
          |> case do
            nil -> raise "#{deb} has no data archive"
            archive -> archive
          end

        run!(tar, ["-xf", data, "-C", destination])
    end
  end

  def relocate_prefix!(root, source, target) when byte_size(source) == byte_size(target) do
    paths = root |> Path.join("**/*") |> Path.wildcard(match_dot: true)

    Enum.each(paths, fn path ->
      case File.lstat(path) do
        {:ok, %File.Stat{type: :regular}} ->
          content = File.read!(path)
          relocated = :binary.replace(content, source, target, [:global])
          if relocated != content, do: File.write!(path, relocated)

        {:ok, %File.Stat{type: :symlink}} ->
          {:ok, link} = File.read_link(path)
          relocated = String.replace(link, source, target)

          if relocated != link do
            File.rm!(path)
            File.ln_s!(relocated, path)
          end

        _ ->
          :ok
      end
    end)

    residual =
      Enum.find(paths, fn path ->
        case File.lstat(path) do
          {:ok, %File.Stat{type: :regular}} ->
            :binary.match(File.read!(path), source) != :nomatch

          {:ok, %File.Stat{type: :symlink}} ->
            {:ok, link} = File.read_link(path)
            String.contains?(link, source)

          _ ->
            false
        end
      end)

    if residual, do: raise("relocation left #{inspect(source)} in #{residual}")
  end

  def license_files(root, package_name) do
    candidates = [
      Path.join([root, "share/doc", package_name, "copyright"]),
      Path.join([root, "share/doc", package_name, "LICENSE"]),
      Path.join([root, "share/licenses", package_name, "*"])
    ]

    candidates
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, root))
    |> Enum.sort()
  end
end

case System.argv() do
  ["--update-lock"] ->
    File.mkdir_p!(build_dir)
    inrelease_file = Path.join(build_dir, "InRelease")
    gpg_home = Path.join(build_dir, "gnupg")
    File.rm_rf!(gpg_home)
    File.mkdir_p!(gpg_home)
    File.chmod!(gpg_home, 0o700)
    TermuxRootfs.fetch!("#{repo}/dists/stable/InRelease", inrelease_file)

    TermuxRootfs.run!("gpg", [
      "--batch",
      "--no-options",
      "--homedir",
      gpg_home,
      "--import",
      key_path
    ])

    key_listing =
      TermuxRootfs.run!("gpg", [
        "--batch",
        "--no-options",
        "--homedir",
        gpg_home,
        "--with-colons",
        "--list-keys"
      ])

    primary_keys = Regex.scan(~r/^pub:/m, key_listing)

    fingerprints =
      Regex.scan(~r/^fpr:::::::::([0-9A-F]+):$/m, key_listing, capture: :all_but_first)

    unless length(primary_keys) == 1 and List.first(fingerprints) == [signing_fingerprint],
      do: raise("pinned Termux signing key has an unexpected fingerprint")

    authenticated_release_file = Path.join(build_dir, "Release.authenticated")
    signature_status_file = Path.join(build_dir, "Release.status")
    File.rm(authenticated_release_file)
    File.rm(signature_status_file)

    TermuxRootfs.run!("gpg", [
      "--batch",
      "--no-options",
      "--homedir",
      gpg_home,
      "--status-file",
      signature_status_file,
      "--output",
      authenticated_release_file,
      "--decrypt",
      inrelease_file
    ])

    signature_status = File.read!(signature_status_file)

    unless TermuxRootfs.valid_signature_status?(signature_status, signing_fingerprint),
      do: raise("Termux release does not have a valid signature from the pinned key")

    index_file = Path.join(build_dir, "Packages")
    TermuxRootfs.fetch!("#{repo}/#{index_path}", index_file)
    index_sha = TermuxRootfs.sha256!(index_file)

    signed_index_sha =
      authenticated_release_file
      |> File.read!()
      |> TermuxRootfs.release_sha256!(release_index_path)

    unless index_sha == signed_index_sha,
      do: raise("package index does not match the authenticated release")

    packages = index_file |> File.read!() |> TermuxRootfs.parse_packages()
    selected = TermuxRootfs.resolve!(packages, roots)

    lock = %{
      "lock_version" => 1,
      "repository" => repo,
      "index_path" => index_path,
      "index_sha256" => index_sha,
      "inrelease_sha256" => TermuxRootfs.sha256!(inrelease_file),
      "signing_fingerprint" => signing_fingerprint,
      "abi" => "arm64-v8a",
      "source_prefix" => source_prefix,
      "target_prefix" => target_prefix,
      "source_application_id" => "com.termux",
      "target_application_id" => "io.hndbean",
      "roots" => roots,
      "packages" => Enum.map(selected, &TermuxRootfs.lock_package/1)
    }

    File.write!(lock_path, JSON.encode!(lock, pretty: true) <> "\n")
    IO.puts("Wrote #{lock_path} with #{length(selected)} pinned packages")

  [] ->
    lock = lock_path |> File.read!() |> JSON.decode!()
    unless lock["lock_version"] == 1, do: raise("unsupported lock version")
    unless lock["abi"] == "arm64-v8a", do: raise("lock is not ARM64")
    unless lock["repository"] == repo, do: raise("unexpected repository")

    unless lock["inrelease_sha256"] =~ ~r/\A[0-9a-f]{64}\z/ and
             lock["signing_fingerprint"] == signing_fingerprint,
           do: raise("lock has no authenticated release provenance")

    unless lock["source_prefix"] == source_prefix and lock["target_prefix"] == target_prefix,
      do: raise("lock prefix contract does not match this builder")

    unless lock["source_application_id"] == "com.termux" and
             lock["target_application_id"] == "io.hndbean",
           do: raise("lock application id contract does not match this builder")

    download_dir = Path.join(build_dir, "downloads")
    staging = Path.join(build_dir, "staging")
    scratch = Path.join(build_dir, "deb")
    File.rm_rf!(staging)
    File.mkdir_p!(staging)

    Enum.each(lock["packages"], fn package ->
      filename = package["filename"]

      unless String.starts_with?(filename, "pool/") and ".." not in Path.split(filename),
        do: raise("unsafe package filename: #{inspect(filename)}")

      deb = Path.join(download_dir, Path.basename(filename))

      unless File.regular?(deb) and TermuxRootfs.sha256!(deb) == package["sha256"] do
        File.rm(deb)
        TermuxRootfs.fetch!("#{repo}/#{filename}", deb)
      end

      actual = TermuxRootfs.sha256!(deb)
      unless actual == package["sha256"], do: raise("SHA-256 mismatch for #{package["name"]}")
      IO.puts("Extracting #{package["name"]} #{package["version"]}")
      TermuxRootfs.extract_deb!(deb, staging, scratch)
    end)

    packaged_usr = Path.join(staging, "data/data/com.termux/files/usr")

    unless File.dir?(packaged_usr),
      do: raise("packages did not produce the expected Termux prefix")

    TermuxRootfs.relocate_prefix!(packaged_usr, source_prefix, target_prefix)
    TermuxRootfs.relocate_prefix!(packaged_usr, "com.termux", "io.hndbean")

    required = [
      "bin/bash",
      "bin/elixir",
      "bin/erl",
      "bin/iex",
      "bin/mix",
      "bin/node",
      "lib/libtermux-exec.so"
    ]

    Enum.each(required, fn relative ->
      unless File.exists?(Path.join(packaged_usr, relative)),
        do: raise("rootfs missing #{relative}")
    end)

    unless File.exists?(Path.join(packaged_usr, "bin/python")) or
             File.exists?(Path.join(packaged_usr, "bin/python3")),
           do: raise("rootfs missing Python")

    File.mkdir_p!(assets_dir)
    archive_path = Path.join(assets_dir, "termux-rootfs.tgz")
    File.rm(archive_path)

    python =
      System.find_executable("python3") || raise "python3 is required to archive the rootfs"

    TermuxRootfs.run!(python, [
      Path.expand("script/create_deterministic_tar.py"),
      packaged_usr,
      archive_path
    ])

    package_manifest = %{
      "repository" => repo,
      "index_sha256" => lock["index_sha256"],
      "license_review_required" => false,
      "packages" =>
        Enum.map(lock["packages"], fn package ->
          Map.put(
            package,
            "license_files",
            TermuxRootfs.license_files(packaged_usr, package["name"])
          )
        end)
    }

    package_manifest_path = Path.join(assets_dir, "termux-packages.json")

    File.write!(
      package_manifest_path,
      JSON.encode!(package_manifest, pretty: true) <> "\n"
    )

    archive_sha = TermuxRootfs.sha256!(archive_path)

    rootfs_manifest = %{
      "version" => String.slice(lock["index_sha256"], 0, 16),
      "archive_sha256" => archive_sha,
      "abi" => "arm64-v8a",
      "prefix" => target_prefix,
      "package_lock_sha256" => TermuxRootfs.sha256!(lock_path),
      "package_manifest_sha256" => TermuxRootfs.sha256!(package_manifest_path)
    }

    File.write!(
      Path.join(assets_dir, "termux-rootfs.json"),
      JSON.encode!(rootfs_manifest, pretty: true) <> "\n"
    )

    IO.puts("Built #{archive_path}")
    IO.puts("SHA-256 #{archive_sha}")

  _ ->
    raise "usage: mix run --no-start script/build_termux_rootfs.exs [--update-lock]"
end
