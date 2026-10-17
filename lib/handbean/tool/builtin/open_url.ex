defmodule Handbean.Tool.Builtin.OpenUrl do
  @moduledoc """
  Open an http(s) URL in the system browser.

  This is not the conversation Agent WebView (`browser` tool). Android and iOS
  share this tool; the host injects the presentation backend.
  """

  @behaviour Handbean.Agent.Tool

  alias Handbean.ArtifactDelivery
  alias Handbean.ArtifactDelivery.{Input, Url}

  @impl true
  def name, do: "open_url"

  @impl true
  def description do
    "Open a public http or https page in the device system browser so the user " <>
      "can view a document, order, or login page. This is not the in-app Agent " <>
      "WebView; use the browser tool to inspect a page inside Handbean. Only the URL " <>
      "is accepted — never platform Intent fields. Success means the system UI was " <>
      "shown, not that the site finished loading or the user signed in."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      additionalProperties: false,
      required: ["url"],
      properties: %{
        url: %{
          type: "string",
          maxLength: 2048,
          description: "Absolute http or https URL. No userinfo, file, or javascript schemes."
        }
      }
    }
  end

  @impl true
  def concurrent?, do: false

  @impl true
  def execute(input, context) when is_map(input) and is_map(context) do
    with {:ok, fields} <- Input.take(input, ["url"]),
         {:ok, url} <- Url.parse(fields["url"]),
         {:ok, result} <- ArtifactDelivery.dispatch(%{op: :open_url, url: url}, context) do
      finish(result)
    else
      {:error, :raw_intent_rejected} ->
        {:error, "raw Intent fields are not allowed"}

      {:error, :unexpected_fields} ->
        {:error, "only url is accepted"}

      {:error, :unavailable} ->
        {:error, "system browser is not available on this host"}

      {:error, reason} ->
        {:error, ArtifactDelivery.format_outcome(to_string(reason))}
    end
  end

  def execute(_, _), do: {:error, "invalid open_url input"}

  defp finish(%{outcome: outcome} = result) do
    text = ArtifactDelivery.format_outcome(outcome)
    details = Map.take(result, [:outcome, :url])

    if ArtifactDelivery.presented?(outcome) do
      {:ok, text, details}
    else
      {:error, text, details}
    end
  end

  defp finish(result) when is_map(result), do: finish(normalize(result))
  defp finish(_), do: {:error, ArtifactDelivery.format_outcome("outcome_unknown")}

  defp normalize(map) do
    %{
      outcome:
        to_string(Handbean.Utils.SafeMap.get_any(map, :outcome, "outcome") || "outcome_unknown"),
      url: Handbean.Utils.SafeMap.get_any(map, :url, "url")
    }
  end
end
