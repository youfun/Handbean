defmodule Handbean.Agent.Coordinator.RunOptions do
  @moduledoc false

  require Logger

  @required_opts [:model, :provider_config, :tools, :source]

  @spec validate(keyword()) :: :ok | {:error, term()}
  def validate(opts) when is_list(opts) do
    with :ok <- validate_model_resolution(opts),
         :ok <- validate_required_opts(opts),
         :ok <- validate_model_policy(opts),
         :ok <- validate_advisor_policy(opts) do
      :ok
    end
  end

  defp validate_model_resolution(opts) do
    case Keyword.get(opts, :model_resolution_error) do
      nil -> :ok
      reason -> {:error, reason}
    end
  end

  @spec validate_checkout(keyword()) :: :ok | {:error, :checkout_unavailable}
  def validate_checkout(opts) when is_list(opts) do
    if free_chat?(opts) do
      :ok
    else
      case Keyword.get(opts, :working_directory) do
        path when is_binary(path) and path != "" ->
          if File.dir?(path), do: :ok, else: {:error, :checkout_unavailable}

        _ ->
          {:error, :checkout_unavailable}
      end
    end
  end

  @spec build(String.t(), keyword()) :: keyword()
  def build(conversation_id, opts) when is_binary(conversation_id) and is_list(opts) do
    opts =
      case Handbean.ConversationStore.get_metadata(conversation_id) do
        {:ok, meta} ->
          opts =
            opts
            |> Keyword.put_new(:workspace_id, meta["workspace_id"])
            |> put_created_by(meta)
            |> put_checkout_path(meta)
            |> put_permission_mode(meta)
            |> put_model_selection(meta)

          if get_in(meta, ["collaboration", "read_only"]) == true,
            do: Keyword.put(opts, :delegated_read_only, true),
            else: opts

        _ ->
          opts
      end

    opts
    |> Keyword.put(:session_id, conversation_id)
    |> Keyword.put(:conversation_id, conversation_id)
    |> ensure_run_id()
    |> put_saved_provider()
    |> put_transcript_history(conversation_id)
    |> put_working_directory()
    |> put_builtin_memory()
    |> put_skills()
    |> put_advisor_pin()
  end

  defp validate_required_opts(opts) do
    missing = Enum.reject(@required_opts, &Keyword.has_key?(opts, &1))

    missing =
      if free_chat?(opts) or present_workspace_path?(opts) do
        missing
      else
        [:workspace_path | missing]
      end

    if missing == [] do
      :ok
    else
      {:error, {:missing_opts, missing}}
    end
  end

  defp present_workspace_path?(opts) do
    case Keyword.get(opts, :workspace_path) do
      path when is_binary(path) and path != "" -> true
      _ -> false
    end
  end

  defp validate_model_policy(opts) do
    cond do
      explicit_provider_with_raw_model?(opts) -> :ok
      free_chat?(opts) -> :ok
      true -> validate_workspace_model_policy(opts)
    end
  end

  defp explicit_provider_with_raw_model?(opts) do
    Keyword.has_key?(opts, :provider) and
      opts
      |> Keyword.fetch!(:model)
      |> String.contains?("/")
      |> Kernel.not()
  end

  defp validate_workspace_model_policy(opts) do
    workspace_path = Keyword.fetch!(opts, :workspace_path)
    model = Keyword.fetch!(opts, :model)

    if Handbean.Agent.ModelConfig.model_allowed_for_workspace?(workspace_path, model,
         checkout_path: Keyword.get(opts, :working_directory, workspace_path)
       ) do
      validate_om_model_policy(opts)
    else
      {:error,
       Gettext.dgettext(
         Handbean.Gettext,
         "errors",
         "Model %{model} is not allowed in this workspace. Check Settings → Model / AI → Default model.",
         model: model
       )}
    end
  end

  defp validate_om_model_policy(opts) do
    workspace_path = Keyword.fetch!(opts, :workspace_path)

    if Handbean.WorkspaceSettings.builtin_memory_enabled(workspace_path) do
      om = Keyword.get(opts, :om, %{})
      memory_model_allowed(workspace_path, om[:model] || om["model"])
    else
      :ok
    end
  end

  # A removed catalog entry is not a workspace restriction. "Unrestricted" and
  # an allowlist that simply does not name the model both mean "do not use it
  # for memory", so the chat model can still start. An explicit allowlist that
  # excludes a model still present in the catalog remains a hard error.
  defp memory_model_allowed(_workspace_path, model) when model in [nil, ""], do: :ok

  defp memory_model_allowed(workspace_path, model) do
    cond do
      Handbean.Agent.ModelConfig.model_allowed_for_workspace?(workspace_path, model) ->
        :ok

      Handbean.Agent.ModelConfig.model_in_catalog?(model) ->
        {:error, memory_model_rejected(model)}

      true ->
        :ok
    end
  end

  defp memory_model_rejected(model) do
    Gettext.dgettext(
      Handbean.Gettext,
      "errors",
      "Observational Memory model (%{model}) is not allowed in this workspace. Check Settings → Model / AI → Observational Memory → Memory model.",
      model: model
    )
  end

  defp validate_advisor_policy(opts) do
    if free_chat?(opts) do
      :ok
    else
      {:ok, _pin} =
        Handbean.Agent.Advisor.validate_start(Keyword.fetch!(opts, :workspace_path), opts)

      :ok
    end
  end

  defp put_permission_mode(opts, meta) do
    resolved =
      meta
      |> Handbean.Permissions.ConversationMode.get()
      |> Handbean.Permissions.ConversationMode.resolve(Keyword.get(opts, :delegated_approval))

    opts
    |> Keyword.put(:permission_mode, resolved.permission_mode)
    |> Keyword.put(:permission_revision, meta["permission_revision"] || 0)
    |> Keyword.put(:approval_mode, resolved.approval_mode)
    |> Keyword.put(:approvals_reviewer, resolved.reviewer)
    |> Keyword.put(:permission_source, :conversation)
  end

  defp put_model_selection(opts, meta) do
    revision = meta["model_selection_revision"] || 0

    case meta["selected_model"] do
      model when is_binary(model) and model != "" ->
        opts =
          opts
          |> Keyword.put(:selected_model, model)
          |> Keyword.put(:model, model)
          |> Keyword.put(:model_selection_revision, revision)
          |> Keyword.put(:durable_model_selection, true)
          |> then(fn selected ->
            case meta["selected_reasoning_level"] do
              level when is_binary(level) -> Keyword.put(selected, :reasoning_level, level)
              _missing -> Keyword.delete(selected, :reasoning_level)
            end
          end)

        opts |> Keyword.delete(:provider) |> Keyword.put(:provider_config, %{})

      _missing ->
        Keyword.put(opts, :model_selection_revision, revision)
    end
  end

  defp put_checkout_path(opts, meta) do
    if Keyword.has_key?(opts, :working_directory) do
      opts
    else
      case meta["checkout_path"] do
        path when is_binary(path) and path != "" ->
          case Handbean.ConversationStore.effective_checkout_path(meta) do
            {:ok, checkout_path} -> Keyword.put(opts, :working_directory, checkout_path)
            {:error, _reason} -> Keyword.put(opts, :working_directory, nil)
          end

        _missing ->
          opts
      end
    end
  end

  defp put_created_by(opts, meta) do
    case Handbean.ConversationStore.parent_conversation_id(meta) do
      parent_id when is_binary(parent_id) ->
        Keyword.put(opts, :created_by_conversation_id, parent_id)

      _ ->
        opts
    end
  end

  # A composite model id is the saved catalog entry. Load that provider so a
  # subscription adapter is selected from models.json, not from a caller that
  # only forwarded transport options such as a test plug.
  defp put_saved_provider(opts) do
    model = Keyword.get(opts, :model)

    if is_binary(model) and String.contains?(model, "/") do
      case saved_provider_config(opts, model) do
        {:ok, saved, model_id} ->
          provider_config =
            if durable_provider_authority?(opts),
              do: saved,
              else: Map.merge(saved, Keyword.get(opts, :provider_config, %{}))

          opts
          |> Keyword.put(:model, model_id)
          |> Keyword.put(:provider_config, provider_config)

        {:error, reason} ->
          if Keyword.get(opts, :durable_model_selection, false),
            do: Keyword.put(opts, :model_resolution_error, reason),
            else: opts
      end
    else
      opts
    end
  end

  defp durable_provider_authority?(opts),
    do: Keyword.get(opts, :durable_model_selection, false)

  defp saved_provider_config(opts, model) do
    cond do
      free_chat?(opts) ->
        Handbean.Agent.ModelConfig.resolve_global_model(model)

      match?({:ok, _}, Keyword.fetch(opts, :workspace_path)) ->
        Handbean.Agent.ModelConfig.resolve_model_for_workspace(opts[:workspace_path], model,
          checkout_path: Keyword.get(opts, :working_directory, opts[:workspace_path])
        )

      true ->
        :error
    end
  end

  defp put_transcript_history(opts, conversation_id) do
    Keyword.put_new_lazy(opts, :history_messages, fn ->
      transcript_history_messages(
        conversation_id,
        Keyword.get(opts, :run_id),
        Keyword.get(opts, :transcript_id),
        history_workspace_path(opts)
      )
    end)
  end

  defp history_workspace_path(opts) do
    if free_chat?(opts), do: nil, else: opts[:working_directory]
  end

  defp transcript_history_messages(
         conversation_id,
         current_run_id,
         current_transcript_id,
         workspace_path
       ) do
    case Handbean.ConversationTranscriptStore.list(conversation_id) do
      {:ok, entries} ->
        entries
        |> Enum.reject(fn entry ->
          (current_run_id && Map.get(entry, "run_id") == current_run_id) or
            (current_transcript_id && Map.get(entry, "id") == current_transcript_id)
        end)
        |> Handbean.Attachments.History.to_messages(workspace_path, conversation_id)

      {:error, reason} ->
        Logger.warning(fn ->
          "[Coordinator] failed to load transcript history conversation=#{conversation_id} " <>
            "reason=#{inspect(reason)}"
        end)

        []
    end
  end

  defp put_working_directory(opts) do
    cond do
      free_chat?(opts) ->
        Keyword.delete(opts, :working_directory)

      true ->
        case Keyword.fetch(opts, :working_directory) do
          {:ok, _value} -> opts
          :error -> Keyword.put(opts, :working_directory, Keyword.fetch!(opts, :workspace_path))
        end
    end
  end

  defp put_builtin_memory(opts) do
    enabled =
      if free_chat?(opts) do
        true
      else
        opts
        |> Keyword.fetch!(:workspace_path)
        |> Handbean.WorkspaceSettings.builtin_memory_enabled()
      end

    om =
      opts
      |> Keyword.get(:om, %{})
      |> then(&if(is_map(&1), do: &1, else: %{}))
      |> Map.delete("enabled")
      |> Map.put(:enabled, enabled)

    opts
    |> Keyword.put(:builtin_memory_enabled, enabled)
    |> Keyword.put(:om, om)
  end

  defp put_skills(opts) do
    if free_chat?(opts),
      do: Keyword.put(opts, :skills, false),
      else: Keyword.put(opts, :skills, true)
  end

  defp put_advisor_pin(opts) do
    if free_chat?(opts) do
      Keyword.put(opts, :advisor, Handbean.Agent.Advisor.unavailable())
    else
      {:ok, pin} =
        Handbean.Agent.Advisor.validate_start(Keyword.fetch!(opts, :workspace_path), opts)

      Keyword.put(opts, :advisor, pin)
    end
  end

  defp ensure_run_id(opts), do: Keyword.put_new(opts, :run_id, Ecto.UUID.generate())

  defp free_chat?(opts), do: Keyword.get(opts, :chat_scope) == :free
end
