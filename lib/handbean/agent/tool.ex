defmodule Handbean.Agent.Tool do
  @moduledoc """
  Behaviour for tools that agents can call.

  ## Required Callbacks

  Every tool must implement `name/0`, `description/0`, `input_schema/0`,
  and `execute/2`.

  ## Optional Callbacks

  - `max_result_chars/0` — max output length before truncation (default: unlimited)
  - `concurrent?/0` — can this tool run in parallel? (default: true)
  """

  @doc "Unique tool name (used in API calls)."
  @callback name() :: String.t()

  @doc "Human-readable description of what the tool does."
  @callback description() :: String.t()

  @doc "JSON Schema defining the tool's input parameters."
  @callback input_schema() :: map()

  @doc """
  Execute the tool with the given input and context.

  Context is a map that may contain:
  - `:working_directory` - base path for file operations
  - `:session_id` - current session identifier
  - any custom keys added by middleware

  Returns `{:ok, String.t()}` or `{:ok, String.t(), map()}` on success,
  `{:error, String.t()}` or `{:error, String.t(), map()}` on failure.
  """
  @callback execute(input :: map(), context :: map()) ::
              {:ok, String.t()}
              | {:ok, String.t(), map()}
              | {:error, String.t()}
              | {:error, String.t(), map()}

  @callback max_result_chars() :: pos_integer() | :unlimited
  @callback concurrent?() :: boolean()

  @callback timeout_ms() :: pos_integer()

  @doc """
  Short recovery note appended to a failed result for this tool.

  The model sees it only after a failure, next to the concrete error, so it
  can change the next call instead of repeating the same one. Omit it when
  the error text is already enough.
  """
  @callback hint() :: String.t()

  @optional_callbacks [max_result_chars: 0, concurrent?: 0, timeout_ms: 0, hint: 0]

  @doc """
  Resolve a file path against the working directory from context.

  Returns `{:ok, path}` or `{:error, reason}`.
  """
  @spec resolve_path(String.t(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def resolve_path(file_path, context) when is_binary(file_path) do
    file_path = Handbean.Agent.Tool.Helpers.expand_tilde(file_path)
    working_directory = working_directory(context)

    resolved =
      if Path.type(file_path) == :absolute do
        Path.expand(file_path)
      else
        case working_directory do
          wd when is_binary(wd) and wd != "" -> Path.expand(file_path, wd)
          _ -> Path.expand(file_path)
        end
      end

    with :ok <- within_workspace(resolved, working_directory, context),
         :ok <- Handbean.Security.PathValidator.reject_resolved(resolved) do
      {:ok, resolved}
    else
      {:error, reason} ->
        if sensitive_resolved?(resolved, file_path) do
          {:error, Handbean.Security.PathValidator.sensitive_reason()}
        else
          {:error, reason}
        end
    end
  end

  defp working_directory(context) when is_map(context) do
    Handbean.Utils.SafeMap.get_any(context, :working_directory, "working_directory")
  end

  defp working_directory(_context), do: nil

  @doc "Whether this tool context may access paths outside the current workspace."
  @spec outside_workspace_allowed?(map()) :: boolean()
  def outside_workspace_allowed?(context) when is_map(context) do
    Handbean.Utils.SafeMap.get_any(context, :approval_mode, "approval_mode") in [:yolo, "yolo"] or
      Handbean.Utils.SafeMap.get_any(context, :delegated_approval, "delegated_approval") in [
        :yolo,
        "yolo"
      ]
  end

  def outside_workspace_allowed?(_context), do: false

  defp within_workspace(resolved, wd, context) do
    cond do
      outside_workspace_allowed?(context) ->
        :ok

      not is_binary(wd) or wd == "" ->
        :ok

      true ->
        Handbean.Security.PathValidator.validate_within_workspace(resolved, wd)
    end
  end

  defp sensitive_resolved?(resolved, original) do
    Handbean.Security.PathValidator.reject_resolved(resolved) != :ok or
      Handbean.Security.PathValidator.reject_sensitive(original) != :ok or
      Handbean.Security.PathValidator.reject_sensitive(resolved) != :ok
  end
end
