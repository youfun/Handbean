defmodule Handbean.Permissions.Remember do
  @moduledoc """
  Turns a tool call into a workspace Matcher pattern the user can remember.
  """

  alias Handbean.Permissions.Matcher

  @spec pattern(map()) :: String.t()
  def pattern(call) when is_map(call) do
    name = normalize_name(Handbean.Utils.SafeMap.get_any(call, :name, "name"))

    input = Handbean.Utils.SafeMap.get_any(call, :input, "input") || %{}
    do_pattern(name, input)
  end

  defp do_pattern("bash", input) do
    command = string_field(input, ["command", :command])

    case bash_family(command) do
      nil -> "bash"
      family -> bash_pattern(family)
    end
  end

  defp do_pattern(name, input) when name in ["read", "edit", "write"] do
    path = string_field(input, ["file_path", :file_path, "path", :path])

    if path == "" do
      name
    else
      "#{name}(#{path})"
    end
  end

  defp do_pattern("ext__beam__sql", input) do
    "ext__beam__sql(call:#{Matcher.sql_call_fingerprint(input)})"
  end

  defp do_pattern("browser", input) do
    case Handbean.Browser.Policy.command_token(input) do
      "" -> "browser"
      command -> "browser(#{command}:*)"
    end
  end

  defp do_pattern(name, _input) when is_binary(name) and name != "", do: name
  defp do_pattern(_name, _input), do: "unknown"

  defp bash_pattern(family) do
    if String.contains?(family, " ") do
      "bash(#{family}*)"
    else
      "bash(#{family}:*)"
    end
  end

  defp bash_family(command) do
    tokens =
      command
      |> String.trim()
      |> String.split(~r/\s+/, trim: true)

    case tokens do
      ["git", sub | _] -> "git #{sub}"
      ["mix", sub | _] -> "mix #{sub}"
      ["npm", sub | _] -> "npm #{sub}"
      ["npx", sub | _] -> "npx #{sub}"
      [cmd | _] -> cmd
      [] -> nil
    end
  end

  defp string_field(input, keys) when is_map(input) do
    Enum.find_value(keys, "", &Map.get(input, &1))
    |> to_string()
    |> String.trim()
  end

  defp normalize_name(name) when is_atom(name), do: Atom.to_string(name)
  defp normalize_name(name) when is_binary(name), do: name
  defp normalize_name(_), do: ""
end
