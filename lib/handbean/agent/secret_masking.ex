defmodule Handbean.Agent.SecretMasking do
  @moduledoc """
  Pure secret detection, placeholder generation and restoration primitives.

  The high-confidence secret patterns are adapted from yetone/magpie's local
  redaction rules (MIT, copyright 2026 yetone). Handbean intentionally excludes
  Magpie's personal-data, model-assisted and custom-policy features.
  """

  @placeholder_body ~r/[A-Za-z][A-Za-z0-9_]*_[A-Za-z2-7]{8,52}/
  @token_chars "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"
  @alnum "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

  @rules [
    {:private_key,
     ~r/-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?-----[\s\S]+?-----END (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?-----/,
     0, :always},
    {:api_key, ~r/sk-(?:ant-|proj-|or-|svcacct-|admin-)?[A-Za-z0-9_-]{20,}/, 0,
     {:bounded, @token_chars}},
    {:api_key, ~r/[a-z]{2,4}_sk_[A-Za-z0-9_-]{20,}/, 0, {:bounded, @token_chars}},
    {:api_key,
     ~r/(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|glpat-[A-Za-z0-9_-]{20,})/, 0,
     {:bounded, @token_chars}},
    {:api_key, ~r/AIza[0-9A-Za-z_-]{35}/, 0, {:bounded, @token_chars}},
    {:api_key, ~r/xox[abposr]-[0-9A-Za-z-]{10,}/, 0, {:bounded, @token_chars}},
    {:api_key, ~r/(?:sk|rk)_live_[0-9A-Za-z]{20,}/, 0, {:bounded, @token_chars}},
    {:api_key, ~r/(?:AKIA|ASIA)[0-9A-Z]{16}/, 0, {:bounded, @alnum}},
    {:api_key,
     ~r/(?:hf_[A-Za-z0-9]{30,}|gsk_[A-Za-z0-9]{40,}|xai-[A-Za-z0-9]{40,}|npm_[A-Za-z0-9]{36}|pypi-[A-Za-z0-9_-]{50,}|dop_v1_[a-f0-9]{64}|SG\.[A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{43})/,
     0, {:bounded, @token_chars}},
    {:token, ~r/eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/, 0,
     {:bounded, @token_chars}},
    {:password, ~r/[A-Za-z][A-Za-z0-9+.-]*:\/\/[^\s:@\/?#"'<>]*:([^\s@\/?#"'<>]{3,})@/, 1,
     :not_variable},
    {:secret,
     ~r/(?i)[A-Za-z0-9_.-]*(?:password|passwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key|credential)[A-Za-z0-9_.-]*(?:\\?["'])?[ \t]*[:=][ \t]*(?:\\?["'])?([A-Za-z0-9_\-.\/+\=~!@#%^&*]{8,})/,
     1, :secret_value},
    {:secret,
     ~r/(?i)(?:^|[^A-Za-z0-9_.-])(?:\\?["'])?key(?:\\?["'])?[ \t]*[:=][ \t]*(?:\\?["'])?([A-Za-z0-9_\-.\/+\=~!@#%^&*]{16,})/,
     1, :secret_value},
    {:password,
     ~r/(?i)(?:密码|密碼|口令|PIN ?码|PIN ?碼|安全码|安全碼|パスワード|暗証番号|비밀번호|암호|비번)[ \t]*(?:[:：=][ \t]*|[为為是][ \t]*[:：]?[ \t]*|は[ \t]*|는[ \t]*)?(?:\\?["'“「])?([A-Za-z0-9_\-.\/+\=~!@#%^&*]{4,64})/u,
     1, :not_variable},
    {:secret,
     ~r/(?i)(?:密钥|密鑰|秘钥|秘鑰|私钥|私鑰|金钥|金鑰|令牌|授权码|授權碼|秘密鍵|トークン|シークレット|API ?キー|アクセスキー|토큰|비밀키|API ?키)[ \t]*(?:[:：=][ \t]*|[为為是][ \t]*[:：]?[ \t]*|は[ \t]*|는[ \t]*)?(?:\\?["'“「])?([A-Za-z0-9_\-.\/+\=~!@#%^&*]{4,64})/u,
     1, :key_value}
  ]

  @type span :: %{
          required(:start) => non_neg_integer(),
          required(:length) => pos_integer(),
          required(:kind) => String.t(),
          required(:value) => String.t()
        }

  @spec detect(String.t()) :: [span()]
  def detect(text) when is_binary(text) do
    @rules
    |> Enum.flat_map(&rule_matches(text, &1))
    |> non_overlapping()
  end

  @spec placeholder(String.t(), String.t(), binary(), map()) ::
          {:ok, String.t()} | {:error, :placeholder_collision}
  def placeholder(kind, value, key, placeholders)
      when is_binary(kind) and is_binary(value) and is_binary(key) and is_map(placeholders) do
    digest =
      :crypto.mac(:hmac, :sha256, key, kind <> <<0>> <> value)
      |> Base.encode32(case: :lower, padding: false)

    Enum.find_value([8, 12, 16, 24, 32, 40, 52], {:error, :placeholder_collision}, fn size ->
      candidate = "{{#{kind}_#{binary_part(digest, 0, size)}}}"

      case Map.get(placeholders, candidate) do
        nil -> {:ok, candidate}
        ^value -> {:ok, candidate}
        _other -> false
      end
    end)
  end

  @spec restore(String.t(), map()) :: String.t()
  def restore(text, restore_map) when is_binary(text) and is_map(restore_map) do
    aliases =
      Map.new(restore_map, fn {placeholder, value} ->
        {placeholder_body(placeholder) |> String.downcase(), value}
      end)

    @placeholder_body
    |> Regex.scan(text, return: :index, capture: :first)
    |> Enum.reduce({[], 0}, fn [{start, length}], {parts, cursor} ->
      body = binary_part(text, start, length)

      with true <- start >= cursor,
           false <- word_byte_before?(text, start),
           false <- word_byte_after?(text, start + length),
           {:ok, value} <- Map.fetch(aliases, String.downcase(body)) do
        {expanded_start, expanded_end} = expand_braces(text, start, start + length)

        if expanded_start < cursor do
          {parts, cursor}
        else
          prefix = binary_part(text, cursor, expanded_start - cursor)
          {[value, prefix | parts], expanded_end}
        end
      else
        _other -> {parts, cursor}
      end
    end)
    |> then(fn {parts, cursor} ->
      tail = binary_part(text, cursor, byte_size(text) - cursor)
      IO.iodata_to_binary(Enum.reverse([tail | parts]))
    end)
  end

  @spec partial_placeholder_length(String.t(), map()) :: non_neg_integer()
  def partial_placeholder_length(text, restore_map \\ %{})

  def partial_placeholder_length("", _restore_map), do: 0

  def partial_placeholder_length(text, restore_map)
      when is_binary(text) and is_map(restore_map) do
    max = min(byte_size(text), 72)

    known_bodies =
      restore_map |> Map.keys() |> MapSet.new(&(placeholder_body(&1) |> String.downcase()))

    Enum.find_value(max..1//-1, 0, fn length ->
      tail = binary_part(text, byte_size(text) - length, length)
      if partial_placeholder?(tail, known_bodies), do: length
    end)
  end

  @spec standalone?(String.t(), non_neg_integer(), pos_integer()) :: boolean()
  def standalone?(text, start, length) do
    before = if start > 0, do: :binary.at(text, start - 1)
    after_at = start + length
    after_byte = if after_at < byte_size(text), do: :binary.at(text, after_at)
    first = :binary.at(text, start)
    last = :binary.at(text, after_at - 1)

    not (ascii_alnum?(before) and ascii_alnum?(first)) and
      not (ascii_alnum?(after_byte) and ascii_alnum?(last))
  end

  defp rule_matches(text, {kind, regex, capture, validator}) do
    Regex.scan(regex, text, return: :index, capture: :all)
    |> Enum.flat_map(fn indexes ->
      case Enum.at(indexes, capture) do
        {start, length} when start >= 0 and length > 0 ->
          value = binary_part(text, start, length)

          if valid?(validator, text, start, length, value) do
            [%{start: start, length: length, kind: kind_name(kind), value: value}]
          else
            []
          end

        _other ->
          []
      end
    end)
  end

  defp valid?(:always, _text, _start, _length, _value), do: true
  defp valid?(:not_variable, _text, _start, _length, value), do: not_variable?(value)
  defp valid?(:secret_value, _text, _start, _length, value), do: secret_value?(value)
  defp valid?(:key_value, _text, _start, _length, value), do: key_value?(value)

  defp valid?({:bounded, chars}, text, start, length, _value) do
    boundary_clear?(text, start - 1, chars) and
      boundary_clear?(text, start + length, chars)
  end

  defp boundary_clear?(text, index, _chars) when index < 0 or index >= byte_size(text), do: true

  defp boundary_clear?(text, index, chars),
    do: :binary.at(text, index) not in :binary.bin_to_list(chars)

  defp not_variable?(value) do
    first = binary_part(value, 0, 1)
    first not in ["$", "%", "{", "<", "[", "*"] and String.trim(value, "*xX.") != ""
  end

  defp secret_value?(value) do
    not_variable?(value) and not String.starts_with?(value, ["process.env", "os."]) and
      Regex.match?(~r/[A-Za-z]/, value) and Regex.match?(~r/[0-9]/, value)
  end

  defp key_value?(value) do
    not_variable?(value) and Regex.match?(~r/[A-Za-z]/, value) and
      (Regex.match?(~r/[0-9]/, value) or byte_size(value) >= 16)
  end

  defp kind_name(kind), do: kind |> Atom.to_string() |> String.upcase()

  defp placeholder_body(placeholder) do
    binary_part(placeholder, 2, byte_size(placeholder) - 4)
  end

  defp word_byte_before?(_text, 0), do: false

  defp word_byte_before?(text, start) do
    word_byte?(:binary.at(text, start - 1))
  end

  defp word_byte_after?(text, finish) when finish == byte_size(text), do: false

  defp word_byte_after?(text, finish) do
    word_byte?(:binary.at(text, finish))
  end

  defp word_byte?(byte) do
    byte in ?A..?Z or byte in ?a..?z or byte in ?0..?9 or byte == ?_
  end

  defp expand_braces(text, start, finish) do
    {left_start, left_braces} = scan_left_braces(text, scan_left_space(text, start), 0)
    {right_end, right_braces} = scan_right_braces(text, scan_right_space(text, finish), 0)

    expanded_start =
      if left_braces == 2 or (left_braces == 1 and right_braces >= 1),
        do: left_start,
        else: start

    expanded_end =
      if right_braces == 2 or (right_braces == 1 and left_braces >= 1),
        do: right_end,
        else: finish

    {expanded_start, expanded_end}
  end

  defp scan_left_space(text, index) when index > 0 do
    if :binary.at(text, index - 1) in [32, 9],
      do: scan_left_space(text, index - 1),
      else: index
  end

  defp scan_left_space(_text, index), do: index

  defp scan_left_braces(text, index, count) when index > 0 and count < 2 do
    if :binary.at(text, index - 1) == ?{,
      do: scan_left_braces(text, index - 1, count + 1),
      else: {index, count}
  end

  defp scan_left_braces(_text, index, count), do: {index, count}

  defp scan_right_space(text, index) when index < byte_size(text) do
    if :binary.at(text, index) in [32, 9],
      do: scan_right_space(text, index + 1),
      else: index
  end

  defp scan_right_space(_text, index), do: index

  defp scan_right_braces(text, index, count) when index < byte_size(text) and count < 2 do
    if :binary.at(text, index) == ?},
      do: scan_right_braces(text, index + 1, count + 1),
      else: {index, count}
  end

  defp scan_right_braces(_text, index, count), do: {index, count}

  defp non_overlapping(spans) do
    spans
    |> Enum.sort_by(&{&1.start, -&1.length})
    |> Enum.reduce({[], 0}, fn span, {kept, next_start} ->
      if span.start >= next_start do
        {[span | kept], span.start + span.length}
      else
        {kept, next_start}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp partial_placeholder?("{", _known_bodies), do: true
  defp partial_placeholder?("{{", _known_bodies), do: true

  defp partial_placeholder?(tail, known_bodies) do
    partial_braced_placeholder?(tail, known_bodies) or
      partial_unbraced_placeholder?(tail, known_bodies)
  end

  defp partial_braced_placeholder?(tail, known_bodies) do
    case Regex.run(~r/^\{\{?[ \t]*([A-Za-z][A-Za-z0-9_]*)(?:[ \t]*\}?)?$/, tail) do
      [_, body] -> known_body_prefix?(body, known_bodies)
      _other -> false
    end
  end

  defp partial_unbraced_placeholder?(tail, known_bodies) do
    case tail do
      <<first, _rest::binary>> when first in ?A..?Z ->
        Regex.match?(~r/^[A-Za-z][A-Za-z0-9_]*$/, tail) and
          known_body_prefix?(tail, known_bodies)

      _other ->
        false
    end
  end

  defp known_body_prefix?(body, known_bodies) do
    downcased = String.downcase(body)

    if MapSet.size(known_bodies) == 0 do
      Regex.match?(~r/^[A-Z][A-Z0-9_]*(?:_[a-z2-7]*)?$/, body)
    else
      Enum.any?(known_bodies, &String.starts_with?(&1, downcased))
    end
  end

  defp ascii_alnum?(byte) when byte in ?0..?9, do: true
  defp ascii_alnum?(byte) when byte in ?A..?Z, do: true
  defp ascii_alnum?(byte) when byte in ?a..?z, do: true
  defp ascii_alnum?(_byte), do: false
end
