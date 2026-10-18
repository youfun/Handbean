defmodule HandbeanProbe.GuardTest do
  @moduledoc """
  Static guards against merge regressions in `handbean_probe/lib` (tech-debt plan WP1).

  Pure source scans, no runtime. Each guard walks the quoted AST so comments,
  `@doc` / `@moduledoc`, and `*gettext(` call arguments are never counted.

  Whitelists record files that violate a rule *today*. A whitelisted file that
  stops violating fails the test as a "stale whitelist" entry so the list only
  shrinks. Files outside the whitelist must be clean.
  """

  use ExUnit.Case, async: true

  @lib_root Path.expand("../../lib", __DIR__)

  # WP12 cleared this list. CJK literals must go through gettext; keep empty so
  # any new one fails.
  @cjk_whitelist []

  # The only file allowed to hold hex color literals.
  @hex_palette "handbean_probe/native_ui.ex"

  # WP12 cleared this list. Hex must use NativeUI.color/1; keep empty.
  @hex_whitelist []

  # browser/nif.ex nif_map/1 was fixed by WP3; keep empty so any new call fails.
  @to_atom_whitelist []

  @doc_attrs [:doc, :moduledoc, :typedoc, :shortdoc]

  # PCRE2 resolves `\p{Han}` via Script_Extensions, which also covers Common
  # punctuation such as U+00B7 "·" and the U+02C7.. tone marks. Those appear in
  # Latin UI separators, so exclude them explicitly.
  @han ~r/(?![\x{00B7}\x{02C7}\x{02C9}-\x{02CB}\x{02CD}\x{02D9}])\p{Han}/u
  @hex ~r/#[0-9A-Fa-f]{6}\b/

  test "CJK literals appear only inside gettext, docs, or comments (WP12 whitelist)" do
    violations = scan(&literal_violations(&1, @han))
    assert_whitelisted(violations, @cjk_whitelist, "CJK literal outside gettext")
  end

  test "color hex literals live only in the native_ui palette (WP12 whitelist)" do
    violations =
      scan(&literal_violations(&1, @hex))
      |> Map.delete(@hex_palette)

    assert_whitelisted(violations, @hex_whitelist, "color hex outside #{@hex_palette}")
  end

  test "String.to_atom/1 is never called" do
    violations = scan(&to_atom_calls/1)
    assert_whitelisted(violations, @to_atom_whitelist, "String.to_atom/1 call")
  end

  # WP8: every host / sigil payload is decoded once (`HandbeanProbe.Bridge.Inbound`,
  # `HandbeanProbe.Bridge.Payload`, `Handbean.TranscriptEntry`), so no reader may fall
  # back between an atom key and a string key. Keep empty so any new one fails.
  @dual_key_whitelist []

  # Textual form of the same rule, e.g. `m[:k] || m["k"]`.
  @dual_key_text ~r/\[:\w+\]\s*\|\|\s*\w+\["/

  test "no atom-or-string dual key lookups (m[:k] || m[\"k\"], value/2, field/2 helpers)" do
    violations = scan(&dual_key_lookups/1)
    assert_whitelisted(violations, @dual_key_whitelist, "dual key lookup")

    text_hits =
      @lib_root
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.reduce(%{}, fn path, acc ->
        hits =
          path
          |> File.read!()
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.filter(fn {line, _} -> Regex.match?(@dual_key_text, line) end)
          |> Enum.map(fn {line, no} -> {no, String.slice(String.trim(line), 0, 40)} end)

        if hits == [], do: acc, else: Map.put(acc, Path.relative_to(path, @lib_root), hits)
      end)

    assert_whitelisted(text_hits, @dual_key_whitelist, "dual key lookup text")
  end

  describe "JNI string safety" do
    @c_src_root Path.expand("../../c_src", __DIR__)

    # Modified UTF-8 corrupts non-BMP text (emoji). WP5 moved handbean_browser.c and
    # handbean_notify.c to jbyteArray; keep empty so any new use fails.
    @jni_utf8_whitelist []
    @jni_utf8_calls ~r/\b(NewStringUTF|GetStringUTFChars)\(/
    @c_comments ~r{/\*.*?\*/|//[^\n]*}s

    test "c_src never converts strings through NewStringUTF/GetStringUTFChars" do
      violations =
        @c_src_root
        |> Path.join("*.c")
        |> Path.wildcard()
        |> Enum.sort()
        |> Enum.reduce(%{}, fn path, acc ->
          case jni_utf8_calls(File.read!(path)) do
            [] -> acc
            hits -> Map.put(acc, Path.relative_to(path, @c_src_root), hits)
          end
        end)

      assert_whitelisted(violations, @jni_utf8_whitelist, "Modified UTF-8 JNI string call")
    end

    # Comments are blanked (not removed) so line numbers stay accurate.
    defp jni_utf8_calls(source) do
      source
      |> then(&Regex.replace(@c_comments, &1, fn m -> String.replace(m, ~r/[^\n]/, " ") end))
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, no} ->
        @jni_utf8_calls
        |> Regex.scan(line)
        |> Enum.map(fn [_, name] -> {no, name <> "("} end)
      end)
    end
  end

  # ── scanning ──

  # Returns %{relative_path => [{line, snippet}]} for files with at least one hit.
  defp scan(collector) do
    @lib_root
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.reduce(%{}, fn path, acc ->
      case path |> quoted!() |> collector.() |> Enum.uniq_by(&elem(&1, 0)) do
        [] -> acc
        hits -> Map.put(acc, Path.relative_to(path, @lib_root), Enum.sort(hits))
      end
    end)
  end

  defp quoted!(path) do
    {:ok, ast} =
      path
      |> File.read!()
      |> Code.string_to_quoted(
        file: path,
        token_metadata: true,
        literal_encoder: &{:ok, {:__literal__, &2, [&1]}}
      )

    ast
  end

  # String and atom literals matching `regex`, skipping doc attributes and
  # any `*gettext(` call (local or remote) together with its arguments.
  defp literal_violations(ast, regex) do
    {_, hits} =
      Macro.prewalk(ast, [], fn
        {:@, _, [{attr, _, _}]}, acc when attr in @doc_attrs ->
          {:__pruned__, acc}

        {:__literal__, meta, [lit]} = node, acc when is_binary(lit) or is_atom(lit) ->
          {node, match(acc, meta, to_string(lit), regex)}

        {:<<>>, meta, parts} = node, acc ->
          acc =
            parts
            |> Enum.filter(&is_binary/1)
            |> Enum.reduce(acc, &match(&2, meta, &1, regex))

          {node, acc}

        {{:., _, [_, fun]}, _, args} = node, acc when is_atom(fun) and is_list(args) ->
          if gettext_name?(fun), do: {:__pruned__, acc}, else: {node, acc}

        {fun, _, args} = node, acc when is_atom(fun) and is_list(args) ->
          if gettext_name?(fun), do: {:__pruned__, acc}, else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    hits
  end

  defp to_atom_calls(ast) do
    {_, hits} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, [:String]}, :to_atom]}, meta, _} = node, acc ->
          {node, [{Keyword.get(meta, :line, 0), "String.to_atom("} | acc]}

        node, acc ->
          {node, acc}
      end)

    hits
  end

  # A `||` chain is a violation when two operands read the *same* subject with
  # an atom key and a string key (`m[:k] || m["k"]`, `Map.get(m, :k) || Map.get(m, "k")`)
  # or with a key variable and its `Atom.to_string/1`
  # (`map[key] || map[Atom.to_string(key)]`, the classic `value/2` / `field/2` helper).
  defp dual_key_lookups(ast) do
    {_, hits} =
      Macro.prewalk(ast, [], fn
        {:||, meta, _} = node, acc ->
          lookups = node |> or_operands() |> Enum.map(&lookup/1) |> Enum.reject(&is_nil/1)

          if dual?(lookups),
            do: {node, [{Keyword.get(meta, :line, 0), "atom || string key lookup"} | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    hits
  end

  defp or_operands({:||, _, [left, right]}), do: or_operands(left) ++ or_operands(right)
  defp or_operands(other), do: [other]

  # `m[k]` (Access.get) or `Map.get(m, k)` → {subject, key kind}
  defp lookup({{:., _, [Access, :get]}, _, [subject, key]}), do: lookup(subject, key)

  defp lookup({{:., _, [{:__aliases__, _, [:Map]}, :get]}, _, [subject, key | _]}),
    do: lookup(subject, key)

  defp lookup(_), do: nil

  defp lookup(subject, key) do
    case key_kind(key) do
      nil -> nil
      kind -> {Macro.to_string(subject), kind}
    end
  end

  defp key_kind({:__literal__, _, [lit]}) when is_atom(lit), do: :atom
  defp key_kind({:__literal__, _, [lit]}) when is_binary(lit), do: :string

  defp key_kind({{:., _, [{:__aliases__, _, [:Atom]}, :to_string]}, _, [{var, _, ctx}]})
       when is_atom(var) and is_atom(ctx),
       do: {:to_string, var}

  defp key_kind({var, _, ctx}) when is_atom(var) and is_atom(ctx), do: {:var, var}
  defp key_kind(_), do: nil

  defp dual?(lookups) do
    by_subject = Enum.group_by(lookups, &elem(&1, 0), &elem(&1, 1))

    Enum.any?(by_subject, fn {_subject, kinds} ->
      (:atom in kinds and :string in kinds) or
        Enum.any?(kinds, fn
          {:var, var} -> {:to_string, var} in kinds
          _ -> false
        end)
    end)
  end

  defp gettext_name?(fun), do: fun |> Atom.to_string() |> String.ends_with?("gettext")

  defp match(acc, meta, text, regex) do
    if Regex.match?(regex, text),
      do: [{Keyword.get(meta, :line, 0), String.slice(text, 0, 40)} | acc],
      else: acc
  end

  # ── assertions ──

  defp assert_whitelisted(violations, whitelist, label) do
    unexpected = Map.drop(violations, whitelist)
    stale = whitelist -- Map.keys(violations)

    assert unexpected == %{}, """
    #{label} found outside the whitelist (#{count(unexpected)} hit(s)):
    #{format(unexpected)}
    """

    assert stale == [], """
    Stale whitelist: these files no longer violate "#{label}", remove them:
    #{Enum.map_join(stale, "\n", &("  " <> &1))}
    """
  end

  defp count(violations), do: violations |> Map.values() |> Enum.map(&length/1) |> Enum.sum()

  defp format(violations) do
    Enum.map_join(violations, "\n", fn {file, hits} ->
      Enum.map_join(hits, "\n", fn {line, snippet} ->
        "  #{file}:#{line}  #{inspect(snippet)}"
      end)
    end)
  end
end
