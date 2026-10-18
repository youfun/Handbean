defmodule Handbean.Tool.ConversationTool do
  @moduledoc false

  defmacro __using__(opts) do
    quote do
      @behaviour Handbean.Agent.Tool
      @impl true
      def name, do: unquote(opts[:name])
      @impl true
      def description, do: unquote(opts[:description])
      @impl true
      def input_schema, do: unquote(opts[:schema])
      @impl true
      def execute(input, context) do
        unquote(opts[:module]).unquote(opts[:action])(input, context)
        |> Handbean.Tool.ConversationTool.result()
      end
    end
  end

  def result({:ok, value}), do: {:ok, Handbean.JSON.encode!(value)}
  def result({:error, reason}) when is_atom(reason), do: {:error, Atom.to_string(reason)}
  def result({:error, reason}) when is_binary(reason), do: {:error, reason}
  def result(_), do: {:error, "conversation operation failed"}
end
