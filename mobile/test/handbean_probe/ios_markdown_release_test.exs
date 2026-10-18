defmodule HandbeanProbe.IosMarkdownReleaseTest do
  use ExUnit.Case, async: true

  alias HandbeanProbe.IosMarkdownRelease

  test "splices the markdown overlay into the stock TestFlight script" do
    stock = stock_script()

    patched = IosMarkdownRelease.patch_script(stock)

    assert patched =~ "bash ios/patch_markdown_host.sh"
    assert patched =~ ~S(-c "$BUILD_DIR/MobNode.m")
    assert patched =~ ~S(-c "$BUILD_DIR/mob_nif.m")
    assert patched =~ ~S("${SWIFT_SOURCES[@]}")
    assert patched =~ ~S|SWIFT_SOURCES+=("ios/HandbeanMarkdown.swift")|
    assert patched =~ ~S(SWIFT_BRIDGING="$BUILD_DIR/MobDemo-Bridging-Header.h")
    assert patched =~ ~S(-I "$BUILD_DIR")
    refute patched =~ ~S(-c "$MOB_DIR/ios/MobNode.m")
    assert IosMarkdownRelease.patch_script(patched) == patched
  end

  test "patches the mob_dev generator source without dropping the rest of the script" do
    path = Path.expand("deps/mob_dev/lib/mob_dev/release.ex")

    if File.exists?(path) do
      source = File.read!(path)
      patched = IosMarkdownRelease.patch_generator_source!(source)

      assert patched =~ "defmodule MobDev.Release"
      assert patched =~ "bash ios/patch_markdown_host.sh"
      assert patched =~ "solver-expression-time-threshold=20000"
      assert patched =~ ~S|SWIFT_SOURCES+=("ios/HandbeanMarkdown.swift")|
      assert patched =~ ~S(SWIFT_BRIDGING="$BUILD_DIR/MobDemo-Bridging-Header.h")
      refute patched =~ ~S(-c "$MOB_DIR/ios/mob_nif.m")
      assert IosMarkdownRelease.patch_generator_source!(patched) == patched
      assert {:ok, _} = Code.string_to_quoted(patched)
    else
      flunk("deps/mob_dev/lib/mob_dev/release.ex is required to lock the TestFlight patch")
    end
  end

  defp stock_script do
    ~S"""
    SWIFT_BRIDGING="$MOB_DIR/ios/MobDemo-Bridging-Header.h"

    $CC -fobjc-arc -fmodules $IFLAGS \
        -c "$MOB_DIR/ios/MobNode.m" -o "$BUILD_DIR/MobNode.o"

    xcrun -sdk iphoneos swiftc \
        -import-objc-header "$SWIFT_BRIDGING" \
        -I "$MOB_DIR/ios" \
        "$MOB_DIR"/ios/*.swift \
        -c -o "$BUILD_DIR/swift_mob.o"

    $CC -fobjc-arc -fmodules $IFLAGS \
        -c "$MOB_DIR/ios/mob_nif.m" -o "$BUILD_DIR/mob_nif.o"
    """
  end
end
