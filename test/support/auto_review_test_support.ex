defmodule Handbean.Permissions.AutoReviewTestSupport do
  defmodule MarkerTool do
    @behaviour Handbean.Agent.Tool

    def name, do: "auto_review_marker"
    def description, do: "Writes a marker file when executed"
    def input_schema, do: %{type: "object", properties: %{file: %{type: "string"}}}

    def execute(%{"file" => file}, %{working_directory: workspace}) do
      :ok = File.write(Path.join(workspace, file), "ran")
      {:ok, "touched #{file}", %{file_path: file}}
    end
  end

  defmacro __using__(_opts) do
    quote do
      use ExUnit.Case, async: false

      alias Handbean.Agent.{Config, Message, State, Turn}
      alias Handbean.Agent.Middleware.ToolGuard
      alias Handbean.Permissions.AutoReview
      alias Handbean.Permissions.AutoReviewTestSupport.MarkerTool

      setup do
        Process.delete(AutoReview.transport_key())
        :ok = Handbean.Tool.Registry.register(MarkerTool, override: true)

        on_exit(fn ->
          Process.delete(AutoReview.transport_key())
          Handbean.Tool.Registry.unregister(MarkerTool.name())
        end)

        :ok
      end

      defp workspace(settings) do
        dir =
          Path.join(System.tmp_dir!(), "auto_review_#{System.unique_integer([:positive])}")

        File.mkdir_p!(Path.join(dir, ".handbean"))
        File.write!(Path.join(dir, ".handbean/settings.jsonc"), Jason.encode!(settings))
        on_exit(fn -> File.rm_rf(dir) end)
        dir
      end

      defp guard_state(settings, calls, overrides \\ %{}) do
        config = %Config{
          working_directory: workspace(settings),
          model: "fake",
          middleware: []
        }

        %State{State.init(config, "please run the local check") | tool_guard_overrides: overrides}
        |> State.append_messages([Message.tool_use(calls)])
      end

      defp reviewed(calls) do
        Process.put(AutoReview.transport_key(), fn request ->
          send(self(), {:reviewed, request})

          decisions =
            Enum.map(request.action_requests, fn req ->
              decision = Map.get(calls, req.tool_call_id, "deny")

              %{
                "tool_call_id" => req.tool_call_id,
                "decision" => decision,
                "rationale" => "because #{decision}"
              }
            end)

          {:ok, Jason.encode!(%{"decisions" => decisions})}
        end)
      end
    end
  end
end
