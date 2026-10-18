defmodule Handbean.Tool.Extension.Terminal do
  @moduledoc "Checkout-scoped terminal introspection tools for agents."

  alias Handbean.Terminal.Supervisor, as: TermSup

  @max_output_bytes 50_000

  def register do
    tools()
    |> Map.values()
    |> Enum.each(fn %{
                      name: name,
                      description: description,
                      input_schema: schema,
                      execute: execute
                    } ->
      Handbean.Tool.Registry.register_virtual(name, description, schema, execute)
    end)

    :ok
  end

  def tools do
    %{
      "ext__term_list" => %{
        name: "ext__term_list",
        description: "列出当前工作区所有终端",
        input_schema: %{"type" => "object", "properties" => %{}, "required" => []},
        execute: &ext_term_list/2
      },
      "ext__term_output" => %{
        name: "ext__term_output",
        description: "读取指定终端的输出",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "terminal" => %{"type" => "string", "description" => "终端名称"},
            "tail" => %{"type" => "integer", "description" => "返回最后 N 行（默认: 全部）"},
            "grep" => %{"type" => "string", "description" => "大小写不敏感正则过滤"}
          },
          "required" => ["terminal"]
        },
        execute: &ext_term_output/2
      },
      "ext__term_send" => %{
        name: "ext__term_send",
        description: "向指定终端发送输入",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "terminal" => %{"type" => "string", "description" => "终端名称"},
            "input" => %{"type" => "string", "description" => "要发送的输入"}
          },
          "required" => ["terminal", "input"]
        },
        execute: &ext_term_send/2
      }
    }
  end

  @doc false
  def ext_term_list(_input, context) do
    with {:ok, workspace_id, checkout_path} <- terminal_scope(context) do
      terminals =
        TermSup.list_terminals(workspace_id, checkout_path)
        |> Enum.map(fn terminal ->
          %{
            name: terminal.name,
            status: terminal.status,
            cmd: terminal.cmd,
            args: terminal.args,
            cwd: terminal.cwd
          }
        end)

      {:ok, Handbean.JSON.encode!(terminals, pretty: true)}
    end
  end

  @doc false
  def ext_term_output(input, context) do
    terminal_name = Map.get(input, "terminal")
    tail = Map.get(input, "tail")
    grep = Map.get(input, "grep")

    with {:ok, workspace_id, checkout_path} <- terminal_scope(context),
         :ok <- require_terminal_name(terminal_name),
         {:ok, pid} <- terminal_pid(workspace_id, checkout_path, terminal_name) do
      opts = [tail: tail, grep: grep] |> Enum.reject(fn {_key, value} -> is_nil(value) end)

      case Handbean.Terminal.Session.snapshot(pid, opts) do
        {:ok, text} ->
          %{content: content} =
            Handbean.Utils.Truncate.truncate(text, :tail, max_bytes: @max_output_bytes)

          {:ok, content}

        {:error, reason} ->
          {:error, "failed to read terminal output: #{inspect(reason)}"}
      end
    end
  end

  @doc false
  def ext_term_send(input, context) do
    terminal_name = Map.get(input, "terminal")
    text_input = Map.get(input, "input")

    with {:ok, workspace_id, checkout_path} <- terminal_scope(context),
         :ok <- require_terminal_name(terminal_name),
         :ok <- require_input(text_input),
         {:ok, pid} <- terminal_pid(workspace_id, checkout_path, terminal_name) do
      case Handbean.Terminal.Session.send_input(pid, text_input) do
        :ok -> {:ok, "input sent to terminal '#{terminal_name}'"}
        {:error, reason} -> {:error, "failed to send input: #{inspect(reason)}"}
      end
    end
  end

  defp terminal_scope(context) do
    workspace_id = Map.get(context, :workspace_id, Map.get(context, "workspace_id"))

    checkout_path =
      Map.get(context, :working_directory, Map.get(context, "working_directory")) ||
        Map.get(context, :checkout_path, Map.get(context, "checkout_path"))

    cond do
      not is_binary(workspace_id) or workspace_id == "" ->
        {:error, "workspace_id is required in context"}

      not is_binary(checkout_path) or checkout_path == "" ->
        {:error, "working_directory is required in context"}

      true ->
        {:ok, workspace_id, checkout_path}
    end
  end

  defp require_terminal_name(name) when is_binary(name) and name != "", do: :ok
  defp require_terminal_name(_name), do: {:error, "terminal name is required"}

  defp require_input(input) when is_binary(input) and input != "", do: :ok
  defp require_input(_input), do: {:error, "input is required"}

  defp terminal_pid(workspace_id, checkout_path, terminal_name) do
    case TermSup.lookup(workspace_id, checkout_path, terminal_name) do
      {:ok, pid} -> {:ok, pid}
      {:error, :not_found} -> {:error, "terminal '#{terminal_name}' not found in checkout"}
      {:error, reason} -> {:error, "terminal lookup failed: #{inspect(reason)}"}
    end
  end
end
