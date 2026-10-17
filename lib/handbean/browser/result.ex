defmodule Handbean.Browser.Result do
  @moduledoc """
  Parses `agent-browser --json` output into dual-channel tool results.

  Artifact paths are accepted only when they resolve inside the
  conversation artifact directory. Failures carry a machine-readable
  `failure_category` plus optional `next_actions`.
  """

  alias Handbean.Browser.{InstallPrompt, Redactor}

  @type artifact :: %{type: String.t(), path: String.t(), media_type: String.t()}

  @type t :: %{
          content: String.t(),
          details: map()
        }

  @doc """
  Parse a completed CLI invocation.

  `raw` is `%{stdout, stderr, exit_code, timed_out}`.
  """
  @spec parse(map(), keyword()) :: t()
  def parse(raw, opts \\ []) when is_map(raw) do
    artifact_dir = Keyword.get(opts, :artifact_dir)
    timed_out? = truthy?(Handbean.Utils.SafeMap.get_any(raw, :timed_out, "timed_out"))
    exit_code = Handbean.Utils.SafeMap.get_any(raw, :exit_code, "exit_code") || 0
    stdout = Handbean.Utils.SafeMap.get_any(raw, :stdout, "stdout") || ""
    stderr = Handbean.Utils.SafeMap.get_any(raw, :stderr, "stderr") || ""

    cond do
      timed_out? ->
        failure("timeout", "Browser command timed out",
          timed_out: true,
          exit_code: exit_code,
          next_actions: [%{id: "retry-with-fresh-session"}]
        )

      true ->
        parse_output(stdout, stderr, exit_code, artifact_dir)
    end
  end

  @doc "Build a recoverable missing-binary envelope."
  @spec missing_binary(String.t()) :: t()
  def missing_binary(binary) when is_binary(binary) do
    command = InstallPrompt.command()

    failure(
      "missing-binary",
      """
      #{binary} is not installed, or not on this Handbean process's PATH.

      Handbean is installed on more than one computer. Install on the computer \
      running this conversation, not on a development machine that already has it. \
      Handbean loads the login-shell environment and the current workspace's \
      environment, including tools exposed by mise, asdf, or direnv.

      Run this on that computer:
      #{command}

      Then restart Handbean on that computer and retry the same browser call. \
      Do not install it with the bash tool unless the user approves. \
      Do not treat another computer's install as success.
      """,
      next_actions: [%{id: "install-agent-browser", command: command}],
      install_command: command
    )
  end

  defp parse_output(stdout, stderr, exit_code, artifact_dir) do
    case decode_json(stdout) do
      {:ok, data} when is_map(data) ->
        from_json(data, exit_code, artifact_dir)

      {:ok, _other} ->
        from_text(stdout, stderr, exit_code)

      :error ->
        from_text(stdout, stderr, exit_code)
    end
  end

  defp from_json(data, exit_code, artifact_dir) do
    if envelope?(data) do
      from_envelope(data, exit_code, artifact_dir)
    else
      from_legacy_json(data, exit_code, artifact_dir)
    end
  end

  defp envelope?(data) do
    Map.has_key?(data, "success") or Map.has_key?(data, :success)
  end

  defp from_envelope(data, exit_code, artifact_dir) do
    success? = truthy?(Handbean.Utils.SafeMap.get_any(data, "success", :success))
    error = envelope_error(data)
    inner = envelope_inner(data)
    artifacts = collect_artifacts(inner || %{}, artifact_dir)
    content = envelope_content(inner, error, artifacts)
    safe_inner = inner && Redactor.redact_data(Map.delete(inner, "lifecycle"))

    if success? and is_nil(error) and exit_code == 0 do
      success(content, artifacts, safe_inner, exit_code)
    else
      failure("upstream-error", content || error || "Browser command failed",
        exit_code: exit_code,
        artifacts: artifacts,
        data: safe_inner
      )
    end
  end

  defp from_legacy_json(data, exit_code, artifact_dir) do
    safe = Redactor.redact_data(data)
    artifacts = collect_artifacts(data, artifact_dir)
    content = json_content(safe, artifacts)

    if exit_code == 0 and is_nil(safe["error"]) do
      success(content, artifacts, safe, exit_code)
    else
      failure("upstream-error", content || "Browser command failed",
        exit_code: exit_code,
        artifacts: artifacts,
        data: safe
      )
    end
  end

  defp envelope_inner(data) do
    case Handbean.Utils.SafeMap.get_any(data, "data", :data) do
      inner when is_map(inner) -> stringify_keys(inner)
      _ -> nil
    end
  end

  defp envelope_error(data) do
    case Handbean.Utils.SafeMap.get_any(data, "error", :error) do
      error when is_binary(error) and error != "" -> error
      _ -> nil
    end
  end

  defp envelope_content(inner, error, artifacts) do
    cond do
      is_map(inner) and present?(inner["snapshot"]) ->
        inner["snapshot"]

      is_map(inner) and present?(inner["text"]) ->
        inner["text"]

      is_map(inner) and present?(inner["result"]) ->
        inner["result"]

      is_map(inner) and present?(inner["title"]) ->
        title_content(inner)

      is_map(inner) and present?(inner["path"]) ->
        "#{guess_type(inner["path"], "artifact")} saved: #{inner["path"]}"

      present?(error) ->
        error

      artifacts != [] ->
        artifact_lines(artifacts)

      is_map(inner) ->
        inner
        |> Map.drop(["lifecycle"])
        |> case do
          empty when empty == %{} -> "Browser command finished"
          rest -> Handbean.JSON.encode!(rest)
        end

      true ->
        error || "Browser command finished"
    end
  end

  defp title_content(inner) do
    case inner["url"] do
      url when is_binary(url) and url != "" -> "#{inner["title"]}\n#{url}"
      _ -> inner["title"]
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp present?(value), do: is_binary(value) and value != ""

  defp from_text(stdout, stderr, exit_code) do
    content =
      stdout
      |> String.trim()
      |> case do
        "" -> String.trim(stderr)
        text -> text
      end

    content = if content == "", do: "Browser command finished", else: content

    if exit_code == 0 do
      success(content, [], nil, exit_code)
    else
      failure("upstream-error", content, exit_code: exit_code)
    end
  end

  defp json_content(data, artifacts) do
    cond do
      is_binary(data["text"]) and data["text"] != "" ->
        data["text"]

      is_binary(data["result"]) and data["result"] != "" ->
        data["result"]

      is_binary(data["error"]) and data["error"] != "" ->
        data["error"]

      is_binary(data["message"]) and data["message"] != "" ->
        data["message"]

      artifacts != [] ->
        artifact_lines(artifacts)

      true ->
        Handbean.JSON.encode!(data)
    end
  end

  defp artifact_lines(artifacts) do
    Enum.map_join(artifacts, "\n", fn artifact ->
      "#{artifact.type} saved: #{artifact.path}"
    end)
  end

  defp collect_artifacts(data, artifact_dir) do
    candidates =
      screenshot_candidates(data) ++
        list_candidates(Handbean.Utils.SafeMap.get_any(data, "artifacts", :artifacts))

    candidates
    |> Enum.flat_map(&normalize_artifact(&1, artifact_dir))
    |> Enum.uniq_by(& &1.path)
  end

  defp screenshot_candidates(data) do
    for key <- ["screenshot", "path"],
        value = Map.get(data, key),
        is_binary(value) and looks_like_file?(value) do
      %{type: guess_type(value, "screenshot"), path: value}
    end
  end

  defp list_candidates(list) when is_list(list) do
    Enum.flat_map(list, fn
      %{"path" => path} = item when is_binary(path) ->
        [%{type: item["type"] || guess_type(path, "artifact"), path: path}]

      %{path: path} = item when is_binary(path) ->
        [%{type: Map.get(item, :type) || guess_type(path, "artifact"), path: path}]

      _ ->
        []
    end)
  end

  defp list_candidates(_), do: []

  defp normalize_artifact(%{path: path} = artifact, artifact_dir) do
    expanded = Path.expand(path)

    if allowed_artifact?(expanded, artifact_dir) do
      type = artifact.type || guess_type(expanded, "artifact")

      [
        %{
          type: type,
          path: expanded,
          media_type: media_type(expanded, type)
        }
      ]
    else
      []
    end
  end

  defp allowed_artifact?(_path, nil), do: false

  defp allowed_artifact?(path, artifact_dir) do
    root = Path.expand(artifact_dir)
    String.starts_with?(path, root <> "/") or path == root
  end

  defp looks_like_file?(value) do
    String.contains?(value, "/") or String.contains?(value, "\\") or
      Path.extname(value) != ""
  end

  defp guess_type(path, default) do
    case String.downcase(Path.extname(path)) do
      ext when ext in [".png", ".jpg", ".jpeg", ".webp", ".gif"] -> "screenshot"
      _ -> default
    end
  end

  defp media_type(path, type) do
    case String.downcase(Path.extname(path)) do
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".webp" -> "image/webp"
      ".gif" -> "image/gif"
      ".csv" -> "text/csv"
      ".pdf" -> "application/pdf"
      _ when type == "screenshot" -> "image/png"
      _ -> "application/octet-stream"
    end
  end

  defp success(content, artifacts, data, exit_code) do
    %{
      content: content,
      details:
        %{
          result_category: "success",
          failure_category: nil,
          artifacts: artifacts,
          exit_code: exit_code,
          timed_out: false,
          next_actions: []
        }
        |> maybe_put(:data, data)
    }
  end

  defp failure(category, content, opts) do
    %{
      content: content,
      details: %{
        result_category: "failure",
        failure_category: category,
        artifacts: Keyword.get(opts, :artifacts, []),
        exit_code: Keyword.get(opts, :exit_code),
        timed_out: Keyword.get(opts, :timed_out, false),
        next_actions: Keyword.get(opts, :next_actions, []),
        data: Keyword.get(opts, :data),
        install_command: Keyword.get(opts, :install_command)
      }
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp decode_json(stdout) when is_binary(stdout) do
    trimmed = String.trim(stdout)

    if trimmed == "" do
      :error
    else
      case Handbean.JSON.decode(trimmed) do
        {:ok, data} -> {:ok, data}
        {:error, _} -> :error
      end
    end
  end

  defp decode_json(_), do: :error

  defp truthy?(true), do: true
  defp truthy?(false), do: false
  defp truthy?(_), do: false
end
