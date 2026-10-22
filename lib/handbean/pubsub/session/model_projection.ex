defmodule Handbean.PubSub.Session.ModelProjection do
  @moduledoc """
  Pure transformations of Session's active-model metadata.

  Session validates run identity and owns event publication. These functions
  return metadata projections without changing the Runner's model or lifecycle.
  """

  @doc false
  @spec transition(map(), term(), atom(), map()) :: {map(), term()}
  def transition(meta, model, :accepted, payload) do
    {%{
       meta
       | pending_model: payload,
         model_switch_status: :accepted,
         model_switch_revision: payload[:revision] || meta.model_switch_revision
     }, model}
  end

  def transition(meta, _model, :applied, payload) do
    model = payload[:model] || meta.model

    {%{
       meta
       | model: model,
         active_model: payload,
         pending_model: nil,
         model_switch_status: :applied,
         model_switch_revision: payload[:revision] || meta.model_switch_revision
     }, model}
  end

  def transition(meta, model, status, payload)
      when status in [:cancelled, :failed, :expired] do
    {%{
       meta
       | pending_model: nil,
         model_switch_status: status,
         model_switch_revision: payload[:revision] || meta.model_switch_revision
     }, model}
  end

  def transition(meta, model, status, payload) do
    {%{
       meta
       | model_switch_status: status,
         model_switch_revision: payload[:revision] || meta.model_switch_revision
     }, model}
  end

  @doc false
  @spec event_kind(:accepted | :applied | :cancelled | :failed | :expired) :: atom()
  def event_kind(:accepted), do: :model_switch_accepted
  def event_kind(:applied), do: :model_switch_applied
  def event_kind(:cancelled), do: :model_switch_cancelled
  def event_kind(:failed), do: :model_switch_failed
  def event_kind(:expired), do: :model_switch_expired

  @doc false
  @spec normalize(term(), term()) :: map()
  def normalize(%{} = model, fallback) do
    Map.put_new(model, :model, fallback)
  end

  def normalize(model, _fallback) when is_binary(model) do
    %{model: model, model_ref: model, reasoning_level: nil, revision: 0}
  end

  def normalize(_model, fallback) do
    %{model: fallback, model_ref: fallback, reasoning_level: nil, revision: 0}
  end

  @doc false
  @spec registry_model(term(), term()) :: term()
  def registry_model(%{model: model}, _fallback) when is_binary(model), do: model
  def registry_model(model, _fallback) when is_binary(model), do: model
  def registry_model(_model, fallback), do: fallback
end
