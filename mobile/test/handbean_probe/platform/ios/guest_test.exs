defmodule HandbeanProbe.Platform.IOS.GuestTest do
  use ExUnit.Case, async: true

  alias HandbeanProbe.Platform.IOS.Guest

  test "an unlinked iOS binary does not pretend the guest can run" do
    assert Guest.exec("echo hi", "/tmp/alpine", 1_000) == {:error, :guest_not_linked}
  end

  test "a blank command is rejected before the native boundary" do
    assert Guest.exec("", "/tmp/alpine", 1_000) == {:error, :invalid_command}
  end

  test "a linked flag without the NIF does not invent a running guest" do
    Application.put_env(:handbean_probe, :ios_guest_linked, true)

    assert Guest.exec("echo hi", "/tmp/alpine", 1_000) == {:error, :guest_not_linked}
  after
    Application.delete_env(:handbean_probe, :ios_guest_linked)
  end
end
