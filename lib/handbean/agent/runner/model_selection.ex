defmodule Handbean.Agent.Runner.ModelSelection do
  @moduledoc """
  Pure transitions for a run's active and pending model selections.

  The Runner owns this value, validates run/task identity, and publishes changes.
  A committed selection returns updated run options alongside the new value so
  approval resumes use the same configuration as the active model projection.
  """

  @enforce_keys [:active]
  defstruct [:active, :pending, revision: 0]

  @type t :: %__MODULE__{active: map(), pending: map() | nil, revision: non_neg_integer()}

  @spec new(keyword()) :: t()
  def new(opts) do
    provider_config = Keyword.get(opts, :provider_config, %{})

    revision =
      case Keyword.get(opts, :model_selection_revision, 0) do
        value when is_integer(value) and value >= 0 -> value
        _invalid -> 0
      end

    %__MODULE__{
      revision: revision,
      active: %{
        revision: revision,
        model_ref: Keyword.get(opts, :selected_model) || Keyword.get(opts, :model),
        model: Keyword.get(opts, :model),
        reasoning_level: Keyword.get(opts, :reasoning_level),
        provider:
          provider_config[:provider] || provider_config["provider"] ||
            inspect(Keyword.get(opts, :provider))
      }
    }
  end

  @spec request(t(), map(), keyword()) ::
          {:ok, :accepted | :cancelled, t(), map()} | {:error, term()}
  def request(%__MODULE__{} = current, selection, opts) do
    with :ok <- validate_expected_revision(current, selection),
         {:ok, normalized} <- normalize(selection) do
      revision = current.revision + 1

      if same_model?(current.active, normalized) do
        next = %{current | pending: nil, revision: revision}
        public = public_selection(Map.put(normalized, :revision, revision))
        {:ok, :cancelled, next, public}
      else
        config_opts =
          opts
          |> Keyword.drop([
            :provider,
            :provider_config,
            :model,
            :selected_model,
            :reasoning_level,
            :max_tokens
          ])
          |> Keyword.merge(normalized.run_opts)

        pending =
          normalized
          |> Map.put(:revision, revision)
          |> Map.put(:config_opts, config_opts)

        next = %{current | pending: pending, revision: revision}
        {:ok, :accepted, next, public_selection(pending)}
      end
    end
  end

  defp validate_expected_revision(%__MODULE__{revision: revision}, %{expected_revision: revision}),
       do: :ok

  defp validate_expected_revision(%__MODULE__{revision: revision}, %{
         expected_revision: expected
       })
       when is_integer(expected),
       do: {:error, {:stale_model_selection, revision}}

  defp validate_expected_revision(%__MODULE__{}, _selection), do: :ok

  @spec commit(t(), non_neg_integer(), map()) ::
          {:ok, t(), keyword()} | {:error, :stale_revision}
  def commit(%__MODULE__{pending: %{revision: revision} = pending} = current, revision, public) do
    opts =
      Keyword.merge(pending.config_opts,
        selected_model: public.model_ref,
        model: public.model,
        reasoning_level: public.reasoning_level
      )

    {:ok, %{current | active: public, pending: nil}, opts}
  end

  def commit(%__MODULE__{}, _revision, _public), do: {:error, :stale_revision}

  @spec fail(t(), non_neg_integer(), term()) ::
          {:ok, t(), map()} | {:error, :stale_revision}
  def fail(%__MODULE__{pending: %{revision: revision} = pending} = current, revision, reason) do
    public =
      current.active
      |> public_selection()
      |> Map.put(:revision, revision)
      |> Map.put(:error, inspect(reason))
      |> Map.put(:failed_model_ref, pending.model_ref)
      |> Map.put(:failed_reasoning_level, pending.reasoning_level)

    {:ok, %{current | pending: nil}, public}
  end

  def fail(%__MODULE__{}, _revision, _reason), do: {:error, :stale_revision}

  @spec public_pending(t()) :: map() | nil
  def public_pending(%__MODULE__{pending: pending}), do: public_selection(pending)

  defp normalize(%{model_ref: model_ref, run_opts: run_opts} = selection)
       when is_binary(model_ref) and is_list(run_opts) do
    model = Keyword.get(run_opts, :model)

    reasoning_level =
      Map.get(selection, :reasoning_level) || Keyword.get(run_opts, :reasoning_level)

    if is_binary(model) do
      {:ok,
       %{
         model_ref: model_ref,
         model: model,
         reasoning_level: reasoning_level,
         run_opts: run_opts
       }}
    else
      {:error, :invalid_model_selection}
    end
  end

  defp normalize(_selection), do: {:error, :invalid_model_selection}

  defp same_model?(active, pending) when is_map(active) do
    active.model_ref == pending.model_ref and active.reasoning_level == pending.reasoning_level
  end

  defp same_model?(_active, _pending), do: false

  defp public_selection(nil), do: nil

  defp public_selection(pending) do
    Map.take(pending, [:revision, :model_ref, :model, :reasoning_level, :provider, :error])
  end
end
