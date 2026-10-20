defmodule HandbeanProbe.TermuxRootfsLockTest do
  use ExUnit.Case, async: true

  @lock Path.expand("../../config/termux-rootfs.lock.json", __DIR__)

  test "developer rootfs lock pins every recursively resolved package" do
    lock = @lock |> File.read!() |> Handbean.JSON.decode!()
    packages = lock["packages"]
    names = Enum.map(packages, & &1["name"])

    assert lock["lock_version"] == 1
    assert lock["abi"] == "arm64-v8a"
    assert lock["repository"] == "https://packages.termux.dev/apt/termux-main"
    assert lock["index_sha256"] =~ ~r/\A[0-9a-f]{64}\z/
    assert lock["inrelease_sha256"] =~ ~r/\A[0-9a-f]{64}\z/
    assert lock["signing_fingerprint"] == "CC72CF8BA7DBFA0182877D045A897D96E57CF20C"
    assert lock["source_prefix"] == "/data/data/com.termux/files/usr"
    assert lock["target_prefix"] == "/data/data/io.hndbean/files/usr"
    assert byte_size(lock["source_prefix"]) == byte_size(lock["target_prefix"])
    assert lock["source_application_id"] == "com.termux"
    assert lock["target_application_id"] == "io.hndbean"
    assert byte_size(lock["source_application_id"]) == byte_size(lock["target_application_id"])
    assert Enum.uniq(names) == names
    assert Enum.all?(lock["roots"], &(&1 in names))

    assert Enum.all?(packages, fn package ->
             is_binary(package["version"]) and package["version"] != "" and
               String.starts_with?(package["filename"], "pool/") and
               package["sha256"] =~ ~r/\A[0-9a-f]{64}\z/ and
               is_integer(package["download_size"]) and package["download_size"] > 0
           end)
  end

  test "runtime roots include the promised languages and command environment shim" do
    lock = @lock |> File.read!() |> Handbean.JSON.decode!()

    for package <- ~w(bash elixir erlang git nodejs-lts openssh python termux-exec termux-tools) do
      assert package in lock["roots"]
    end
  end

  test "developer rootfs pins a complete Elixir and Erlang CLI" do
    lock = @lock |> File.read!() |> Handbean.JSON.decode!()
    packages = Map.new(lock["packages"], &{&1["name"], &1})

    assert packages["elixir"]["version"] =~ ~r/^1\.20\./
    assert packages["erlang"]["version"] =~ ~r/^29\./
  end
end
