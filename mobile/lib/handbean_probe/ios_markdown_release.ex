defmodule HandbeanProbe.IosMarkdownRelease do
  @moduledoc false

  # `mix mob.release` rewrites ios/release_device.sh from mob_dev, then runs it.
  # A hand edit of that script never reaches TestFlight. This module splices the
  # markdown host overlay back into the generator before the rewrite.

  @marker "patch_markdown_host.sh"

  @spec install!() :: :ok
  def install! do
    path = generator_path()

    unless File.exists?(path) do
      Mix.raise("iOS markdown release patch needs #{path}")
    end

    unless script_ready?() do
      previous = Code.get_compiler_option(:ignore_module_conflict)
      Code.put_compiler_option(:ignore_module_conflict, true)

      try do
        Code.compile_string(patch_generator_source!(File.read!(path)), path)
      after
        Code.put_compiler_option(:ignore_module_conflict, previous)
      end
    end

    unless script_ready?() do
      Mix.raise("iOS markdown patch did not apply to the TestFlight release script")
    end

    :ok
  end

  @spec patch_script(String.t()) :: String.t()
  def patch_script(script) when is_binary(script) do
    patch(script)
  end

  @spec patch_generator_source!(String.t()) :: String.t()
  def patch_generator_source!(source) when is_binary(source) do
    patched = patch(source)

    unless String.contains?(patched, @marker) do
      Mix.raise("iOS markdown patch could not find the TestFlight compile anchors")
    end

    patched
  end

  defp script_ready? do
    release = Module.concat([:MobDev, :Release])

    Code.ensure_loaded?(release) and function_exported?(release, :release_device_sh, 0) and
      String.contains?(apply(release, :release_device_sh, []), @marker)
  end

  defp generator_path do
    Path.expand("deps/mob_dev/lib/mob_dev/release.ex")
  end

  defp patch(text) do
    if String.contains?(text, @marker) do
      text
    else
      text
      |> splice_overlay()
      |> replace_once!(
        ~s(-c "$MOB_DIR/ios/MobNode.m"),
        ~s(-c "$BUILD_DIR/MobNode.m"),
        "MobNode.m"
      )
      |> replace_once!(
        ~s(-c "$MOB_DIR/ios/mob_nif.m"),
        ~s(-c "$BUILD_DIR/mob_nif.m"),
        "mob_nif.m"
      )
      |> replace_once!(
        ~s("$MOB_DIR"/ios/*.swift \\),
        ~s("${SWIFT_SOURCES[@]}" \\),
        "swift sources"
      )
      |> replace_once!(
        ~s(-I "$MOB_DIR/ios"),
        ~s(-I "$BUILD_DIR" \\\n) <> include_indent(text) <> ~s(-I "$MOB_DIR/ios"),
        "swift include"
      )
      |> raise_solver_budget()
    end
  end

  # MobRootView's body is one SwiftUI expression. The markdown branch pushes it
  # past the type checker's default time limit ("unable to type-check this
  # expression in reasonable time"). The limit is milliseconds.
  defp raise_solver_budget(text) do
    module_name = ~s(-module-name "$APP_NAME" \\)

    cond do
      String.contains?(text, "solver-expression-time-threshold=") ->
        text

      String.contains?(text, module_name) ->
        indent = indent_of(text, module_name)
        anchor = indent <> module_name <> "\n"
        flag = indent <> "-Xfrontend -solver-expression-time-threshold=20000 \\\n"
        String.replace(text, anchor, anchor <> flag, global: false)

      true ->
        text
    end
  end

  defp splice_overlay(text) do
    anchor = ~s(SWIFT_BRIDGING="$MOB_DIR/ios/MobDemo-Bridging-Header.h"\n)

    unless String.contains?(text, anchor) do
      Mix.raise("iOS markdown patch could not find the TestFlight Swift bridging anchor")
    end

    indent = indent_of(text, ~s(SWIFT_BRIDGING="$MOB_DIR/ios/MobDemo-Bridging-Header.h"))
    String.replace(text, anchor, anchor <> overlay(indent) <> "\n", global: false)
  end

  defp overlay(indent) do
    ~S"""
    # Handbean: stock Mob drops `markdown`. mix mob.release rewrites this script;
    # HandbeanProbe.IosMarkdownRelease splices this block back in for TestFlight.
    bash ios/patch_markdown_host.sh "$MOB_DIR/ios" \
        "$BUILD_DIR/MobNode.h" \
        "$BUILD_DIR/MobNode.m" \
        "$BUILD_DIR/mob_nif.m" \
        "$BUILD_DIR/MobRootView.swift"
    IFLAGS="-I$BUILD_DIR $IFLAGS"
    SWIFT_SOURCES=("$BUILD_DIR/MobRootView.swift")
    for src in "$MOB_DIR"/ios/*.swift; do
        case "$(basename "$src")" in
            MobRootView.swift) ;;
            *) SWIFT_SOURCES+=("$src") ;;
        esac
    done
    SWIFT_SOURCES+=("ios/HandbeanMarkdown.swift")
    # The stock bridging header sits next to the unpatched MobNode.h.
    # A quoted #import resolves there before -I, so Swift never saw markdown.
    python3 - "$MOB_DIR/ios/MobDemo-Bridging-Header.h" "$BUILD_DIR/MobDemo-Bridging-Header.h" "$BUILD_DIR" <<'PY'
    import pathlib, sys
    src, dest, build = sys.argv[1:]
    text = pathlib.Path(src).read_text()
    old = '#import "MobNode.h"'
    new = '#import "%s/MobNode.h"' % build
    if old not in text:
        raise SystemExit('bridging header is missing #import "MobNode.h"')
    pathlib.Path(dest).write_text(text.replace(old, new, 1))
    PY
    SWIFT_BRIDGING="$BUILD_DIR/MobDemo-Bridging-Header.h"
    """
    |> String.trim_trailing()
    |> String.replace("\n", "\n" <> indent)
    |> then(&(indent <> &1))
  end

  defp include_indent(text) do
    case Regex.run(~r/^([ \t]*)-I "\$MOB_DIR\/ios"/m, text) do
      [_, indent] -> indent
      _ -> "        "
    end
  end

  defp indent_of(text, line) do
    case Regex.run(~r/^([ \t]*)#{Regex.escape(line)}/m, text) do
      [_, indent] -> indent
      _ -> ""
    end
  end

  defp replace_once!(text, old, new, label) do
    case :binary.matches(text, old) do
      [_] ->
        String.replace(text, old, new, global: false)

      [] ->
        Mix.raise("iOS markdown patch could not find the TestFlight #{label} anchor")

      _ ->
        Mix.raise("iOS markdown patch found more than one TestFlight #{label} anchor")
    end
  end
end
