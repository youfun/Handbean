defmodule Handbean.Agent.Tool.SavedInput do
  @moduledoc """
  Immutable tool-input artifacts and reference retries.

  A failed write/edit stores the real input before any side effect. A later
  call may send `retry_of` plus a small override. The reference is resolved
  before path and approval checks, and a changed semantic field becomes a new
  revision. Cross-conversation references are rejected.
  """

  alias Handbean.Agent.OperationReceipt
  alias Handbean.Security.PathValidator

  @large_bytes 8_000
  @max_artifact_bytes 50_000_000
  @artifact_fields %{
    "edit" => MapSet.new(["diff", "new_string", "old_string"]),
    "write" => MapSet.new(["content"])
  }
  @tool_modules %{
    "edit" => Handbean.Tool.Builtin.Edit,
    "write" => Handbean.Tool.Builtin.Write
  }

  @spec prepare(String.t(), map(), map(), [String.t()]) ::
          {:ok, map(), String.t()} | {:error, String.t(), map()}
  def prepare(tool, input, context, overridable) when is_map(input) do
    case Handbean.Utils.SafeMap.get_any(input, "retry_of", :retry_of) do
      ref when is_binary(ref) and ref != "" ->
        resolve(tool, ref, input, context, overridable)

      _ ->
        save_fresh(tool, input, context)
    end
  end

  @spec attach(String.t(), term(), map(), [String.t()]) :: term()
  def attach(operation_id, outcome, context, allowed_overrides \\ ["file_path"])

  def attach(operation_id, {:error, reason}, context, allowed_overrides)
      when is_binary(operation_id) do
    if is_binary(conversation_id(context)) do
      failure(operation_id, to_string(reason), %{allowed_overrides: allowed_overrides})
    else
      {:error, to_string(reason)}
    end
  end

  def attach(_operation_id, other, _context, _allowed_overrides), do: other

  @spec failure(String.t(), String.t(), map()) :: {:error, String.t(), map()}
  def failure(operation_id, reason, extra \\ %{}) do
    {:error, reason,
     Map.merge(
       %{
         operation_id: operation_id,
         status: :failed,
         side_effect: :not_started,
         code: :input_rejected,
         recovery: %{
           action: :retry_saved_input,
           ref: operation_id,
           allowed_overrides: Map.get(extra, :allowed_overrides, [])
         }
       },
       extra
     )}
  end

  defp save_fresh(tool, input, context) do
    operation_id = "op_" <> Ecto.UUID.generate()

    case validate_fresh_input(tool, input) do
      :ok ->
        save_validated(tool, operation_id, input, context)

      {:error, reason} ->
        failure(operation_id, reason, %{code: :input_rejected, side_effect: :not_started})
    end
  end

  defp save_validated(tool, operation_id, input, context) do
    case store_large_fields(tool, operation_id, input, context) do
      {:ok, stored} ->
        stored = Map.put(stored, "operation_id", operation_id)

        with :ok <- persist(tool, operation_id, stored, context) do
          {:ok, Map.put(input, "operation_id", operation_id), operation_id}
        end

      {:error, reason} ->
        failure(operation_id, reason, %{code: :artifact_unavailable, side_effect: :not_started})
    end
  end

  defp resolve(tool, ref, input, context, overridable) do
    with {:ok, saved} <- lookup(tool, ref, context) do
      overrides = Map.drop(input, ["retry_of", :retry_of, "operation_id", :operation_id])
      unknown = Enum.reject(Map.keys(overrides), &(to_string(&1) in overridable))

      cond do
        unknown != [] ->
          failure(ref, "retry_of only allows #{Enum.join(overridable, ", ")}", %{
            allowed_overrides: overridable,
            code: :invalid_retry
          })

        true ->
          merged = apply_overrides(saved, overrides)

          if semantic_change?(saved, merged, overridable) do
            save_fresh(tool, Map.drop(merged, ["operation_id", "retry_of"]), context)
          else
            {:ok, Map.put(merged, "operation_id", ref), ref}
          end
      end
    end
  end

  defp apply_overrides(saved, overrides) do
    Enum.reduce(overrides, saved, fn {key, value}, acc ->
      Map.put(acc, to_string(key), value)
    end)
  end

  defp semantic_change?(saved, merged, overridable) do
    Enum.any?(overridable, fn key ->
      Map.get(saved, key) != Map.get(merged, key) and
        key in ["file_path", "old_string", "command"]
    end)
  end

  defp validate_fresh_input(tool, input) do
    allowed = schema_fields(tool)

    unknown =
      input
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> Enum.reject(&MapSet.member?(allowed, &1))

    cond do
      unknown != [] ->
        {:error, "unknown tool input fields: #{Enum.join(Enum.sort(unknown), ", ")}"}

      input_bytes(input) > @max_artifact_bytes ->
        {:error, "tool input exceeds the 50MB recovery artifact limit"}

      true ->
        :ok
    end
  end

  defp schema_fields(tool) do
    case Map.fetch(@tool_modules, tool) do
      {:ok, module} ->
        module.input_schema()
        |> Map.get(:properties, %{})
        |> Map.keys()
        |> Enum.map(&to_string/1)
        |> MapSet.new()

      :error ->
        MapSet.new()
    end
  end

  defp input_bytes(value) when is_binary(value), do: byte_size(value)
  defp input_bytes(value) when is_list(value), do: Enum.reduce(value, 0, &(&2 + input_bytes(&1)))

  defp input_bytes(value) when is_map(value),
    do: Enum.reduce(value, 0, fn {_key, item}, total -> total + input_bytes(item) end)

  defp input_bytes(_value), do: 0

  defp store_large_fields(tool, operation_id, input, context) do
    artifact_fields = Map.get(@artifact_fields, tool, MapSet.new())

    Enum.reduce_while(input, {:ok, input}, fn
      {key, value}, {:ok, acc} when is_binary(value) and byte_size(value) >= @large_bytes ->
        key = to_string(key)

        if MapSet.member?(artifact_fields, key) do
          case write_artifact(tool, operation_id, value, context) do
            {:ok, ref} -> {:cont, {:ok, Map.put(acc, key, %{"__artifact__" => ref})}}
            :skip -> {:cont, {:ok, acc}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        else
          {:cont, {:ok, acc}}
        end

      _pair, acc ->
        {:cont, acc}
    end)
  end

  defp write_artifact(_tool, _operation_id, value, _context)
       when byte_size(value) > @max_artifact_bytes,
       do: {:error, "tool input exceeds the 50MB recovery artifact limit"}

  defp write_artifact(tool, operation_id, value, context) do
    conversation = conversation_id(context)

    if is_binary(conversation) do
      root = artifact_root(context)
      directory = artifact_directory(root, tool, conversation, operation_id)
      artifact_id = "artifact_" <> Ecto.UUID.generate()
      path = Path.join(directory, artifact_id)

      with :ok <- validate_artifact_path(directory, root),
           :ok <- File.mkdir_p(directory),
           :ok <- validate_artifact_path(directory, root),
           :ok <- File.chmod(directory, 0o700),
           :ok <- validate_artifact_path(path, directory),
           :ok <- validate_artifact_path(path, root),
           :ok <- write_exclusive(path, value) do
        {:ok, artifact_id}
      else
        {:error, reason} -> {:error, "could not save tool input: #{inspect(reason)}"}
      end
    else
      :skip
    end
  end

  defp persist(tool, operation_id, stored, context) do
    conversation = conversation_id(context)

    if is_binary(conversation) do
      fingerprint = OperationReceipt.fingerprint({tool, stored})

      case OperationReceipt.reserve({:tool_input, conversation}, operation_id, fingerprint) do
        :ok ->
          :ok = OperationReceipt.complete({:tool_input, conversation}, operation_id, stored)
          :ok

        {:error, :idempotency_conflict} ->
          failure(operation_id, "saved input conflict", %{code: :idempotency_conflict})

        other ->
          failure(operation_id, "could not save tool input: #{inspect(other)}", %{
            code: :artifact_unavailable,
            side_effect: :not_started
          })
      end
    else
      :ok
    end
  end

  defp lookup(tool, ref, context) do
    conversation = conversation_id(context)

    if is_binary(conversation) do
      case OperationReceipt.lookup({:tool_input, conversation}, ref) do
        {:ok, %{"receipt" => receipt}} when is_map(receipt) ->
          materialize(tool, conversation, receipt, context)

        {:ok, _} ->
          failure(ref, "saved input has no receipt", %{code: :retry_not_found})

        _ ->
          failure(ref, "saved input was not found in this conversation", %{code: :retry_not_found})
      end
    else
      failure(ref, "retry_of requires a conversation", %{code: :retry_not_found})
    end
  end

  defp materialize(tool, conversation, receipt, context) do
    Enum.reduce_while(receipt, {:ok, %{}}, fn
      {key, %{"__artifact__" => name}}, {:ok, acc} when is_binary(name) ->
        root = artifact_root(context)

        directory =
          artifact_directory(
            root,
            tool,
            conversation,
            receipt["operation_id"] || ref_from(receipt)
          )

        path = Path.join(directory, name)

        with :ok <- validate_artifact_name(name),
             :ok <- validate_artifact_path(directory, root),
             :ok <- validate_artifact_path(path, directory),
             :ok <- validate_artifact_path(path, root),
             :ok <- validate_artifact_file(path),
             {:ok, body} <- read_bounded(path) do
          {:cont, {:ok, Map.put(acc, key, body)}}
        else
          {:error, reason} ->
            {:halt,
             failure(
               receipt["operation_id"] || "missing",
               "saved input artifact is unavailable",
               %{
                 code: :artifact_unavailable,
                 artifact_error: inspect(reason)
               }
             )}
        end

      {key, value}, {:ok, acc} ->
        {:cont, {:ok, Map.put(acc, key, value)}}
    end)
  end

  defp artifact_root(context) do
    context[:tool_input_root] || Handbean.ConversationArtifacts.root()
  end

  defp artifact_directory(root, tool, conversation, operation_id) do
    Path.join([root, "items", conversation, "tool-inputs", tool, operation_id])
  end

  defp validate_artifact_path(path, root), do: PathValidator.validate_under_root(path, root)

  defp validate_artifact_name(name) do
    if name not in ["", ".", ".."] and Path.basename(name) == name,
      do: :ok,
      else: {:error, :invalid_artifact_name}
  end

  defp validate_artifact_file(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular, size: size}} when size <= @max_artifact_bytes -> :ok
      {:ok, %{type: :regular}} -> {:error, :artifact_too_large}
      {:ok, _} -> {:error, :invalid_artifact_type}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_bounded(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, @max_artifact_bytes + 1)) do
      {:ok, :eof} -> {:ok, ""}
      {:ok, body} when is_binary(body) and byte_size(body) <= @max_artifact_bytes -> {:ok, body}
      {:ok, body} when is_binary(body) -> {:error, :artifact_too_large}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_exclusive(path, value) do
    case File.open(path, [:write, :binary, :exclusive], &IO.binwrite(&1, value)) do
      {:ok, :ok} ->
        case File.chmod(path, 0o600) do
          :ok ->
            :ok

          {:error, reason} ->
            _ = File.rm(path)
            {:error, reason}
        end

      {:ok, {:error, reason}} ->
        _ = File.rm(path)
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ref_from(receipt), do: receipt["operation_id"] || "missing"

  defp conversation_id(context) do
    Handbean.Utils.SafeMap.get_any(context, :conversation_id, "conversation_id")
  end
end
