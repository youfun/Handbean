defmodule Handbean.Agent.SecretMasking.Store do
  @moduledoc false

  use GenServer

  alias Handbean.Agent.SecretMasking
  alias Handbean.Agent.SecretMasking.Transformer

  @default_max_known 2_048
  @default_max_sent 8_192
  @call_timeout 30_000
  @rule_version 1

  defstruct key: nil,
            directory: nil,
            known: %{},
            known_order: :queue.new(),
            placeholders: %{},
            sent: %{},
            sent_order: :queue.new(),
            max_known: @default_max_known,
            max_sent: @default_max_sent

  @type prepared :: %{
          required(:messages) => list(),
          required(:tools) => list(),
          required(:config) => map(),
          required(:restore) => map()
        }

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec prepare([Handbean.Agent.Message.t()], [map()], map(), GenServer.server()) ::
          {:ok, prepared()} | {:error, term()}
  def prepare(messages, tools, config, server \\ __MODULE__) do
    GenServer.call(server, {:prepare, messages, tools, config}, @call_timeout)
  catch
    :exit, reason -> {:error, {:secret_masking_store_unavailable, reason}}
  end

  @impl true
  def init(opts) do
    directory =
      Keyword.get(opts, :directory) ||
        Application.get_env(:handbean, :secret_masking_directory) ||
        Path.join([Handbean.Home.path(), ".handbean", "secret-masking"])

    {:ok,
     %__MODULE__{
       directory: directory,
       max_known: Keyword.get(opts, :max_known, @default_max_known),
       max_sent: Keyword.get(opts, :max_sent, @default_max_sent)
     }}
  end

  @impl true
  def handle_call({:prepare, messages, tools, config}, _from, state) do
    result =
      with {:ok, state} <- ensure_key(state),
           {:ok, texts} <- Transformer.regular_texts(messages, tools, config),
           {:ok, masked, current, restore, state} <- mask_regular_texts(texts, state),
           {:ok, request, _restore, state} <-
             transform_request(messages, tools, config, masked, current, restore, state) do
        {:ok, request, state}
      end

    case result do
      {:ok, request, state} -> {:reply, {:ok, request}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp mask_regular_texts(texts, state) do
    texts
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, %{}, %{}, %{}, state}, fn text,
                                                         {:ok, masked, current, restore, state} ->
      case mask_regular(text, state) do
        {:ok, output, detected, local_restore, state} ->
          {:cont,
           {:ok, Map.put(masked, text, output), Map.merge(current, detected),
            Map.merge(restore, local_restore), state}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp transform_request(messages, tools, config, masked, current, restore, state) do
    regular = &Map.fetch!(masked, &1)

    with {:ok, signed_masked, restore, state} <-
           mask_signed_texts(signed_texts(messages), current, restore, state),
         {:ok, {messages, tools, config}} <-
           Transformer.mask_request(
             messages,
             tools,
             config,
             regular,
             &Map.fetch!(signed_masked, &1)
           ) do
      request = %{messages: messages, tools: tools, config: config, restore: restore}
      {:ok, request, restore, state}
    end
  end

  defp mask_signed_texts(texts, current, restore, state) do
    texts
    |> Enum.uniq()
    |> Enum.reduce({:ok, %{}, restore, state}, fn text, {:ok, masked, restore, state} ->
      {:ok, output, local_restore, state} = mask_signed(text, current, state)
      {:ok, Map.put(masked, text, output), Map.merge(restore, local_restore), state}
    end)
  end

  defp mask_regular(text, state) do
    with {:ok, direct, detected, state} <- direct_spans(text, state),
         {known, state} <- sent_known_spans(text, state) do
      spans = merge_spans(direct ++ known)
      {output, restore} = apply_spans(text, spans)
      {:ok, output, detected, restore, state}
    end
  end

  defp mask_signed(text, current, state) do
    exact = exact_spans(text, current)
    {known, state} = sent_known_spans(text, state)
    spans = merge_spans(exact ++ known)
    {output, restore} = apply_spans(text, spans)
    {:ok, output, restore, state}
  end

  defp direct_spans(text, state) do
    Enum.reduce_while(SecretMasking.detect(text), {:ok, [], %{}, state}, fn span,
                                                                            {:ok, spans, detected,
                                                                             state} ->
      case placeholder_for(span.kind, span.value, state) do
        {:ok, placeholder, state} ->
          masked = Map.put(span, :placeholder, placeholder)

          {:cont, {:ok, [masked | spans], Map.put(detected, span.value, placeholder), state}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, spans, detected, state} -> {:ok, Enum.reverse(spans), detected, state}
      error -> error
    end
  end

  defp placeholder_for(kind, value, state) do
    case Map.get(state.known, value) do
      %{placeholder: placeholder} ->
        {:ok, placeholder, state}

      nil ->
        with {:ok, placeholder} <-
               SecretMasking.placeholder(kind, value, state.key, state.placeholders) do
          entry = %{placeholder: placeholder, kind: kind}

          state = %{
            state
            | known: Map.put(state.known, value, entry),
              known_order: :queue.in(value, state.known_order),
              placeholders: Map.put(state.placeholders, placeholder, value)
          }

          {:ok, placeholder, trim_known(state)}
        end
    end
  end

  defp sent_known_spans(text, state) do
    key = :crypto.hash(:sha256, <<@rule_version::32, text::binary>>)

    case Map.fetch(state.sent, key) do
      {:ok, spans} ->
        {spans, state}

      :error ->
        spans = known_spans(text, state.known)

        state = %{
          state
          | sent: Map.put(state.sent, key, spans),
            sent_order: :queue.in(key, state.sent_order)
        }

        {spans, trim_sent(state)}
    end
  end

  defp known_spans(text, known) do
    known
    |> Enum.sort_by(fn {value, _entry} -> -byte_size(value) end)
    |> Enum.flat_map(fn {value, %{placeholder: placeholder, kind: kind}} ->
      if byte_size(value) >= 8 do
        for {start, length} <- :binary.matches(text, value),
            SecretMasking.standalone?(text, start, length) do
          %{
            start: start,
            length: length,
            value: value,
            kind: kind,
            placeholder: placeholder
          }
        end
      else
        []
      end
    end)
    |> merge_spans()
  end

  defp exact_spans(text, replacements) do
    replacements
    |> Enum.sort_by(fn {value, _placeholder} -> -byte_size(value) end)
    |> Enum.flat_map(fn {value, placeholder} ->
      for {start, length} <- :binary.matches(text, value) do
        %{start: start, length: length, value: value, kind: nil, placeholder: placeholder}
      end
    end)
  end

  defp merge_spans(spans) do
    spans
    |> Enum.sort_by(&{&1.start, -&1.length})
    |> Enum.reduce({[], 0}, fn span, {kept, next_start} ->
      if span.start >= next_start,
        do: {[span | kept], span.start + span.length},
        else: {kept, next_start}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp apply_spans(text, spans) do
    Enum.reduce(Enum.reverse(spans), {text, %{}}, fn span, {output, restore} ->
      prefix = binary_part(output, 0, span.start)
      suffix_start = span.start + span.length
      suffix = binary_part(output, suffix_start, byte_size(output) - suffix_start)

      {prefix <> span.placeholder <> suffix, Map.put(restore, span.placeholder, span.value)}
    end)
  end

  defp trim_known(state) when map_size(state.known) <= state.max_known, do: state

  defp trim_known(state) do
    {{:value, value}, order} = :queue.out(state.known_order)
    %{placeholder: placeholder} = Map.fetch!(state.known, value)

    trim_known(%{
      state
      | known: Map.delete(state.known, value),
        known_order: order,
        placeholders: Map.delete(state.placeholders, placeholder)
    })
  end

  defp trim_sent(state) when map_size(state.sent) <= state.max_sent, do: state

  defp trim_sent(state) do
    {{:value, key}, order} = :queue.out(state.sent_order)
    trim_sent(%{state | sent: Map.delete(state.sent, key), sent_order: order})
  end

  defp signed_texts(messages) do
    Enum.flat_map(messages, fn
      %Handbean.Agent.Message{content: blocks} when is_list(blocks) ->
        Enum.flat_map(blocks, fn block ->
          type = block[:type] || block["type"]
          signature = block[:signature] || block["signature"]
          thinking = block[:thinking] || block["thinking"]

          if type == "thinking" and is_binary(signature) and signature != "" and
               is_binary(thinking),
             do: [thinking],
             else: []
        end)

      _message ->
        []
    end)
  end

  defp ensure_key(%{key: key} = state) when is_binary(key), do: {:ok, state}

  defp ensure_key(state) do
    with :ok <- ensure_private_directory(state.directory),
         {:ok, key} <- read_or_create_key(Path.join(state.directory, "key")) do
      {:ok, %{state | key: key}}
    end
  end

  defp ensure_private_directory(directory) do
    with :ok <- File.mkdir_p(directory),
         {:ok, %{type: :directory}} <- File.lstat(directory),
         :ok <- File.chmod(directory, 0o700),
         {:ok, %{type: :directory, mode: mode}} <- File.lstat(directory),
         true <- Bitwise.band(mode, 0o077) == 0 do
      :ok
    else
      _other -> {:error, :secret_masking_storage_failed}
    end
  end

  defp read_or_create_key(path) do
    case private_read(path) do
      {:ok, key} when byte_size(key) == 32 ->
        {:ok, key}

      {:ok, _invalid} ->
        {:error, :invalid_secret_masking_key}

      {:error, :enoent} ->
        key = :crypto.strong_rand_bytes(32)

        case create_key(path, key) do
          :ok -> {:ok, key}
          {:error, :eexist} -> private_read_valid_key(path)
          _other -> {:error, :secret_masking_storage_failed}
        end

      {:error, _reason} ->
        {:error, :secret_masking_storage_failed}
    end
  end

  defp private_read_valid_key(path) do
    case private_read(path) do
      {:ok, key} when byte_size(key) == 32 -> {:ok, key}
      {:ok, _invalid} -> {:error, :invalid_secret_masking_key}
      _other -> {:error, :secret_masking_storage_failed}
    end
  end

  defp private_read(path) do
    with {:ok, %{type: :regular, mode: mode}} <- File.lstat(path),
         true <- Bitwise.band(mode, 0o077) == 0 do
      File.read(path)
    else
      {:error, :enoent} -> {:error, :enoent}
      _other -> {:error, :unsafe_secret_masking_key}
    end
  end

  defp create_key(path, key) do
    with {:ok, io} <- File.open(path, [:write, :binary, :exclusive]) do
      result =
        with :ok <- File.chmod(path, 0o600),
             :ok <- IO.binwrite(io, key),
             do: :file.sync(io)

      File.close(io)
      result
    end
  end
end
