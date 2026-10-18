defmodule HandbeanProbe.JniStaticInitTest do
  use ExUnit.Case, async: true

  test "BrowserEngine nativeInitClass is a @JvmStatic external" do
    source =
      File.read!(
        Path.expand(
          "../../android/app/src/main/java/com/example/handbean_probe/BrowserEngine.kt",
          __DIR__
        )
      )

    assert source =~ ~r/@JvmStatic\s+private external fun nativeInitClass\(\)/
  end

  test "nativeShareIntakeReady returns before any enif call unless nif_ready" do
    source =
      File.read!(Path.expand("../../c_src/handbean_browser.c", __DIR__))

    assert source =~ ~r/static atomic_bool nif_ready\s*=\s*0/

    {start, _} =
      :binary.match(source, "Java_com_example_handbean_1probe_BrowserEngine_nativeShareIntakeReady")

    chunk = binary_part(source, start, 420)
    assert chunk =~ "if (!atomic_load(&nif_ready)) return;"
    [prefix, _] = String.split(chunk, "if (!atomic_load(&nif_ready)) return;", parts: 2)
    refute prefix =~ "enif_"
  end

  test "browser NIF onload sets nif_ready only after pending mutex exists" do
    source =
      File.read!(Path.expand("../../c_src/handbean_browser.c", __DIR__))

    {start, _} = :binary.match(source, "static int onload(")
    chunk = binary_part(source, start, 520)
    [prefix, _] = String.split(chunk, "atomic_store(&nif_ready, 1)", parts: 2)
    assert prefix =~ "enif_mutex_create"
    refute prefix =~ "atomic_store(&nif_ready"
    assert chunk =~ ~r/if\s*\(\s*!g_pending_lock\s*\)\s*return 1;/
  end

  test "device App loads browser NIF before HomeScreen mount" do
    app = File.read!(Path.expand("../../lib/handbean_probe/app.ex", __DIR__))
    engine = File.read!(Path.expand("../../lib/handbean_probe/browser/engine.ex", __DIR__))
    assert engine =~ "HandbeanProbe.Browser.Nif.ensure_loaded()"
    install = :binary.match(app, "HandbeanProbe.Browser.Engine.install!()")
    mount = :binary.match(app, "Mob.Screen.start_root(HandbeanProbe.HomeScreen)")
    assert install
    assert mount
    assert elem(install, 0) < elem(mount, 0)
  end

  test "MobBridge nativeInitPlatformClass is a @JvmStatic external" do
    source =
      File.read!(
        Path.expand(
          "../../android/app/src/main/java/com/example/handbean_probe/MobBridge.kt",
          __DIR__
        )
      )

    assert source =~ ~r/@JvmStatic\s+private external fun nativeInitPlatformClass\(\)/
  end
end
