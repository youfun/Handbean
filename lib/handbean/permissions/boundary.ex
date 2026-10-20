defmodule Handbean.Permissions.Boundary do
  @moduledoc """
  Classifies and enforces resource access outside the current checkout or workspace.

  Policy decides whether a requirement is automatic, reviewed, or denied. This
  module owns only normalized boundary descriptors and invocation-scoped grants;
  path and conversation owners still perform their normal validation at use time.
  """

  alias Handbean.{ConversationStore, Conversations, WorkspaceStore}
  alias Handbean.Security.PathValidator
  alias Handbean.Utils.SafeMap

  defmodule ReturnGrant do
    @moduledoc false
    @enforce_keys [:source_conversation_id, :target_conversation_id, :handoff_id]
    defstruct [:source_conversation_id, :target_conversation_id, :handoff_id]
  end

  @path_tools %{
    "read" => {"file_path", :read, :file},
    "edit" => {"file_path", :write, :file},
    "write" => {"file_path", :write, :file},
    "grep" => {"path", :search, :path},
    "file_search" => {"path", :search, :path},
    "code_search" => {"path", :search, :path},
    "bash" => {"cwd", :execute, :directory}
  }

  @conversation_operations %{
    "read_conversation" => :read,
    "get_conversation_status" => :status,
    "get_conversation_trajectory" => :trajectory,
    "send_conversation_message" => :send
  }

  @workspace_operations %{
    "list_models" => :list_models,
    "create_conversation" => :create_conversation
  }

  @doc "Return the extra resource requirement for a tool call, if any."
  def requirement(call, context) when is_map(call) and is_map(context) do
    name = call_name(call)
    input = call_input(call)

    cond do
      Map.has_key?(@path_tools, name) ->
        path_requirement(name, input, context)

      Map.has_key?(@conversation_operations, name) ->
        conversation_requirement(name, input, context)

      Map.has_key?(@workspace_operations, name) ->
        workspace_requirement(name, input, context)

      true ->
        nil
    end
  end

  def requirement(_call, _context), do: nil

  @doc "Build an exact invocation grant from a normalized requirement."
  def grant(call, context, requirement, provenance)
      when is_map(call) and is_map(context) and is_map(requirement) do
    %{
      source_workspace_id: value(context, :workspace_id),
      source_conversation_id: value(context, :conversation_id),
      run_id: value(context, :run_id),
      tool_call_id: call_id(call),
      tool_name: call_name(call),
      input_fingerprint: fingerprint(call_name(call), call_input(call)),
      resource: requirement.resource,
      operation: requirement.operation,
      provenance: provenance
    }
  end

  @doc "Select and validate the grant for one invocation, dropping the grant collection."
  def invocation_context(context, call) when is_map(context) and is_map(call) do
    id = call_id(call)
    name = call_name(call)
    input = call_input(call)

    grant =
      context
      |> Map.get(:tool_execution_grants, %{})
      |> Map.get(id)
      |> valid_invocation_grant(context, id, name, input)

    context
    |> Map.delete(:tool_execution_grants)
    |> Map.delete(:boundary_grant)
    |> maybe_put_grant(grant)
  end

  def invocation_context(context, _call) do
    context
    |> Map.delete(:tool_execution_grants)
    |> Map.delete(:boundary_grant)
  end

  defp valid_invocation_grant(
         %{
           tool_call_id: tool_call_id,
           tool_name: tool_name,
           input_fingerprint: input_fingerprint,
           source_workspace_id: source_workspace_id,
           source_conversation_id: source_conversation_id,
           run_id: run_id
         } = candidate,
         context,
         id,
         name,
         input
       ) do
    if identity_present?(source_workspace_id) and identity_present?(source_conversation_id) and
         identity_present?(run_id) and tool_call_id == id and tool_name == name and
         input_fingerprint == fingerprint(name, input) and
         source_workspace_id == value(context, :workspace_id) and
         source_conversation_id == value(context, :conversation_id) and
         run_id == value(context, :run_id),
       do: candidate
  end

  defp valid_invocation_grant(_candidate, _context, _id, _name, _input), do: nil

  @doc "Whether this invocation may use a canonical path outside its checkout."
  def path_allowed?(context, path, operation) when is_map(context) and is_binary(path) do
    yolo?(context) or
      case Map.get(context, :boundary_grant) do
        %{resource: %{kind: :path} = resource, operation: granted_operation} ->
          operation_matches?(granted_operation, operation) and path_matches?(resource, path)

        _ ->
          false
      end
  end

  def path_allowed?(_context, _path, _operation), do: false

  @doc "Whether this invocation may access an exact conversation in another workspace."
  def conversation_allowed?(context, target_id, operation)
      when is_map(context) and is_binary(target_id) do
    yolo?(context) or return_allowed?(context, target_id, operation) or
      create_initial_allowed?(context, target_id, operation) or
      match_grant?(context, :conversation, target_id, operation)
  end

  def conversation_allowed?(_context, _target_id, _operation), do: false

  @doc "Whether this invocation may address an exact workspace."
  def workspace_allowed?(context, workspace_id, operation)
      when is_map(context) and is_binary(workspace_id) do
    value(context, :workspace_id) == workspace_id or yolo?(context) or
      match_grant?(context, :workspace, workspace_id, operation)
  end

  def workspace_allowed?(_context, _workspace_id, _operation), do: false

  @doc "Project boundary details into approval requests without exposing hidden metadata."
  def annotate_requests(requests, pending_grants)
      when is_list(requests) and is_map(pending_grants) do
    Enum.map(requests, fn request ->
      case Map.get(pending_grants, request.tool_call_id) do
        %{resource: resource, operation: operation} ->
          Map.put(request, :boundary, %{resource: public_resource(resource), operation: operation})

        _ ->
          request
      end
    end)
  end

  def annotate_requests(requests, _pending_grants), do: requests

  @doc "Return public target metadata after applying permanent visibility exclusions."
  def conversation_target(id) when is_binary(id) do
    with {:ok, target} <- ConversationStore.get_metadata(id),
         true <- Conversations.visible?(target),
         false <- target["scope"] == "free",
         false <- target["visibility"] == "internal",
         workspace_id when is_binary(workspace_id) and workspace_id != "" <-
           target["workspace_id"] do
      {:ok, target}
    else
      _ -> {:error, :not_accessible}
    end
  end

  def conversation_target(_id), do: {:error, :not_accessible}

  defp path_requirement(name, input, context) do
    {field, operation, scope_hint} = Map.fetch!(@path_tools, name)

    case input_value(input, field) do
      path when is_binary(path) and path != "" ->
        checkout = value(context, :working_directory) || value(context, :checkout_path)

        with {:ok, resolved} <- resolve_path(path, checkout),
             :ok <- PathValidator.reject_resolved(resolved) do
          if inside?(resolved, checkout) do
            nil
          else
            scope = path_scope(resolved, scope_hint)

            %{
              resource: %{kind: :path, path: resolved, scope: scope},
              operation: operation
            }
          end
        else
          {:error, reason} -> {:deny, reason}
        end

      _ ->
        nil
    end
  end

  defp conversation_requirement(name, input, context) do
    operation = Map.fetch!(@conversation_operations, name)
    target_id = input_value(input, "conversation")
    source_workspace_id = value(context, :workspace_id)

    if is_binary(target_id) and target_id != "" do
      case conversation_target(target_id) do
        {:ok, target} ->
          if target["workspace_id"] == source_workspace_id do
            nil
          else
            %{
              resource: %{
                kind: :conversation,
                id: target["id"],
                workspace_id: target["workspace_id"]
              },
              operation: operation
            }
          end

        {:error, reason} ->
          {:deny, reason}
      end
    end
  end

  defp workspace_requirement(name, input, context) do
    operation = Map.fetch!(@workspace_operations, name)
    target_id = input_value(input, "workspace")
    source_workspace_id = value(context, :workspace_id)

    cond do
      target_id in [nil, ""] ->
        nil

      target_id == source_workspace_id ->
        nil

      is_binary(target_id) ->
        case WorkspaceStore.get(target_id) do
          {:ok, _workspace} ->
            %{resource: %{kind: :workspace, id: target_id}, operation: operation}

          _ ->
            {:deny, :not_accessible}
        end

      true ->
        {:deny, :invalid_input}
    end
  end

  defp resolve_path(path, checkout) do
    expanded = Handbean.Agent.Tool.Helpers.expand_tilde(path)

    resolved =
      cond do
        Path.type(expanded) == :absolute -> Path.expand(expanded)
        is_binary(checkout) and checkout != "" -> Path.expand(expanded, checkout)
        true -> Path.expand(expanded)
      end

    case PathValidator.canonicalize(resolved) do
      {:ok, canonical} -> {:ok, canonical}
      {:error, _reason} -> {:error, "Path traversal blocked"}
    end
  end

  defp inside?(_path, checkout) when not is_binary(checkout) or checkout == "", do: true
  defp inside?(path, checkout), do: PathValidator.validate_within_workspace(path, checkout) == :ok

  defp path_scope(path, :path) do
    if File.regular?(path), do: :file, else: :subtree
  end

  defp path_scope(_path, :directory), do: :directory
  defp path_scope(_path, scope), do: scope

  defp path_matches?(%{path: granted, scope: :file}, path),
    do: current_canonical_path(path) == granted

  defp path_matches?(%{path: granted, scope: :directory}, path),
    do: current_canonical_path(path) == granted

  defp path_matches?(%{path: granted, scope: :subtree}, path) do
    case current_canonical_path(path) do
      canonical when is_binary(canonical) ->
        canonical == granted or String.starts_with?(canonical, granted <> "/")

      _ ->
        false
    end
  end

  defp path_matches?(_resource, _path), do: false

  defp current_canonical_path(path) do
    case PathValidator.canonicalize(path) do
      {:ok, canonical} -> canonical
      _ -> nil
    end
  end

  defp match_grant?(context, kind, id, operation) do
    case Map.get(context, :boundary_grant) do
      %{resource: %{kind: ^kind, id: ^id}, operation: granted_operation} ->
        operation_matches?(granted_operation, operation)

      _ ->
        false
    end
  end

  defp operation_matches?(operation, operation), do: true
  defp operation_matches?(_granted, _requested), do: false

  defp create_initial_allowed?(context, target_id, :create_initial) do
    case {conversation_target(target_id), Map.get(context, :boundary_grant)} do
      {{:ok, %{"workspace_id" => workspace_id}},
       %{resource: %{kind: :workspace, id: workspace_id}, operation: :create_conversation}} ->
        true

      _ ->
        false
    end
  end

  defp create_initial_allowed?(_context, _target_id, _operation), do: false

  defp return_allowed?(context, target_id, :automatic_return) do
    source_id = value(context, :conversation_id)

    case Map.get(context, :conversation_return_grant) do
      %ReturnGrant{
        source_conversation_id: ^source_id,
        target_conversation_id: ^target_id,
        handoff_id: handoff_id
      }
      when is_binary(handoff_id) and handoff_id != "" ->
        true

      _ ->
        false
    end
  end

  defp return_allowed?(_context, _target_id, _operation), do: false

  defp identity_present?(value), do: is_binary(value) and String.trim(value) != ""

  defp maybe_put_grant(context, nil), do: context
  defp maybe_put_grant(context, grant), do: Map.put(context, :boundary_grant, grant)

  defp public_resource(%{kind: :path, path: path, scope: scope}),
    do: %{kind: :path, path: path, scope: scope}

  defp public_resource(%{kind: :conversation, id: id, workspace_id: workspace_id}),
    do: %{kind: :conversation, id: id, workspace_id: workspace_id}

  defp public_resource(%{kind: :workspace, id: id}), do: %{kind: :workspace, id: id}
  defp public_resource(_resource), do: %{kind: :unknown}

  defp fingerprint(name, input) do
    :crypto.hash(:sha256, :erlang.term_to_binary({name, input}, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  defp yolo?(context) do
    value(context, :approval_mode) in [:yolo, "yolo"] or
      value(context, :delegated_approval) in [:yolo, "yolo"]
  end

  defp call_id(call), do: SafeMap.get_any(call, :id, "id")
  defp call_name(call), do: to_string(SafeMap.get_any(call, :name, "name") || "")
  defp call_input(call), do: SafeMap.get_any(call, :input, "input") || %{}

  defp input_value(input, key) when is_map(input) do
    Map.get(input, key) || existing_atom_value(input, key)
  end

  defp input_value(_input, _key), do: nil

  defp existing_atom_value(input, key) do
    try do
      Map.get(input, String.to_existing_atom(key))
    rescue
      ArgumentError -> nil
    end
  end

  defp value(map, key), do: SafeMap.get_any(map, key, Atom.to_string(key))
end
