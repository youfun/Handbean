defmodule HandbeanProbe.ModelSettingsTest do
  use ExUnit.Case, async: false
  use Gettext, backend: HandbeanProbe.Gettext

  alias Handbean.Agent.ModelConfig
  alias Handbean.Settings.ModelAISettings
  alias Handbean.Settings.ModelCatalog
  alias HandbeanProbe.ModelSettings

  setup do
    dir = Path.join(System.tmp_dir!(), "native_settings_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    host = Application.get_env(:handbean, :host)
    Handbean.Host.put!(%{data_dir: dir, shell: false, mcp: false})

    vars = %{
      "HANDBEAN_WORKSPACE" => Path.join(dir, "workspace_a"),
      "HANDBEAN_MODELS_FILE" => Path.join(dir, "models.json"),
      "HANDBEAN_WORKSPACES_FILE" => Path.join(dir, "workspaces.json"),
      "HANDBEAN_GLOBAL_SETTINGS_FILE" => Path.join(dir, "settings.json")
    }

    previous = Map.new(vars, fn {key, _} -> {key, System.get_env(key)} end)
    Enum.each(vars, fn {key, value} -> System.put_env(key, value) end)

    {:ok, ws_a} = Handbean.WorkspaceStore.ensure_default!()
    path_b = Path.join(dir, "workspace_b")
    File.mkdir_p!(path_b)
    {:ok, ws_b} = Handbean.WorkspaceStore.add(path_b, name: "B")

    on_exit(fn ->
      if host,
        do: Application.put_env(:handbean, :host, host),
        else: Application.delete_env(:handbean, :host)

      Enum.each(previous, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)

      File.rm_rf!(dir)
    end)

    %{dir: dir, ws_a: ws_a, ws_b: ws_b}
  end

  test "saves context window and max tokens without dropping unknown fields or keys", %{ws_a: ws} do
    state = add_model(ws, "alpha", "one", "https://alpha.example/v1")
    state = ModelSettings.change(state, :context_window, "64000")
    state = ModelSettings.change(state, :max_tokens, "2048")
    state = ModelSettings.action(:save_model, state, ws)
    assert state.notice == gettext("Model saved")

    config = read_models()
    model = hd(config["providers"]["alpha"]["models"])
    assert model["contextWindow"] == 64_000
    assert model["maxTokens"] == 2048
    assert config["providers"]["alpha"]["apiKey"] == "fixture-key-not-real"

    {:ok, resolved} = ModelCatalog.request_max_tokens(ws["path"], "alpha/one")
    assert resolved == 2048

    state = ModelSettings.action({:edit_model, "alpha", "one"}, state, ws)
    state = ModelSettings.change(state, :name, "Renamed")
    update_model_raw("alpha", "one", %{"cost" => %{"input" => 1}, "extra" => "keep"})
    state = ModelSettings.action(:save_model, state, ws)
    assert state.confirm == nil
    model = read_models()["providers"]["alpha"]["models"] |> hd()
    assert model["name"] == "Renamed"
    assert model["cost"] == %{"input" => 1}
    assert model["extra"] == "keep"
    assert model["contextWindow"] == 64_000
    assert read_models()["providers"]["alpha"]["apiKey"] == "fixture-key-not-real"
    state = ModelSettings.action({:edit_model, "alpha", "one"}, state, ws)
    refute Map.has_key?(state.form, :api_key)
    state = ModelSettings.action({:edit_provider, "alpha"}, state, ws)
    assert state.form.api_key == ""
    assert state.form.key_status == :configured
  end

  test "provider maxTokens overrides model maxTokens in request config", %{ws_a: ws} do
    state = save_named(ws, "alpha", "one")
    state = ModelSettings.action({:edit_model, "alpha", "one"}, state, ws)
    state = ModelSettings.change(state, :max_tokens, "1111")
    state = ModelSettings.action(:save_model, state, ws)
    state = ModelSettings.action({:edit_provider, "alpha"}, state, ws)
    state = ModelSettings.change(state, :provider_max_tokens, "2222")
    state = ModelSettings.action(:save_provider, state, ws)
    assert state.confirm == nil
    {:ok, resolved} = ModelCatalog.request_max_tokens(ws["path"], "alpha/one")
    assert resolved == 2222

    state = save_named(ws, "alpha", "two")
    state = ModelSettings.action({:edit_model, "alpha", "two"}, state, ws)
    state = ModelSettings.change(state, :max_tokens, "3333")
    state = ModelSettings.action(:save_model, state, ws)
    assert state.confirm == nil
    assert read_models()["providers"]["alpha"]["maxTokens"] == 2222
    {:ok, second} = ModelCatalog.request_max_tokens(ws["path"], "alpha/two")
    assert second == 2222
  end

  test "rejects invalid token fields and keeps the form", %{ws_a: ws} do
    state = add_model(ws, "alpha", "one", "https://alpha.example/v1")

    rejected =
      ModelSettings.action(:save_model, ModelSettings.change(state, :max_tokens, "0"), ws)

    assert rejected.form.max_tokens == "0"
    assert read_models()["providers"]["alpha"]["models"] == []

    rejected =
      ModelSettings.action(:save_model, ModelSettings.change(state, :context_window, "-5"), ws)

    assert rejected.notice
    assert read_models()["providers"]["alpha"]["models"] == []

    rejected =
      ModelSettings.action(:save_model, ModelSettings.change(state, :max_tokens, "abc"), ws)

    assert rejected.form.model == "one"
    assert read_models()["providers"]["alpha"]["models"] == []
  end

  test "delete without refs writes; referenced delete needs replacement; cancel does not write",
       %{
         ws_a: ws_a,
         ws_b: ws_b
       } do
    save_named(ws_a, "alpha", "one")
    save_named(ws_a, "alpha", "spare")
    save_named(ws_a, "beta", "two")
    save_named(ws_a, "beta", "spare")

    state = ModelSettings.action({:scope, :global}, ModelSettings.load(ws_a), ws_a)
    state = ModelSettings.action({:default_model, "alpha/one"}, state, ws_a)
    state = ModelSettings.action({:scope, :workspace}, ModelSettings.load(ws_b), ws_b)
    state = ModelSettings.action({:default_model, "alpha/one"}, state, ws_b)

    state =
      ModelSettings.action({:ask_delete_model, "beta", "two"}, ModelSettings.load(ws_a), ws_a)

    assert state.confirm.refs == []
    state = ModelSettings.action(:cancel_confirm, state, ws_a)
    assert Enum.any?(read_models()["providers"]["beta"]["models"], &(&1["id"] == "two"))

    state =
      ModelSettings.action({:ask_delete_model, "beta", "two"}, ModelSettings.load(ws_a), ws_a)

    state = ModelSettings.action(:confirm_delete, state, ws_a)
    refute Enum.any?(read_models()["providers"]["beta"]["models"] || [], &(&1["id"] == "two"))
    save_named(ws_a, "beta", "two")

    state =
      ModelSettings.action({:ask_delete_model, "alpha", "one"}, ModelSettings.load(ws_a), ws_a)

    assert state.confirm.refs != []
    cancelled = ModelSettings.action(:cancel_confirm, state, ws_a)
    assert Enum.any?(read_models()["providers"]["alpha"]["models"], &(&1["id"] == "one"))
    assert cancelled.confirm == nil

    blocked = ModelSettings.action(:confirm_delete, state, ws_a)
    assert blocked.notice
    assert Enum.any?(read_models()["providers"]["alpha"]["models"], &(&1["id"] == "one"))

    state = ModelSettings.action({:replacement, "beta/two"}, state, ws_a)
    state = ModelSettings.action(:confirm_delete, state, ws_a)
    refute Enum.any?(read_models()["providers"]["alpha"]["models"] || [], &(&1["id"] == "one"))
    assert Handbean.Settings.global_model_ai().default_model == "beta/two"
    assert Handbean.Settings.effective_model_ai(ws_b["path"]).default_model == "beta/two"
    assert Handbean.Settings.effective_model_ai(ws_a["path"]).default_model == "beta/two"
  end

  test "workspace inherit removes overrides and does not copy effective values", %{
    ws_a: ws_a,
    ws_b: ws_b
  } do
    save_named(ws_a, "alpha", "one")
    save_named(ws_a, "beta", "two")

    state = ModelSettings.action({:scope, :global}, ModelSettings.load(ws_a), ws_a)
    state = ModelSettings.action({:default_model, ""}, state, ws_a)
    assert Handbean.Settings.global_model_ai().default_model == nil

    state = ModelSettings.action({:default_model, "alpha/one"}, state, ws_a)
    state = ModelSettings.action({:reasoning, "high"}, state, ws_a)
    assert Handbean.Settings.global_model_ai().default_model == "alpha/one"

    state = ModelSettings.action({:scope, :workspace}, ModelSettings.load(ws_a), ws_a)
    state = ModelSettings.action({:default_model, "beta/two"}, state, ws_a)
    state = ModelSettings.action({:reasoning, "low"}, state, ws_a)

    {:ok, raw_a} = Handbean.Settings.load_workspace_model_ai(ws_a["path"])
    assert raw_a["default_model"] == "beta/two"

    state = ModelSettings.action({:inherit, :default_model}, state, ws_a)
    {:ok, raw_a} = Handbean.Settings.load_workspace_model_ai(ws_a["path"])
    refute Map.has_key?(ModelAISettings.normalize_override(raw_a), :default_model)
    assert raw_a["reasoning"] == "low"
    assert Handbean.Settings.effective_model_ai(ws_a["path"]).default_model == "alpha/one"

    state = ModelSettings.action(:inherit_all, state, ws_a)
    {:ok, raw_a} = Handbean.Settings.load_workspace_model_ai(ws_a["path"])
    assert raw_a == %{}
    assert Handbean.Settings.effective_model_ai(ws_a["path"]).reasoning == "high"

    state = ModelSettings.action({:reasoning, "minimal"}, ModelSettings.load(ws_b), ws_b)
    assert Handbean.Settings.effective_model_ai(ws_b["path"]).reasoning == "minimal"
    assert Handbean.Settings.effective_model_ai(ws_a["path"]).reasoning == "high"
  end

  test "memory reflection toggle persists and enters runtime opts", %{ws_a: ws} do
    save_named(ws, "alpha", "one")
    state = ModelSettings.action({:scope, :global}, ModelSettings.load(ws), ws)
    state = ModelSettings.action({:om_model, "alpha/one"}, state, ws)

    tree = ModelSettings.render(state)
    blob = flatten_text(tree)
    assert blob =~ gettext("Memory Reflection")
    assert blob =~ gettext("Compaction can produce reviewable memory candidates")
    refute blob =~ "Observational memory"
    refute blob =~ "Recent context limit"

    toggle = find_type(tree, :toggle, "toggle-memory-reflection")
    assert toggle.props.label == gettext("Enable memory reflection")
    refute toggle.props.value
    assert tap_change?(tree, {:model_field, :om_reflector_enabled})

    state = ModelSettings.change(state, :om_reflector_enabled, true)
    state = ModelSettings.action(:save_memory_details, state, ws)

    settings = Handbean.Settings.effective_model_ai(ws["path"])
    opts = ModelAISettings.to_runtime_opts(settings)
    assert opts[:om][:reflector_enabled]
    assert opts[:om][:model] == "alpha/one"
    refute Map.has_key?(opts[:om], :enabled)

    for removed <- ~w(max_recent_context message_tokens buffer_tokens observation_tokens)a do
      refute Map.has_key?(opts[:om], removed)
    end

    {:ok, global} = Handbean.Settings.load_global()
    assert get_in(global, ["model_ai", "observational_memory", "reflector_enabled"]) == true
    refute inspect(opts) =~ "Follow"
  end

  test "allowlist unconfigured, empty, and restricted behave as backend documents", %{
    ws_a: ws_a,
    ws_b: ws_b
  } do
    save_named(ws_a, "alpha", "one")
    save_named(ws_a, "beta", "two")

    settings_path = Handbean.WorkspaceSettings.path(ws_a["path"])
    {:ok, existing} = Handbean.WorkspaceSettings.load(ws_a["path"])
    File.write!(settings_path, Jason.encode!(Map.delete(existing, "models")))
    assert ModelConfig.load_workspace_policy(ws_a["path"]) == :unrestricted

    assert Enum.map(ModelConfig.available_models_for_workspace(ws_a["path"]), & &1.id)
           |> Enum.sort() ==
             ["alpha/one", "beta/two"]

    :ok =
      Handbean.WorkspaceSettings.write_policy(ws_a["path"], %{"allow" => %{"providers" => %{}}})

    assert {:ok, policy} = ModelConfig.load_workspace_policy(ws_a["path"])
    assert policy["allow"]["providers"] == %{}

    assert Enum.map(ModelConfig.available_models_for_workspace(ws_a["path"]), & &1.id)
           |> Enum.sort() ==
             ["alpha/one", "beta/two"]

    state = ModelSettings.load(ws_a)
    state = ModelSettings.action({:policy_mode, :restricted}, state, ws_a)
    state = ModelSettings.action({:toggle_policy_model, "alpha", "one"}, state, ws_a)
    state = ModelSettings.action({:policy_default, "alpha/one"}, state, ws_a)
    state = ModelSettings.action(:save_policy, state, ws_a)

    assert Enum.map(ModelConfig.available_models_for_workspace(ws_a["path"]), & &1.id) == [
             "alpha/one"
           ]

    assert ModelConfig.available_models_for_workspace(ws_b["path"])
           |> Enum.map(& &1.id)
           |> Enum.sort() ==
             ["alpha/one", "beta/two"]

    blocked = ModelSettings.action({:default_model, "beta/two"}, ModelSettings.load(ws_a), ws_a)
    assert blocked.notice

    # Policy default is used only when Model/AI has no model.
    state = ModelSettings.action({:scope, :workspace}, ModelSettings.load(ws_a), ws_a)
    state = ModelSettings.action(:inherit_all, state, ws_a)
    state = ModelSettings.action({:scope, :global}, state, ws_a)
    state = ModelSettings.action({:default_model, ""}, state, ws_a)
    assert ModelConfig.default_model_for_workspace(ws_a["path"]) == "alpha/one"
  end

  test "provider delete lists model count and does not wipe other workspace settings", %{
    ws_a: ws_a,
    ws_b: ws_b
  } do
    save_named(ws_a, "alpha", "one")
    save_named(ws_a, "alpha", "two")
    save_named(ws_a, "beta", "keep")
    tools = %{"allow" => ["read"]}
    path = Handbean.WorkspaceSettings.path(ws_b["path"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(%{"tools" => tools, "beam" => %{"eval" => true}}))

    state = ModelSettings.action({:ask_delete_provider, "alpha"}, ModelSettings.load(ws_a), ws_a)
    assert state.confirm.models_count == 2
    state = ModelSettings.action(:cancel_confirm, state, ws_a)
    assert Map.has_key?(read_models()["providers"], "alpha")

    state = ModelSettings.action({:ask_delete_provider, "alpha"}, ModelSettings.load(ws_a), ws_a)
    state = ModelSettings.action(:confirm_delete, state, ws_a)
    refute Map.has_key?(read_models()["providers"], "alpha")

    {:ok, settings} = Handbean.WorkspaceSettings.load(ws_b["path"])
    assert settings["tools"] == tools
    assert settings["beam"] == %{"eval" => true}
  end

  test "empty catalog requires a provider before a model and generates an internal id", %{
    ws_a: ws
  } do
    state = ModelSettings.load(ws)
    tree = ModelSettings.render(state)
    blob = flatten_text(tree)
    assert blob =~ gettext("No providers yet. Add a provider, then add a model.")
    refute blob =~ "Provider ID"

    rejected = ModelSettings.action(:add_model, state, ws)
    assert rejected.editing == nil
    assert rejected.notice == gettext("Add a provider first")

    state = ModelSettings.action(:add_provider, state, ws)
    form = ModelSettings.render(state)
    form_blob = flatten_text(form)
    refute form_blob =~ "Provider ID"
    assert tap?(form, :save_provider)

    state = ModelSettings.change(state, :name, "My Lab")
    state = ModelSettings.change(state, :base_url, "https://lab.example/v1")
    state = ModelSettings.change(state, :api_key, "fixture-key-not-real")
    state = ModelSettings.action(:save_provider, state, ws)
    assert state.notice == gettext("Provider saved")
    assert state.selected_provider == "my-lab"
    assert Map.has_key?(read_models()["providers"], "my-lab")
    refute Map.has_key?(read_models()["providers"]["my-lab"], "id")
    assert read_models()["providers"]["my-lab"]["models"] == []

    overview = flatten_text(ModelSettings.render(state))
    assert overview =~ "My Lab"
    refute overview =~ "my-lab" and overview =~ "Provider ID"

    assert overview =~ gettext("No models yet for this provider.") or
             overview =~ gettext("This provider has no models yet.")

    state = ModelSettings.action(:add_model, state, ws)
    assert state.form.provider == "my-lab"
    model_form = flatten_text(ModelSettings.render(state))
    assert model_form =~ "My Lab"
    refute model_form =~ "Provider ID"
    refute model_form =~ "Model ID"
    assert model_form =~ "gpt-4o" or model_form =~ "claude-sonnet-4"
  end

  test "toggling a model off hides it from chat choices and toggling it on restores it", %{
    ws_a: ws
  } do
    save_named(ws, "alpha", "one")
    save_named(ws, "alpha", "two")
    state = ModelSettings.load(ws)

    assert Enum.any?(state.models, &(&1.id == "alpha/one" and &1.enabled))

    stored = Enum.find(read_models()["providers"]["alpha"]["models"], &(&1["id"] == "one"))
    refute Map.has_key?(stored, "enabled")

    tree = ModelSettings.render(state)
    assert tap_change?(tree, {:toggle_model_enabled, "alpha", "one", false})

    state =
      ModelSettings.action({:toggle_model_enabled, "alpha", "one", false}, state, ws)

    one = Enum.find(read_models()["providers"]["alpha"]["models"], &(&1["id"] == "one"))
    assert one["enabled"] == false
    assert Enum.any?(state.models, &(&1.id == "alpha/one" and &1.enabled == false))
    refute Enum.any?(state.allowed_models, &(&1.id == "alpha/one"))
    assert Enum.any?(state.allowed_models, &(&1.id == "alpha/two"))

    refute Enum.any?(
             ModelConfig.available_models_for_workspace(ws["path"]),
             &(&1.id == "alpha/one")
           )

    refute Enum.any?(ModelConfig.all_global_models(), &(&1.id == "alpha/one"))

    tree = ModelSettings.render(state)
    assert tap_change?(tree, {:toggle_model_enabled, "alpha", "one", true})
    assert tap?(tree, {:edit_model, "alpha", "one"})
    refute tap?(tree, {:ask_delete_model, "alpha", "one"})

    state = ModelSettings.action({:toggle_model_enabled, "alpha", "one", true}, state, ws)
    one = Enum.find(read_models()["providers"]["alpha"]["models"], &(&1["id"] == "one"))
    assert one["enabled"] == true
    assert Enum.any?(state.allowed_models, &(&1.id == "alpha/one"))

    assert Enum.any?(
             ModelConfig.available_models_for_workspace(ws["path"]),
             &(&1.id == "alpha/one")
           )
  end

  test "provider dropdown switches visible models and keeps readable names", %{ws_a: ws} do
    save_named(ws, "alpha", "one")
    save_named(ws, "beta", "two")
    state = ModelSettings.load(ws)
    tree = ModelSettings.render(state)
    select = find_type(tree, :settings_select, "select-provider")
    assert select
    labels = Enum.map(select.children, & &1.props.text)
    assert "alpha" in labels
    assert "beta" in labels

    state = ModelSettings.action({:select_provider, "beta"}, state, ws)
    tree = ModelSettings.render(state)
    blob = flatten_text(tree)
    assert blob =~ "beta" or blob =~ "two"
    assert tap?(tree, {:edit_model, "beta", "two"})
    refute tap?(tree, {:edit_model, "alpha", "one"})
  end

  test "model save does not rewrite provider url, key, protocol, or max tokens", %{ws_a: ws} do
    state = ensure_provider(ws, "alpha", "https://alpha.example/v1")
    state = ModelSettings.action({:edit_provider, "alpha"}, state, ws)
    state = ModelSettings.change(state, :provider_max_tokens, "2222")
    state = ModelSettings.action({:api, "anthropic-messages"}, state, ws)
    state = ModelSettings.action(:save_provider, state, ws)

    before = read_models()["providers"]["alpha"]
    state = add_model(ws, "alpha", "one", "https://should-not-write.example/v1")
    state = ModelSettings.action(:save_model, state, ws)
    after_save = read_models()["providers"]["alpha"]
    assert after_save["baseUrl"] == before["baseUrl"]
    assert after_save["apiKey"] == before["apiKey"]
    assert after_save["api"] == "anthropic-messages"
    assert after_save["maxTokens"] == 2222
    assert hd(after_save["models"])["id"] == "one"
    assert state.confirm == nil
  end

  test "first model in an empty catalog becomes the catalog default", %{ws_a: ws} do
    save_named(ws, "alpha", "one")
    config = read_models()
    assert config["defaultProvider"] == "alpha"
    assert config["defaultModel"] == "one"
  end

  test "stale provider edit does not recreate a deleted provider", %{ws_a: ws} do
    ensure_provider(ws, "keep", "https://keep.example/v1")
    state = ensure_provider(ws, "alpha", "https://alpha.example/v1")
    state = ModelSettings.action({:edit_provider, "alpha"}, state, ws)
    assert :ok = ModelConfig.remove_provider("alpha")

    rejected = ModelSettings.action(:save_provider, state, ws)
    assert rejected.notice
    refute Map.has_key?(read_models()["providers"], "alpha")
    assert Map.has_key?(read_models()["providers"], "keep")
  end

  test "locale strings cover the new provider catalog copy", %{ws_a: ws} do
    previous = Gettext.get_locale(HandbeanProbe.Gettext)
    on_exit(fn -> Gettext.put_locale(HandbeanProbe.Gettext, previous) end)

    # zh_CN must carry a real translation (not the msgid) for the catalog copy.
    Gettext.put_locale(HandbeanProbe.Gettext, "zh_CN")
    no_providers = gettext("No providers yet. Add a provider, then add a model.")
    add_provider = gettext("Add provider")
    add_model = gettext("Add model")
    no_models = gettext("No models yet for this provider.")
    provider_empty = gettext("This provider has no models yet.")

    for {msgid, translated} <- [
          {"No providers yet. Add a provider, then add a model.", no_providers},
          {"Add provider", add_provider},
          {"Add model", add_model},
          {"No models yet for this provider.", no_models},
          {"This provider has no models yet.", provider_empty},
          {"Fetch models", gettext("Fetch models")}
        ] do
      refute translated == msgid, "zh_CN translation missing for #{inspect(msgid)}"
    end

    state = ModelSettings.load(ws)
    assert flatten_text(ModelSettings.render(state)) =~ no_providers

    state = ensure_provider(ws, "alpha", "https://alpha.example/v1")
    blob = flatten_text(ModelSettings.render(state))
    assert blob =~ add_provider
    assert blob =~ add_model
    assert blob =~ no_models or blob =~ provider_empty

    Gettext.put_locale(HandbeanProbe.Gettext, "en")
    empty = flatten_text(ModelSettings.render(ModelSettings.load(ws)))
    assert empty =~ "No models yet" or empty =~ "This provider has no models"
  end

  test "a broken workspace settings file does not crash load and is reported on delete", %{
    ws_a: ws_a,
    ws_b: ws_b
  } do
    save_named(ws_a, "alpha", "one")
    save_named(ws_a, "alpha", "spare")
    File.write!(Handbean.WorkspaceSettings.path(ws_b["path"]), "{ not jsonc")

    # Current workspace healthy: load still works and the other workspace's
    # breakage does not leak into sources/policy.
    state = ModelSettings.load(ws_a)
    assert state.sources.advisor == :none

    assert Enum.all?(Map.delete(state.sources, :advisor), fn {_field, source} ->
             source == :global
           end)

    assert state.policy.mode == :unrestricted

    # Broken current workspace: load falls back instead of raising.
    broken = ModelSettings.load(ws_b)
    assert broken.policy.mode == :invalid
    assert broken.chat_blocked
    assert broken.sources.advisor == :none

    assert Enum.all?(Map.delete(broken.sources, :advisor), fn {_field, source} ->
             source == :global
           end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        state = ModelSettings.action({:ask_delete_model, "alpha", "spare"}, state, ws_a)
        # Only the (non-blocking) catalog default provider points at alpha.
        assert Handbean.Settings.ModelRefs.blocking(state.confirm.refs) == []
        assert [%{path: path}] = state.confirm.ref_errors
        assert path == ws_b["path"]

        sheet = ModelSettings.confirm_sheet(state)
        assert find_type(sheet, :text, "settings-confirm-ref-errors")
        # An unreadable workspace does not block deleting an unreferenced model.
        assert tap?(sheet, :confirm_delete)
      end)

    assert log =~ "Skipping workspace"
  end

  test "a broken models.json yields a notice instead of a crash", %{ws_a: ws} do
    save_named(ws, "alpha", "one")
    File.write!(ModelConfig.config_file_path(), "{ not json")

    state = ModelSettings.load(ws)
    assert state.providers == []
    assert state.models == []

    edited = ModelSettings.action({:edit_provider, "alpha"}, state, ws)
    assert edited.editing == nil
    assert edited.notice
  end

  test "load_async and find_refs_async deliver tagged results from the task supervisor", %{
    ws_a: ws
  } do
    save_named(ws, "alpha", "one")
    save_named(ws, "beta", "two")

    %Task{ref: ref} = ModelSettings.load_async(ws, nil, 7)
    assert_receive {^ref, {:model_settings_loaded, 7, loaded}}
    Process.demonitor(ref, [:flush])
    assert loaded.selected_provider == "alpha"
    assert Enum.map(loaded.models, & &1.id) |> Enum.sort() == ["alpha/one", "beta/two"]

    %Task{ref: ref} = ModelSettings.find_refs_async(:delete_provider, "alpha", nil, 8)
    assert_receive {^ref, {:model_settings_refs, 8, {:delete_provider, "alpha", nil}, result}}
    Process.demonitor(ref, [:flush])
    assert %{refs: refs, errors: []} = result
    assert Enum.any?(refs, &(&1.source == :catalog_default_provider))

    state =
      ModelSettings.action(
        {:delete_refs_ready, :delete_provider, "alpha", nil, result},
        loaded,
        ws
      )

    assert state.confirm.kind == :delete_provider
    assert state.confirm.models_count == 1
    assert state.confirm.refs == refs
    assert state.confirm.ref_errors == []
  end

  defp add_model(workspace, provider, model, _url) do
    state = ensure_provider(workspace, provider, "https://#{provider}.example/v1")
    state = ModelSettings.action({:select_provider, provider}, state, workspace)
    state = ModelSettings.action(:add_model, state, workspace)

    Enum.reduce(
      %{model: model, name: model},
      state,
      fn {key, value}, state -> ModelSettings.change(state, key, value) end
    )
  end

  defp save_named(workspace, provider, model) do
    state = add_model(workspace, provider, model, "https://#{provider}.example/v1")
    ModelSettings.action(:save_model, state, workspace)
  end

  defp ensure_provider(workspace, provider, url) do
    state = ModelSettings.load(workspace)

    if Enum.any?(state.providers, &(&1.id == provider)) do
      %{state | selected_provider: provider}
    else
      state
      |> then(&ModelSettings.action(:add_provider, &1, workspace))
      |> ModelSettings.change(:name, provider)
      |> ModelSettings.change(:base_url, url)
      |> ModelSettings.change(:api_key, "fixture-key-not-real")
      |> then(&ModelSettings.action(:save_provider, &1, workspace))
    end
  end

  defp flatten_text(node), do: Enum.join(texts(node), "\n")

  defp texts(node) do
    walk(node)
    |> Enum.map(& &1.props[:text])
    |> Enum.reject(&is_nil/1)
  end

  defp tap?(node, tag), do: Enum.any?(walk(node), &match?(%{props: %{on_tap: {_, ^tag}}}, &1))

  defp tap_change?(node, tag),
    do: Enum.any?(walk(node), &match?(%{props: %{on_change: {_, ^tag}}}, &1))

  defp find_type(node, type, id) do
    Enum.find(walk(node), &(&1.type == type && &1.props[:id] == id))
  end

  defp walk(list) when is_list(list), do: Enum.flat_map(list, &walk/1)
  defp walk(%{children: children} = node), do: [node | walk(children)]
  defp walk(%{} = node), do: [node]
  defp walk(_), do: []

  defp read_models do
    File.read!(ModelConfig.config_file_path()) |> Jason.decode!()
  end

  defp update_model_raw(provider, model, extra) do
    config = read_models()

    models =
      Enum.map(config["providers"][provider]["models"], fn entry ->
        if entry["id"] == model, do: Map.merge(entry, extra), else: entry
      end)

    config = put_in(config, ["providers", provider, "models"], models)
    File.write!(ModelConfig.config_file_path(), Jason.encode!(config))
  end
end
