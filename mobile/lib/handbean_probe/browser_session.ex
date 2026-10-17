defmodule HandbeanProbe.BrowserSession do
  @moduledoc """
  Drive the HomeScreen browser pane from the `browser` tool.

  Does not push a new screen — the workspace WebView stays mounted so
  LiveView chat keeps working. Waits for `{:browser_result, result}`.
  """

  @default_timeout 20_000

  @spec run(tuple() | atom(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def run(command, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout)

    with {:ok, router} <- router() do
      pid = Mob.Screen.get_screen_pid(router)
      send(pid, message(command, self()))

      receive do
        {:browser_result, result} -> result
      after
        timeout -> {:error, "browser timed out after #{timeout}ms"}
      end
    end
  end

  defp router do
    case Process.whereis(:mob_screen) do
      pid when is_pid(pid) -> {:ok, pid}
      _ -> {:error, "browser host is not running"}
    end
  end

  defp message({:open, url}, from), do: {:browser_open, url, from}
  defp message(:snapshot, from), do: {:browser_snapshot, from}
  defp message({:eval, js}, from), do: {:browser_eval, js, from}
  defp message({:click, ref}, from), do: {:browser_click, ref, from}
  defp message({:fill, ref, value}, from), do: {:browser_fill, ref, value, from}
  defp message(:back, from), do: {:browser_back, from}
end
