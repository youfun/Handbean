defmodule Handbean.Agent.HostEnvironment do
  @moduledoc """
  Host facts shared by prompt composition and configuration inspection.
  An entry surface (Web/native/headless) never implies an execution platform.
  Section IDs and sources are safe to inspect; prompt bodies are not exported.
  """

  alias Handbean.Host

  @doc "Selected environment sections. These describe capabilities, not tool authorization."
  def sections do
    [
      %{id: :workspace_files, source: :host_independent},
      %{id: if(Host.shell?(), do: :shell, else: :no_shell), source: :host_shell},
      mix_section(),
      %{id: browser_section(), source: :host_browser},
      script_section(),
      delivery_section()
    ]
    |> Enum.reject(&is_nil/1)
  end

  @doc "Compose a compact environment contract without inferring capabilities from the OS."
  def describe do
    "\n\n## Host execution environment\n\n" <>
      "These host capabilities do not grant permission. Use only tools exposed in this request. " <>
      "Web is an entry surface, not a Linux execution host. Do not infer desktop commands from an Android Linux kernel or iOS/Darwin architecture.\n\n" <>
      Enum.map_join(sections(), "\n\n", &text(&1.id))
  end

  defp browser_section do
    case Host.browser_backend() do
      :cli -> :desktop_browser
      :webview -> :webview_browser
      _ -> :no_browser
    end
  end

  defp script_section do
    if Host.host_script?(),
      do: %{id: :host_script, source: :host_script}
  end

  defp delivery_section do
    if Host.artifact_delivery_backend(),
      do: %{id: :artifact_delivery, source: :artifact_delivery_backend}
  end

  defp mix_section do
    if Host.packaged_mix_toolchain?(),
      do: %{id: :mix_project, source: :host_packaged_mix_toolchain}
  end

  defp text(:workspace_files) do
    "Read/edit/write, grep/file_search, and code_search operate on workspace files when exposed; paths remain subject to tool permissions. " <>
      "code_search returns path and line numbers. Without an embeddings config it matches symbols and tokens, not natural-language questions; a miss is not proof the code is absent. " <>
      git_backend_text()
  end

  defp text(:shell) do
    "The host permits the bash backend when exposed. Prefer file tools for file operations. " <>
      "This does not guarantee installed commands, a Linux environment, or a sandbox. " <>
      "Read the repository's own workflow and choose make, mise, mix, git, or another command; the prompt does not require one of them."
  end

  defp text(:no_shell) do
    "There is no Unix shell on this host available to the agent. Do not call `bash`, shell pipelines, or external mix/elixir commands. " <>
      "Use grep/file_search for exact or filename search, and code_search for symbol or configured semantic search. Browser availability is independent of shell access."
  end

  defp text(:mix_project) do
    "When exposed and its toolchain is available, `mix_project` manages a workspace mix.exs project: deps.get, compile, test and run. " <>
      "It executes on the host BEAM, not in a shell or sandbox. Only host-compatible pure Elixir/Erlang dependencies are supported; arbitrary NIFs and external builds are not supported."
  end

  defp text(:host_script) do
    "For local computation, file processing or HTTP, use `run_elixir_script` when exposed: write the .exs first, then execute and verify outputs. " <>
      "It receives workspace and args bindings and runs high-privilege host BEAM code, not a shell or sandbox. " <>
      "When Mix is present, use Mix.install/2 at the top of the script for host-compatible pure Elixir/Erlang packages. " <>
      "Follow the script tool environment for Mix/Hex availability and curated APIs (Handbean.Tool.ScriptEnvironment)."
  end

  defp text(:artifact_delivery) do
    "System open/share tools (`open_url`, `open_file`, `share_file`) launch native UI, not an agent browser session. " <>
      "Success means the system UI was shown, not that a page loaded, a file was read, or a share completed. " <>
      "When the user asks to check or add a calendar event, call `device_calendar`. " <>
      "An authorized Android insert writes the system calendar directly and does not open the calendar app. " <>
      "iOS does not support device_calendar or device_alarm. When the user asks for a clock alarm, call `device_alarm`. " <>
      "That only prefills the system clock (`AlarmClock.ACTION_SET_ALARM`); many devices still need a save tap. " <>
      "It is not a silent alarm write and does not use accessibility. Do not invent an event or alarm the tool did not confirm."
  end

  defp text(:desktop_browser),
    do:
      "The browser backend is agent-browser CLI when exposed. The executable and browser runtime must be installed on the computer running this conversation. Handbean resolves commands from that computer's login-shell and current workspace environments, including mise, asdf, and direnv. An install on another computer does not count. Browser access does not grant shell permission."

  defp text(:webview_browser),
    do:
      "The browser backend is a host WebView session when exposed, separate from system open/share UI. preview_serve registers workspace previews; it is not a shell server."

  defp text(:no_browser),
    do:
      "Neither desktop nor WebView browser capability is enabled by the host. Do not assume a browser is available."

  defp git_backend_text do
    cond do
      not is_nil(Host.get(:git_backend)) ->
        "The git tool uses the host-provided Git backend. Registration does not prove native dependencies are usable."

      Host.shell?() ->
        "There is no separate git or mix tool. When `bash` is exposed, follow the repository's documented command-line workflow and choose the command yourself; do not assume git or mix must be used."

      true ->
        "This host exposes neither bash nor a Git backend. Do not assume Git operations are available."
    end
  end
end
