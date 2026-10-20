defmodule Handbean.Browser.Runtime do
  @moduledoc false

  @agent_browser_dir "browser-runtime"
  @chrome_extension_dir "chrome-extension"

  @doc false
  @spec agent_browser_executable(keyword()) :: String.t() | nil
  def agent_browser_executable(opts \\ []) do
    with priv_dir when is_binary(priv_dir) <- runtime_priv_dir(opts),
         path <- Path.join([priv_dir, @agent_browser_dir, agent_browser_name()]),
         true <- executable?(path) do
      path
    else
      _ -> nil
    end
  end

  @doc false
  @spec chrome_extension_path(keyword()) :: String.t()
  def chrome_extension_path(opts \\ []) do
    packaged_path =
      case runtime_priv_dir(opts) do
        path when is_binary(path) -> Path.join(path, @chrome_extension_dir)
        _ -> nil
      end

    if extension?(packaged_path),
      do: packaged_path,
      else: Path.expand("../../../desktop/chrome-extension", __DIR__)
  end

  defp runtime_priv_dir(opts) do
    case Keyword.fetch(opts, :priv_dir) do
      {:ok, path} when is_binary(path) -> path
      {:ok, _invalid} -> nil
      :error -> priv_dir()
    end
  end

  defp priv_dir do
    case :code.priv_dir(:handbean) do
      path when is_list(path) -> List.to_string(path)
      _ -> nil
    end
  end

  defp agent_browser_name do
    if match?({:win32, _}, :os.type()), do: "agent-browser.exe", else: "agent-browser"
  end

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} ->
        match?({:win32, _}, :os.type()) or Bitwise.band(mode, 0o111) != 0

      _ ->
        false
    end
  end

  defp extension?(path) when is_binary(path),
    do: File.regular?(Path.join(path, "manifest.json"))

  defp extension?(_path), do: false
end
