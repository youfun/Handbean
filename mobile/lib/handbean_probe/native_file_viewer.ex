defmodule HandbeanProbe.NativeFileViewer do
  @moduledoc """
  Read-only viewer metadata and Mob nodes.

  `prepare/1` resolves the path and classifies from the **name** only.
  It does not open the file. Bytes are read on Android from one checked fd.

  HomeScreen shows the Mob `:file_viewer` node on Android. On iOS the same
  metadata is rendered with stock nodes and a bounded text/image preview.

  External kinds use `export/2`, which is only
  `Platform.export_file(caller, request_id, generation, workspace_path, relative_path)`.
  Foundation also has
  `open_snapshot(caller, request_id, generation, snapshot_id, owner_request_id)` and
  `share_snapshot/5` with the same arity — those run **after** an export
  result exists. This module does not call them.

  Platform snapshot JSON uses snake_case (`snapshot_id`, `owner_request_id`).
  """

  use Gettext, backend: HandbeanProbe.Gettext
  import HandbeanProbe.NativeUI

  alias Handbean.WorkspaceFiles
  alias HandbeanProbe.NativeLocalImage

  defstruct identity: nil, status: :closed, error: nil

  @type status :: :closed | :ready | :external | :error
  @type t :: %__MODULE__{identity: Identity.t() | nil, status: status(), error: term()}

  defmodule Identity do
    @moduledoc false

    @enforce_keys [:workspace_id, :workspace_root, :relative_path, :request_id, :generation]
    defstruct [
      :workspace_id,
      :workspace_root,
      :relative_path,
      :request_id,
      :generation,
      :display_name,
      :kind,
      :mime
    ]

    @type t :: %__MODULE__{
            workspace_id: String.t(),
            workspace_root: String.t(),
            relative_path: String.t(),
            request_id: String.t(),
            generation: integer(),
            display_name: String.t() | nil,
            kind: :text | :image | :external | nil,
            mime: String.t() | nil
          }

    def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

    def new(attrs) when is_map(attrs) do
      workspace_id = string(attrs, :workspace_id)
      workspace_root = string(attrs, :workspace_root)
      relative_path = string(attrs, :relative_path)
      request_id = string(attrs, :request_id)
      generation = integer(attrs, :generation)

      if workspace_id && workspace_root && relative_path && request_id && generation do
        {:ok,
         %__MODULE__{
           workspace_id: workspace_id,
           workspace_root: workspace_root,
           relative_path: relative_path,
           request_id: request_id,
           generation: generation,
           display_name: string(attrs, :display_name) || Path.basename(relative_path),
           kind: kind(attrs),
           mime: string(attrs, :mime)
         }}
      else
        {:error, :invalid_identity}
      end
    end

    def new(_), do: {:error, :invalid_identity}

    def same_file?(%__MODULE__{} = a, %__MODULE__{} = b) do
      a.workspace_id == b.workspace_id and
        a.relative_path == b.relative_path and
        a.request_id == b.request_id and
        a.generation == b.generation
    end

    def same_file?(_, _), do: false

    # `attrs` come from `NativeWorkspaceOpen.authorize/2` (atom keys only).
    defp string(attrs, key) do
      case Map.get(attrs, key) do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end
    end

    defp integer(attrs, key) do
      case Map.get(attrs, key) do
        value when is_integer(value) ->
          value

        value when is_binary(value) ->
          case Integer.parse(value) do
            {n, ""} -> n
            _ -> nil
          end

        _ ->
          nil
      end
    end

    defp kind(attrs) do
      case Map.get(attrs, :kind) do
        kind when kind in [:text, :image, :external] -> kind
        "text" -> :text
        "image" -> :image
        "external" -> :external
        _ -> nil
      end
    end
  end

  @snapshot_keys ~w(snapshot_id path display_name size_bytes mime state owner_request_id)
  @max_text_bytes 1_048_576
  @max_image_bytes 32 * 1024 * 1024

  def new, do: %__MODULE__{}
  def snapshot_keys, do: @snapshot_keys
  def max_text_bytes, do: @max_text_bytes
  def max_image_bytes, do: @max_image_bytes

  @spec prepare(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def prepare(attrs) do
    with {:ok, identity} <- Identity.new(attrs),
         {:ok, _path} <-
           WorkspaceFiles.resolve(identity.workspace_root, identity.relative_path, :file),
         {:ok, kind, mime} <- WorkspaceFiles.kind_from_name(identity.display_name) do
      identity = %{identity | kind: kind, mime: mime}
      status = if kind == :external, do: :external, else: :ready
      {:ok, %__MODULE__{identity: identity, status: status}}
    end
  end

  def close(%__MODULE__{} = state), do: %{state | identity: nil, status: :closed, error: nil}

  @spec export(Identity.t(), keyword()) :: {:ok, :async} | {:ok, map()} | {:error, term()}
  def export(%Identity{} = identity, opts \\ []) do
    export = Keyword.get(opts, :export) || (&default_export/5)
    caller = Keyword.get(opts, :caller, self())

    export.(
      caller,
      identity.request_id,
      identity.generation,
      identity.workspace_root,
      identity.relative_path
    )
  end

  def viewer_node(%__MODULE__{identity: %Identity{} = identity, status: status} = state) do
    if HandbeanProbe.NativePlatform.ios?() do
      ios_viewer_node(identity, status, state)
    else
      node(
        :file_viewer,
        id: "file-viewer-#{identity.request_id}-#{identity.generation}",
        workspace_id: identity.workspace_id,
        workspace_root: identity.workspace_root,
        relative_path: identity.relative_path,
        request_id: identity.request_id,
        generation: identity.generation,
        display_name: identity.display_name,
        kind: kind_name(identity.kind),
        mime: identity.mime || "",
        status: Atom.to_string(status),
        error: error_text(state.error)
      )
    end
  end

  def viewer_node(%__MODULE__{}), do: nil

  defp ios_viewer_node(identity, status, state) do
    preview = ios_preview(identity, status, state)

    node(
      :column,
      [
        id: "file-viewer-#{identity.request_id}-#{identity.generation}",
        fill_width: true,
        padding: 16
      ],
      [
        text(identity.display_name || identity.relative_path, text_size: 16),
        text(kind_name(identity.kind), text_size: 13, text_color: color(:muted), padding_top: 6),
        preview_status(preview),
        preview_body(identity, preview)
      ]
    )
  end

  @doc false
  def ios_preview(%Identity{} = identity, status, state \\ %__MODULE__{}) do
    cond do
      status == :error ->
        %{
          kind: :error,
          message: error_text(state.error) || gettext("Unable to display this file.")
        }

      status == :external or identity.kind == :external ->
        %{kind: :external, message: gettext("This format opens in another app.")}

      identity.kind == :image ->
        image_preview(identity)

      true ->
        text_preview(identity)
    end
  end

  defp preview_status(%{kind: kind}) when kind in [:text, :image, :truncated] do
    text("ready", text_size: 12, text_color: color(:hint), padding_top: 4)
  end

  defp preview_status(%{kind: kind}) do
    text(Atom.to_string(kind), text_size: 12, text_color: color(:hint), padding_top: 4)
  end

  defp preview_body(_identity, %{kind: :text, text: body, truncated: truncated}) do
    children = [
      if(truncated,
        do:
          text(gettext("Truncated to 1 MiB."),
            text_size: 12,
            text_color: color(:muted),
            padding_top: 8
          )
      ),
      scroll(
        [text(body, text_size: 13, padding_top: 8)],
        fill_width: true,
        weight: 1
      )
    ]

    node(:column, [fill_width: true, weight: 1], children)
  end

  defp preview_body(identity, %{kind: :image, path: path}) do
    NativeLocalImage.card_image(path, identity.display_name || identity.relative_path,
      padding_top: 12
    )
  end

  defp preview_body(_identity, %{message: message}) when is_binary(message) and message != "" do
    text(message, text_size: 13, text_color: color(:muted), padding_top: 8)
  end

  defp preview_body(_identity, _), do: nil

  defp text_preview(identity) do
    with {:ok, path} <-
           WorkspaceFiles.resolve(identity.workspace_root, identity.relative_path, :file),
         {:ok, bytes, truncated} <- read_text_bytes(path),
         :ok <- reject_binary(bytes) do
      case decode_utf8(bytes, truncated) do
        {:ok, text} ->
          %{kind: :text, text: text, truncated: truncated}

        :invalid_utf8 ->
          %{kind: :invalid_utf8, message: gettext("Not valid UTF-8 text.")}
      end
    else
      :binary ->
        %{kind: :binary, message: gettext("This is a binary file and cannot be shown as text.")}

      {:error, _} ->
        %{kind: :error, message: gettext("Unable to display this file.")}
    end
  end

  defp image_preview(identity) do
    with {:ok, path} <-
           WorkspaceFiles.resolve(identity.workspace_root, identity.relative_path, :file),
         {:ok, %File.Stat{type: :regular, size: size}} <- File.lstat(path),
         true <- size > 0 and size <= @max_image_bytes,
         true <- NativeLocalImage.local_file_src?(path) do
      %{kind: :image, path: path}
    else
      _ ->
        %{kind: :error, message: gettext("Unable to display this file.")}
    end
  end

  defp read_text_bytes(path) do
    case File.open(path, [:read, :raw, :binary]) do
      {:ok, io} ->
        try do
          data = IO.binread(io, @max_text_bytes + 1)

          case data do
            :eof ->
              {:ok, "", false}

            bin when is_binary(bin) ->
              truncated = byte_size(bin) > @max_text_bytes
              {:ok, binary_part(bin, 0, min(byte_size(bin), @max_text_bytes)), truncated}

            {:error, reason} ->
              {:error, reason}
          end
        after
          File.close(io)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reject_binary(bytes) when is_binary(bytes) do
    if :binary.match(bytes, <<0>>) == :nomatch, do: :ok, else: :binary
  end

  defp decode_utf8(bytes, truncated) do
    sample = if truncated, do: drop_incomplete_utf8(bytes), else: bytes

    if String.valid?(sample) do
      {:ok, sample}
    else
      :invalid_utf8
    end
  end

  defp drop_incomplete_utf8(bytes) when byte_size(bytes) == 0, do: bytes

  defp drop_incomplete_utf8(bytes) do
    size = byte_size(bytes)
    drop = utf8_tail_drop(bytes, size)
    binary_part(bytes, 0, size - drop)
  end

  # Incomplete UTF-8 at the 1 MiB cap is dropped; a real EOF fragment is not.
  defp utf8_tail_drop(bytes, size) do
    last = :binary.at(bytes, size - 1)

    cond do
      last <= 0x7F ->
        0

      last in 0xC2..0xF4 ->
        1

      size >= 2 and :binary.at(bytes, size - 2) in 0xE0..0xF4 ->
        2

      size >= 3 and :binary.at(bytes, size - 3) in 0xF0..0xF4 ->
        3

      last >= 0x80 ->
        1

      true ->
        0
    end
  end

  defp default_export(caller, request_id, generation, workspace_root, relative_path) do
    HandbeanProbe.Platform.export_file(
      caller,
      request_id,
      generation,
      workspace_root,
      relative_path
    )
  end

  defp kind_name(nil), do: ""
  defp kind_name(kind), do: Atom.to_string(kind)
  defp error_text(nil), do: ""
  defp error_text(reason), do: inspect(reason)
end
