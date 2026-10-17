defmodule HandbeanWeb.WorkspaceLive.Skills do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  def load(socket, workspace_root) do
    skills = Handbean.Skills.Loader.load(workspace: workspace_root).skills

    socket
    |> assign(:available_skills, skills)
    |> assign(:show_skills_panel, skills != [])
  end

  def launch_prompt(skills, skill_name) do
    case Enum.find(skills, &(&1.name == skill_name)) do
      %{description: description, name: name} when is_binary(description) and description != "" ->
        "Use the #{name} skill: #{description}"

      %{name: name} ->
        "Use the #{name} skill"
    end
  end

  def suggestions(value, skills) when is_binary(value) and is_list(skills) do
    cond do
      String.starts_with?(value, "/skill:") -> matches(value, "/skill:", skills)
      String.starts_with?(value, "/") and value != "/skill:" -> matches(value, "/", skills)
      true -> nil
    end
  end

  def select(current, skill_name) do
    if String.starts_with?(current, "/"), do: "/skill:#{skill_name} ", else: current
  end

  def expand(%Handbean.Agent.Message{role: :user, content: blocks} = message, skills) do
    blocks =
      Enum.map(blocks, fn
        %{type: "text", text: text} = block ->
          Map.put(block, :text, Handbean.Skills.Expander.expand(text, skills))

        other ->
          other
      end)

    %{message | content: blocks}
  end

  def expand(text, skills) when is_binary(text), do: Handbean.Skills.Expander.expand(text, skills)
  def expand(other, _skills), do: other

  defp matches(value, prefix, skills) do
    filter = String.replace_prefix(value, prefix, "")

    if String.contains?(filter, " ") do
      nil
    else
      lower_filter = String.downcase(filter)
      matches = Enum.filter(skills, &String.contains?(String.downcase(&1.name), lower_filter))
      if matches == [], do: nil, else: matches
    end
  end
end
