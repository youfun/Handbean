defmodule Handbean.MCP.Resources do
  @moduledoc "Workspace-authorized MCP resource discovery and bounded content projection."

  alias Handbean.MCP.{Access, ServerRuntime}

  @max_page_entries 100
  @max_page_bytes 65_536
  @max_text_bytes 48_000
  @max_blob_bytes 8_388_608
  @max_contents 64
  @max_cursor_bytes 4_096
  @max_uri_bytes 8_192

  @doc "Lists one server page, or the effective server directory when server is omitted."
  def list_resources(input, context), do: list(input, context, "resources/list", "resources")

  @doc "Lists one template page, or the effective server directory when server is omitted."
  def list_templates(input, context),
    do: list(input, context, "resources/templates/list", "resourceTemplates")

  @doc "Reads a URI only through an authorized MCP server; never dereferences it on the host."
  def read_resource(input, context) when is_map(input) and is_map(context) do
    with :ok <- required_string(input["server"], "server", 256),
         :ok <- required_string(input["uri"], "uri", @max_uri_bytes),
         {:ok, result} <-
           request(input["server"], "resources/read", %{uri: input["uri"]}, context),
         {:ok, contents} <- project_contents(result) do
      result = %{
        "server" => input["server"],
        "uri" => input["uri"],
        "contents" => contents,
        "untrusted" => true
      }

      if byte_size(Handbean.JSON.encode!(result)) <= 98_304,
        do: {:ok, result},
        else: {:error, "MCP resource contents exceed the 96 KiB output limit"}
    end
  end

  def read_resource(_, _), do: {:error, "Expected resource arguments and a trusted MCP scope"}

  defp list(input, context, method, key) when is_map(input) and is_map(context) do
    with {:ok, opts} <- scope_options(context),
         :ok <- optional_string(input["server"], "server", 256),
         :ok <- validate_cursor(input["cursor"]) do
      case {input["server"], input["cursor"]} do
        {nil, nil} ->
          server_directory(opts)

        {nil, _} ->
          {:error, "A cursor requires its owning server"}

        {server, cursor} ->
          params = if is_nil(cursor), do: %{}, else: %{cursor: cursor}

          with {:ok, result} <- request(server, method, params, context),
               {:ok, page} <- project_page(result, key, cursor, server) do
            {:ok, page}
          end
      end
    end
  end

  defp list(_, _, _, _), do: {:error, "Expected resource arguments and a trusted MCP scope"}

  defp server_directory(opts) do
    servers = Access.config(opts).servers |> Map.keys() |> Enum.sort()

    result = %{
      "servers" => servers,
      "instruction" =>
        "Choose a server and repeat this tool to request one page. Pass each nextCursor unchanged with that same server."
    }

    if length(servers) <= @max_page_entries and
         byte_size(Handbean.JSON.encode!(result)) <= @max_page_bytes do
      {:ok, result}
    else
      {:error, "MCP server directory exceeds the output limit; specify a server"}
    end
  end

  defp request(server, method, params, context) do
    deadline = deadline(context)

    with {:ok, opts} <- scope_options(context),
         {:ok, config} <- effective_server(server, opts),
         :ok <- authorize(config, opts, context),
         {:ok, remaining} <- remaining_budget(deadline),
         {:ok, boot} <- bootstrap(opts, remaining),
         {:ok, runtime} <- runtime_server(boot, server),
         :ok <- same_configuration(config, runtime.config),
         :ok <- authorize(runtime.config, opts, context),
         {:ok, remaining} <- remaining_budget(deadline),
         result <-
           ServerRuntime.resource_request(runtime.pid, method, params, remaining,
             deadline: deadline,
             authorization: {runtime.config, opts}
           ),
         :ok <- authorize(runtime.config, opts, context),
         {:ok, _remaining} <- remaining_budget(deadline) do
      normalize_response(result)
    end
  end

  defp scope_options(%{mcp_scope: opts}) when is_list(opts) do
    if Keyword.keyword?(opts) and opts != [],
      do: {:ok, opts},
      else: {:error, "A trusted MCP workspace scope is required"}
  end

  defp scope_options(_), do: {:error, "A trusted MCP workspace scope is required"}

  defp effective_server(server, opts) do
    case Access.config(opts).servers[server] do
      nil -> {:error, "MCP server is disabled, unknown, or not allowed in this workspace"}
      config -> {:ok, config}
    end
  end

  defp authorize(config, opts, context) do
    if Access.allowed?(config, opts, context),
      do: :ok,
      else: {:error, "MCP server is disabled, changed, or not allowed in this workspace"}
  end

  defp same_configuration(expected, actual) do
    if Access.fingerprint(expected) == Access.fingerprint(actual),
      do: :ok,
      else: {:error, "MCP configuration changed; retry discovery"}
  end

  defp bootstrap(opts, remaining) do
    case Handbean.MCP.bootstrap(opts, remaining) do
      {:ok, boot} -> {:ok, boot}
      _ -> {:error, "MCP connection unavailable"}
    end
  catch
    :exit, {:timeout, _} -> {:error, "MCP resource request timed out"}
    :exit, _ -> {:error, "MCP connection unavailable"}
  end

  defp runtime_server(boot, server) do
    case boot.servers[server] do
      nil ->
        error = Enum.find(boot.server_errors, &(&1.server == server))
        {:error, if(error, do: error.error, else: "MCP server connection unavailable")}

      runtime ->
        {:ok, runtime}
    end
  end

  defp deadline(context) do
    cap =
      case context[:tool_timeout] do
        value when is_integer(value) and value > 0 -> min(value, 60_000)
        _ -> 60_000
      end

    deadline = System.monotonic_time(:millisecond) + cap

    case context[:run_deadline] do
      run_deadline when is_integer(run_deadline) -> min(deadline, run_deadline)
      _ -> deadline
    end
  end

  defp remaining_budget(deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    if remaining > 0, do: {:ok, remaining}, else: {:error, "MCP resource request timed out"}
  end

  defp normalize_response({:ok, result}) when is_map(result), do: {:ok, result}

  defp normalize_response({:error, reason})
       when reason in [
              :authorization_required,
              :oauth_scope_required,
              :oauth_configuration_changed,
              "MCP OAuth authorization required. Connect this server in Plugins settings."
            ],
       do:
         {:error,
          "MCP authorization required. Authorize or reconnect this server in plugin settings."}

  defp normalize_response({:error, :resource_access_revoked}),
    do: {:error, "MCP server is disabled, changed, or not allowed in this workspace"}

  defp normalize_response({:error, :resources_not_supported}),
    do: {:error, "MCP server does not support resources"}

  defp normalize_response({:error, %{"code" => -32601}}),
    do: {:error, "MCP server does not support this resource operation"}

  defp normalize_response({:error, %{"code" => -32002}}),
    do: {:error, "MCP resource was not found"}

  defp normalize_response({:error, {:mcp_timeout, _}}),
    do: {:error, "MCP resource request timed out"}

  defp normalize_response({:error, _}), do: {:error, "MCP resource request failed"}
  defp normalize_response(_), do: {:error, "Invalid MCP resource response"}

  defp project_page(result, key, cursor, server) do
    entries = result[key]
    next = result["nextCursor"]
    identity = if key == "resources", do: "uri", else: "uriTemplate"

    cond do
      not is_list(entries) ->
        {:error, "Invalid MCP resource list response"}

      length(entries) > @max_page_entries ->
        {:error, "MCP resource page exceeds 100 entries; the server must return smaller pages"}

      not valid_cursor?(next) or (not is_nil(next) and next == cursor) ->
        {:error, "Invalid MCP resource pagination cursor"}

      not Enum.all?(entries, &valid_entry?(&1, identity)) ->
        {:error, "Invalid MCP resource list entry"}

      true ->
        fields = [identity, "name", "title", "description", "mimeType", "size"]

        page = %{
          key => Enum.map(entries, &Map.take(&1, fields)),
          "server" => server,
          "untrusted" => true
        }

        page = if is_nil(next), do: page, else: Map.put(page, "nextCursor", next)

        if byte_size(Handbean.JSON.encode!(page)) <= @max_page_bytes,
          do: {:ok, page},
          else: {:error, "MCP resource page exceeds 64 KiB; the server must return smaller pages"}
    end
  end

  defp valid_entry?(entry, identity) when is_map(entry) do
    valid_string?(entry[identity], @max_uri_bytes) and valid_string?(entry["name"], 1_024) and
      Enum.all?(["title", "description", "mimeType"], fn key ->
        is_nil(entry[key]) or (is_binary(entry[key]) and String.valid?(entry[key]))
      end) and
      (is_nil(entry["size"]) or (is_integer(entry["size"]) and entry["size"] >= 0))
  end

  defp valid_entry?(_, _), do: false

  defp project_contents(%{"contents" => contents})
       when is_list(contents) and length(contents) <= @max_contents do
    Enum.reduce_while(contents, {:ok, [], @max_text_bytes}, fn content, {:ok, acc, remaining} ->
      case project_content(content, remaining) do
        {:ok, projected, remaining} -> {:cont, {:ok, [projected | acc], remaining}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, projected, _} -> {:ok, Enum.reverse(projected)}
      {:error, _} = error -> error
    end
  end

  defp project_contents(_),
    do: {:error, "Invalid MCP resource contents or more than 64 content items"}

  defp project_content(content, remaining) when is_map(content) do
    with :ok <- required_string(content["uri"], "content URI", @max_uri_bytes),
         :ok <- optional_string(content["mimeType"], "content MIME type", 256) do
      metadata = Map.take(content, ["uri", "mimeType"])
      project_body(content, metadata, remaining)
    end
  end

  defp project_content(_, _), do: {:error, "Invalid MCP resource content item"}

  defp project_body(%{"text" => text} = content, metadata, remaining) when is_binary(text) do
    if Map.has_key?(content, "blob") or not String.valid?(text) do
      {:error, "Invalid MCP resource text"}
    else
      excerpt = utf8_prefix(text, remaining)

      projected =
        Map.merge(metadata, %{
          "text" => excerpt,
          "bytes" => byte_size(text),
          "truncated" => byte_size(excerpt) < byte_size(text)
        })

      {:ok, projected, remaining - byte_size(excerpt)}
    end
  end

  defp project_body(%{"blob" => blob} = content, metadata, remaining) when is_binary(blob) do
    if Map.has_key?(content, "text") or byte_size(blob) > @max_blob_bytes do
      {:error, "Invalid MCP binary content or encoded blob exceeds 8 MiB"}
    else
      case Base.decode64(blob) do
        {:ok, bytes} ->
          projected =
            Map.merge(metadata, %{
              "kind" => "binary",
              "bytes" => byte_size(bytes),
              "omitted" => true,
              "notice" => "Binary resource received. Its bytes are not included in model context."
            })

          {:ok, projected, remaining}

        :error ->
          {:error, "Invalid base64 in MCP binary resource"}
      end
    end
  end

  defp project_body(_, _, _), do: {:error, "MCP resource must contain text or a base64 blob"}

  defp utf8_prefix(text, limit) when byte_size(text) <= limit, do: text
  defp utf8_prefix(text, limit), do: text |> binary_part(0, limit) |> trim_incomplete_utf8()

  defp trim_incomplete_utf8(text) do
    if String.valid?(text),
      do: text,
      else: trim_incomplete_utf8(binary_part(text, 0, byte_size(text) - 1))
  end

  defp optional_string(nil, _, _), do: :ok
  defp optional_string(value, field, limit), do: required_string(value, field, limit)

  defp required_string(value, field, limit) do
    if valid_string?(value, limit),
      do: :ok,
      else: {:error, "#{field} must be a non-empty string of at most #{limit} bytes"}
  end

  defp validate_cursor(cursor) do
    if valid_cursor?(cursor),
      do: :ok,
      else: {:error, "cursor must be a string of at most 4096 bytes"}
  end

  defp valid_cursor?(nil), do: true

  defp valid_cursor?(cursor),
    do: is_binary(cursor) and byte_size(cursor) <= @max_cursor_bytes and String.valid?(cursor)

  defp valid_string?(value, limit),
    do:
      is_binary(value) and byte_size(value) > 0 and byte_size(value) <= limit and
        String.valid?(value) and String.trim(value) != ""
end
