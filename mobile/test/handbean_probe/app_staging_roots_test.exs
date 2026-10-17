defmodule HandbeanProbe.AppStagingRootsTest do
  use ExUnit.Case, async: false

  setup do
    previous = Application.get_env(:handbean_probe, :staging_roots)

    on_exit(fn ->
      if previous == nil do
        Application.delete_env(:handbean_probe, :staging_roots)
      else
        Application.put_env(:handbean_probe, :staging_roots, previous)
      end
    end)

    :ok
  end

  test "device runtime configures ErrorTracker before migrations" do
    keys = [:repo, :otp_app, :filter, :enabled]
    previous = Map.new(keys, &{&1, Application.fetch_env(:error_tracker, &1)})

    Enum.each(keys, &Application.delete_env(:error_tracker, &1))

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:error_tracker, key, value)
        {key, :error} -> Application.delete_env(:error_tracker, key)
      end)
    end)

    assert :ok = HandbeanProbe.App.configure_error_tracker!()
    assert Application.fetch_env!(:error_tracker, :repo) == Handbean.Repo
    assert Application.fetch_env!(:error_tracker, :otp_app) == :handbean
    assert Application.fetch_env!(:error_tracker, :filter) == Handbean.ErrorTrackerFilter
    assert Application.fetch_env!(:error_tracker, :enabled)
  end

  test "host env does not invent staging roots" do
    Application.delete_env(:handbean_probe, :staging_roots)
    assert :ok = HandbeanProbe.App.configure_staging_roots!(%{})
    assert Application.get_env(:handbean_probe, :staging_roots) == nil

    assert :ok = HandbeanProbe.App.configure_staging_roots!(%{"MOB_CACHE_DIR" => ""})
    assert Application.get_env(:handbean_probe, :staging_roots) == nil
  end

  test "device MOB_CACHE_DIR maps to cacheDir/controlled_import" do
    cache = Path.join(System.tmp_dir!(), "mob_cache_#{System.unique_integer([:positive])}")
    assert :ok = HandbeanProbe.App.configure_staging_roots!(%{"MOB_CACHE_DIR" => cache})

    assert Application.get_env(:handbean_probe, :staging_roots) == [
             Path.join(cache, "controlled_import")
           ]
  end

  test "packaged model seed initializes supported apps without overwriting existing config" do
    priv = Path.join(System.tmp_dir!(), "priv_#{System.unique_integer([:positive])}")
    File.mkdir_p!(priv)
    seed = Path.join(priv, "models.seed.json")
    body = ~s({"defaultProvider":"stepfun","providers":{}})
    File.write!(seed, body)
    old_seed = System.get_env("HANDBEAN_MODELS_SEED")
    old_models = System.get_env("HANDBEAN_MODELS_FILE")
    System.delete_env("HANDBEAN_MODELS_SEED")

    on_exit(fn ->
      for {key, value} <- [{"HANDBEAN_MODELS_SEED", old_seed}, {"HANDBEAN_MODELS_FILE", old_models}] do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end

      File.rm_rf!(priv)
    end)

    assert :ignored =
             HandbeanProbe.App.maybe_set_models_seed(priv, %{
               "MOB_NODE_SUFFIX" => "other"
             })

    assert System.get_env("HANDBEAN_MODELS_SEED") == nil

    for suffix <- ["foundationtest", "nativechat"] do
      assert :seed = HandbeanProbe.App.maybe_set_models_seed(priv, %{"MOB_NODE_SUFFIX" => suffix})
      assert System.get_env("HANDBEAN_MODELS_SEED") == seed
      target = Path.join(priv, "#{suffix}/models.json")
      System.put_env("HANDBEAN_MODELS_FILE", target)
      assert :ok = Handbean.Agent.ModelConfig.ensure_config()
      assert File.read!(target) == body

      File.write!(target, ~s({"custom":true}))
      assert :ok = Handbean.Agent.ModelConfig.ensure_config()
      assert File.read!(target) == ~s({"custom":true})
    end
  end

  test "device MOB_DATA_DIR maps to filesDir/share_intake" do
    previous_platform = Application.get_env(:handbean_probe, :native_platform)
    HandbeanProbe.NativePlatform.put!(:android)

    on_exit(fn ->
      if previous_platform == nil do
        Application.delete_env(:handbean_probe, :native_platform)
      else
        Application.put_env(:handbean_probe, :native_platform, previous_platform)
      end
    end)

    Application.delete_env(:handbean_probe, :staging_roots)
    data = Path.join(System.tmp_dir!(), "mob_data_#{System.unique_integer([:positive])}")
    assert :ok = HandbeanProbe.App.configure_staging_roots!(%{"MOB_DATA_DIR" => data})
    assert Application.get_env(:handbean_probe, :staging_roots) == [Path.join(data, "share_intake")]
  end

  test "iOS MOB_DATA_DIR also stages photo-picker copies under Caches" do
    previous_platform = Application.get_env(:handbean_probe, :native_platform)
    HandbeanProbe.NativePlatform.put!(:ios)

    on_exit(fn ->
      if previous_platform == nil do
        Application.delete_env(:handbean_probe, :native_platform)
      else
        Application.put_env(:handbean_probe, :native_platform, previous_platform)
      end
    end)

    Application.delete_env(:handbean_probe, :staging_roots)
    data = Path.join(System.tmp_dir!(), "mob_data_#{System.unique_integer([:positive])}")
    assert :ok = HandbeanProbe.App.configure_staging_roots!(%{"MOB_DATA_DIR" => data})

    assert Application.get_env(:handbean_probe, :staging_roots) == [
             Path.join([data, "Caches", "controlled_import"]),
             Path.join(data, "share_intake")
           ]
  end

  test "cacerts_path prefers MOB_BEAMS_DIR priv over Application.app_dir" do
    dir = Path.join(System.tmp_dir!(), "beams_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "priv"))
    pem = Path.join(dir, "priv/cacerts.pem")
    File.write!(pem, "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n")
    previous = System.get_env("MOB_BEAMS_DIR")
    System.put_env("MOB_BEAMS_DIR", dir)

    on_exit(fn ->
      if previous,
        do: System.put_env("MOB_BEAMS_DIR", previous),
        else: System.delete_env("MOB_BEAMS_DIR")

      File.rm_rf!(dir)
    end)

    assert HandbeanProbe.App.cacerts_path() == pem
  end

  test "missing :castore OTP app is treated as a skipped start" do
    # Mirrors the iOS sim flattened -pa layout: CAStore.beam is on the
    # code path but there is no lib/castore-*/ebin.
    assert HandbeanProbe.App.missing_otp_app?(
             {:castore, {~c"no such file or directory", ~c"castore.app"}}
           )

    assert HandbeanProbe.App.missing_otp_app?({:castore, {:error, :not_found}})
    refute HandbeanProbe.App.missing_otp_app?({:castore, :eacces})
  end

  test "iOS MOB_DATA_DIR also maps a controlled_import cache root" do
    previous = Application.get_env(:handbean_probe, :native_platform)
    HandbeanProbe.NativePlatform.put!(:ios)
    Application.delete_env(:handbean_probe, :staging_roots)
    data = Path.join(System.tmp_dir!(), "mob_ios_#{System.unique_integer([:positive])}")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:handbean_probe, :native_platform, previous),
        else: Application.delete_env(:handbean_probe, :native_platform)
    end)

    assert :ok = HandbeanProbe.App.configure_staging_roots!(%{"MOB_DATA_DIR" => data})

    assert Application.get_env(:handbean_probe, :staging_roots) == [
             Path.join([data, "Caches", "controlled_import"]),
             Path.join(data, "share_intake")
           ]
  end
end
