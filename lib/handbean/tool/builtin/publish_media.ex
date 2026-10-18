defmodule Handbean.Tool.Builtin.PublishMedia do
  @moduledoc """
  Publishes one verified image as durable, user-visible conversation media.

  Source paths are execution inputs only. Public tool events and transcripts use
  `public_input/1`, which never exposes an absolute path.
  """

  @behaviour Handbean.Agent.Tool

  alias Handbean.Media
  alias Handbean.Settings
  alias Handbean.Utils.SafeMap

  @impl true
  def name, do: "publish_media"

  @impl true
  def description do
    "Publish one PNG, JPEG, GIF, or WebP file from the current workspace or a " <>
      "trusted tool-output directory into this conversation. The returned media " <>
      "is shown in chat. Paths are never exposed as media URLs."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        path: %{
          type: "string",
          description: "Workspace-relative path or a path inside a trusted tool-output directory."
        },
        filename: %{
          type: "string",
          description: "Optional display filename. Defaults to the source filename."
        }
      },
      required: ["path"]
    }
  end

  @impl true
  def concurrent?, do: false

  @impl true
  def max_result_chars, do: 2_000

  @impl true
  def execute(input, context) when is_map(input) and is_map(context) do
    path = SafeMap.get_any(input, "path", :path)
    filename = SafeMap.get_any(input, "filename", :filename)
    conversation_id = context[:conversation_id] || context[:session_id]
    tool_call_id = context[:tool_call_id]

    opts =
      [
        conversation_id: conversation_id,
        producer_tool_call_id: tool_call_id,
        working_directory: context[:working_directory],
        trusted_roots: trusted_roots(context, conversation_id),
        filename: filename || display_name(path)
      ]
      |> maybe_put(:backend, context[:media_backend])
      |> maybe_put(:backend_registry, context[:media_backend_registry])

    case path do
      value when is_binary(value) and value != "" ->
        case Media.stage_file(value, opts) do
          {:ok, media} ->
            descriptor = Media.project(media)

            {:ok, "Published #{descriptor.filename} to this conversation.",
             %{
               status: :succeeded,
               side_effect: :committed,
               published_media: [descriptor]
             }}

          {:error, reason} ->
            {:error, error_text(reason),
             %{code: :media_publish_failed, side_effect: :not_started}}
        end

      _ ->
        {:error, "path is required", %{code: :invalid_input, side_effect: :not_started}}
    end
  end

  def execute(_input, _context),
    do:
      {:error, "invalid publish_media input", %{code: :invalid_input, side_effect: :not_started}}

  @doc "Bounded tool-input projection safe for transcript, PubSub, and logs."
  @spec public_input(map()) :: map()
  def public_input(input) when is_map(input) do
    path = SafeMap.get_any(input, "path", :path)
    filename = SafeMap.get_any(input, "filename", :filename)

    %{"path" => display_name(path)}
    |> maybe_put_map("filename", clean_public_name(filename))
    |> Handbean.Log.Redactor.redact()
  end

  def public_input(_input), do: %{}

  defp trusted_roots(context, conversation_id) do
    configured = List.wrap(context[:media_trusted_roots])

    browser =
      if is_binary(conversation_id) and conversation_id != "" do
        [Path.join([Settings.default_global_dir(), "browser", conversation_id])]
      else
        []
      end

    Enum.uniq(configured ++ browser)
  end

  defp display_name(path) when is_binary(path) do
    path
    |> String.replace("\\", "/")
    |> Path.basename()
    |> clean_public_name()
    |> case do
      nil -> "image"
      name -> name
    end
  end

  defp display_name(_path), do: "image"

  defp clean_public_name(name) when is_binary(name) do
    cleaned =
      name
      |> String.replace(~r/[\x00-\x1f\x7f]/u, "")
      |> String.trim()
      |> String.slice(0, 255)

    if cleaned == "", do: nil, else: cleaned
  end

  defp clean_public_name(_name), do: nil

  defp error_text(:outside_trusted_root),
    do: "Media source is outside the allowed workspace or tool-output directory."

  defp error_text(:unsupported_type), do: "Only PNG, JPEG, GIF, and WebP images can be published."
  defp error_text(:type_mismatch), do: "The image contents do not match the declared media type."
  defp error_text(:image_too_large_or_empty), do: "The image is empty or exceeds 5,000,000 bytes."
  defp error_text(:invalid_filename), do: "The display filename is invalid."

  defp error_text(:missing_working_directory),
    do: "A workspace or trusted tool-output path is required."

  defp error_text(reason), do: "Could not publish media: #{inspect(reason)}"

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_put_map(map, _key, nil), do: map
  defp maybe_put_map(map, key, value), do: Map.put(map, key, value)
end
