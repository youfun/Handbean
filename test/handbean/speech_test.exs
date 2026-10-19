defmodule Handbean.SpeechTest.Backend do
  @behaviour Handbean.Speech.Backend

  @impl true
  def available?, do: true

  @impl true
  def load_model(path), do: {:ok, path}

  @impl true
  def transcribe(_model, _pcm, opts) do
    notify = Keyword.get(opts, :notify)
    if is_pid(notify), do: send(notify, {:speech_opts, opts})
    {:ok, Keyword.get(opts, :text, "  你好 Handbean  ")}
  end
end

defmodule Handbean.SpeechTest do
  use ExUnit.Case, async: false

  alias Handbean.Speech
  alias Handbean.Speech.{Model, Server}

  setup do
    root = Path.join(System.tmp_dir!(), "handbean-speech-#{System.unique_integer([:positive])}")
    settings_path = Path.join(root, "settings.json")
    previous_settings_path = System.get_env("HANDBEAN_GLOBAL_SETTINGS_FILE")
    File.mkdir_p!(root)
    System.put_env("HANDBEAN_GLOBAL_SETTINGS_FILE", settings_path)

    on_exit(fn ->
      if previous_settings_path,
        do: System.put_env("HANDBEAN_GLOBAL_SETTINGS_FILE", previous_settings_path),
        else: System.delete_env("HANDBEAN_GLOBAL_SETTINGS_FILE")

      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "voice input is disabled by default and persists without replacing other settings" do
    refute Speech.enabled?()

    assert :ok = Handbean.Settings.save_global(%{"default_model" => "provider/model"})
    assert :ok = Speech.set_enabled(true)
    assert Speech.enabled?()

    assert {:ok, settings} = Handbean.Settings.load_global()
    assert settings["speech"] == %{"enabled" => true}
    assert settings["model_ai"] == %{"default_model" => "provider/model"}

    assert :ok = Speech.set_enabled(false)
    refute Speech.enabled?()
  end

  test "validates the 16 kHz mono float PCM duration contract" do
    assert Speech.validate_pcm(:binary.copy(<<0, 0, 0, 0>>, 4_800)) == :ok
    assert Speech.validate_pcm(:binary.copy(<<0, 0, 0, 0>>, 4_799)) == {:error, :too_short}
    assert Speech.validate_pcm(:binary.copy(<<0, 0, 0, 0>>, 960_001)) == {:error, :too_long}
    assert Speech.validate_pcm(<<0, 0, 0>>) == {:error, :invalid_pcm}
    assert Speech.validate_pcm(:not_audio) == {:error, :invalid_pcm}
  end

  test "normalizes speech text and appends it to the draft without sending" do
    assert Speech.normalize_text(" [BLANK_AUDIO] 你好 [MUSIC] ") == "你好"
    assert Speech.append_to_draft("", " 你好 ") == "你好"
    assert Speech.append_to_draft("请检查", "这个文件") == "请检查 这个文件"
    assert Speech.append_to_draft("line\n", "next") == "line\nnext"
    assert Speech.append_to_draft("keep", " [SILENCE] ") == "keep"
  end

  test "installs a verified model atomically and reuses it", %{root: root} do
    bytes = "multilingual-model-fixture"
    spec = model_spec(bytes)
    parent = self()

    fetch = fn url, destination ->
      send(parent, {:fetch, url})
      File.write(destination, bytes)
    end

    assert {:ok, path} = Model.ensure_installed(spec, directory: root, fetch: fetch)
    assert File.read!(path) == bytes
    assert_received {:fetch, "https://example.invalid/fixture.bin"}

    no_fetch = fn _url, _destination -> flunk("verified model should be reused") end
    assert {:ok, ^path} = Model.ensure_installed(spec, directory: root, fetch: no_fetch)
    assert Path.wildcard(Path.join(root, "*.part")) == []
  end

  test "rejects a model whose checksum does not match and removes the partial file", %{root: root} do
    spec = model_spec("expected")
    fetch = fn _url, destination -> File.write(destination, "tampered") end

    assert Model.ensure_installed(spec, directory: root, fetch: fetch) ==
             {:error, :checksum_mismatch}

    refute File.exists?(Model.path(spec, root))
    assert Path.wildcard(Path.join(root, "*.part")) == []
  end

  test "installed files are not advertised ready before verification and load", %{root: root} do
    model_bytes = "model"
    vad_bytes = "vad"
    model = model_spec(model_bytes)
    vad_model = model_spec(vad_bytes, "vad.bin")

    File.write!(Model.path(model, root), model_bytes)
    File.write!(Model.path(vad_model, root), vad_bytes)

    pid =
      start_supervised!(
        {Server,
         name: nil,
         backend: Handbean.SpeechTest.Backend,
         model: model,
         vad_model: vad_model,
         model_opts: [directory: root]}
      )

    assert Server.status(pid) == :installed
    assert Server.prepare(pid) == {:error, :disabled}
  end

  test "server serializes setup and returns normalized transcription", %{root: root} do
    bytes = "model"
    vad_bytes = "vad"
    spec = model_spec(bytes)
    vad_spec = model_spec(vad_bytes, "vad.bin")

    fetch = fn _url, destination ->
      contents =
        if String.contains?(Path.basename(destination), "vad.bin"), do: vad_bytes, else: bytes

      File.write(destination, contents)
    end

    pid =
      start_supervised!(
        {Server,
         name: nil,
         backend: Handbean.SpeechTest.Backend,
         model: spec,
         vad_model: vad_spec,
         model_opts: [directory: root, fetch: fetch]}
      )

    assert Server.status(pid) == :not_downloaded
    assert Server.prepare(pid) == {:error, :disabled}
    assert :ok = Speech.set_enabled(true)
    assert Server.prepare(pid) == :ok
    assert Server.status(pid) == :ready

    pcm = :binary.copy(<<0, 0, 0, 0>>, 4_800)

    assert Server.transcribe(pid, pcm, text: " 你好 Handbean ", notify: self()) ==
             {:ok, "你好 Handbean"}

    assert_received {:speech_opts, opts}
    assert opts[:vad_model_path] == Model.path(vad_spec, root)
    assert Server.status(pid) == :ready
  end

  defp model_spec(bytes, filename \\ "fixture.bin") do
    %{
      id: filename,
      filename: filename,
      url: "https://example.invalid/#{filename}",
      size_bytes: byte_size(bytes),
      sha256: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    }
  end
end
