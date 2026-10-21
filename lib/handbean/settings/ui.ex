defmodule Handbean.Settings.UI do
  @moduledoc "Global UI preferences persisted in the application's SQLite database."
  use Ecto.Schema

  import Ecto.Changeset

  alias Handbean.Repo
  alias Handbean.Storage.WriteTransaction

  @primary_key {:key, :string, autogenerate: false}
  schema "ui_settings" do
    field :value, :string
  end

  @doc "Return a supported locale, or nil when no valid preference has been saved."
  def locale do
    case Repo.get(__MODULE__, "ui.locale") do
      %__MODULE__{value: locale} -> valid_locale(locale)
      nil -> nil
    end
  end

  @doc "Save the language preference atomically, replacing the previous value."
  def save_locale(locale) do
    %__MODULE__{key: "ui.locale"}
    |> change(value: locale)
    |> validate_required([:value])
    |> validate_inclusion(:value, ["zh_CN", "en"])
    |> Repo.insert(on_conflict: {:replace, [:value]}, conflict_target: [:key])
    |> case do
      {:ok, _setting} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  def valid_locale(locale) when locale in ["zh_CN", "en"], do: locale
  def valid_locale(_), do: nil

  @themes ["light", "dark", "system"]

  @doc "Return the saved theme, or light when none has been chosen."
  def theme do
    case Repo.get(__MODULE__, "ui.theme") do
      %__MODULE__{value: theme} -> valid_theme(theme) || "light"
      nil -> "light"
    end
  end

  @doc "Save light, dark, or system. System follows the OS color scheme."
  def save_theme(theme) do
    %__MODULE__{key: "ui.theme"}
    |> change(value: theme)
    |> validate_required([:value])
    |> validate_inclusion(:value, @themes)
    |> Repo.insert(on_conflict: {:replace, [:value]}, conflict_target: [:key])
    |> case do
      {:ok, _setting} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  def valid_theme(theme) when theme in @themes, do: theme
  def valid_theme(_), do: nil

  @location_key "ui.last_location"
  @collapsed_key "ui.collapsed_groups"
  @collapsed_threads_key "ui.collapsed_threads"
  @max_collapsed_ids 200
  @id_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\z/

  @doc """
  Last conversation the UI was left on.

  Returns `%{scope: :free, conversation_id: id}` or
  `%{scope: :workspace, workspace_id: id, conversation_id: id}`, or nil.
  """
  def last_location do
    case Repo.get(__MODULE__, @location_key) do
      %__MODULE__{value: value} -> decode_location(value)
      nil -> nil
    end
  end

  @doc "Save the conversation the UI should reopen. Invalid ids are rejected."
  def save_last_location(location) do
    case encode_location(location) do
      {:ok, value} -> put(@location_key, value)
      :error -> {:error, :invalid}
    end
  end

  @doc "Workspace, free, and pinned groups the sidebar left collapsed."
  def collapsed_groups, do: collapsed_ids(@collapsed_key)

  @doc "Replace the collapsed sidebar groups. Unknown ids are dropped."
  def save_collapsed_groups(groups), do: save_collapsed_ids(@collapsed_key, groups)

  @doc "Conversation threads the sidebar left collapsed."
  def collapsed_threads, do: collapsed_ids(@collapsed_threads_key)

  @doc "Persist one conversation thread's collapsed state without replacing other views' choices."
  def set_thread_collapsed(thread_id, collapsed?)
      when is_binary(thread_id) and is_boolean(collapsed?) do
    if valid_id?(thread_id) do
      fn ->
        ids = persisted_ids(@collapsed_threads_key)

        ids =
          if collapsed? do
            ids
            |> Enum.reject(&(&1 == thread_id))
            |> Kernel.++([thread_id])
          else
            Enum.reject(ids, &(&1 == thread_id))
          end

        case save_ids(@collapsed_threads_key, ids) do
          :ok -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end
      end
      |> WriteTransaction.run()
      |> transaction_result()
    else
      {:error, :invalid}
    end
  end

  def set_thread_collapsed(_thread_id, _collapsed?), do: {:error, :invalid}

  defp save_collapsed_ids(key, ids) do
    ids = ids |> Enum.map(&to_string/1) |> normalize_ids()
    save_ids(key, ids)
  end

  defp save_ids(key, ids) do
    case Handbean.JSON.encode(normalize_ids(ids)) do
      {:ok, value} -> put(key, value)
      {:error, _} -> {:error, :invalid}
    end
  end

  defp put(key, value) do
    %__MODULE__{key: key}
    |> change(value: value)
    |> validate_required([:value])
    |> Repo.insert(on_conflict: {:replace, [:value]}, conflict_target: [:key])
    |> case do
      {:ok, _setting} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp encode_location(%{scope: :free, conversation_id: id}) do
    if valid_id?(id) do
      Handbean.JSON.encode(%{scope: "free", conversation_id: id})
    else
      :error
    end
  end

  defp encode_location(%{scope: :workspace, workspace_id: workspace_id, conversation_id: id}) do
    if valid_id?(workspace_id) and valid_id?(id) do
      Handbean.JSON.encode(%{scope: "workspace", workspace_id: workspace_id, conversation_id: id})
    else
      :error
    end
  end

  defp encode_location(_), do: :error

  defp decode_location(value) when is_binary(value) do
    case Handbean.JSON.decode(value) do
      {:ok, %{"scope" => "free", "conversation_id" => id}} ->
        if valid_id?(id), do: %{scope: :free, conversation_id: id}

      {:ok, %{"scope" => "workspace", "workspace_id" => workspace_id, "conversation_id" => id}} ->
        if valid_id?(workspace_id) and valid_id?(id) do
          %{scope: :workspace, workspace_id: workspace_id, conversation_id: id}
        end

      _ ->
        nil
    end
  end

  defp decode_location(_), do: nil

  defp collapsed_ids(key), do: key |> persisted_ids() |> MapSet.new()

  defp persisted_ids(key) do
    case Repo.get(__MODULE__, key) do
      %__MODULE__{value: value} -> decode_ids(value)
      nil -> []
    end
  end

  defp decode_ids(value) when is_binary(value) do
    case Handbean.JSON.decode(value) do
      {:ok, ids} when is_list(ids) -> normalize_ids(ids)
      _ -> []
    end
  end

  defp decode_ids(_), do: []

  defp normalize_ids(ids) do
    ids
    |> Enum.filter(&valid_id?/1)
    |> Enum.reverse()
    |> Enum.uniq()
    |> Enum.take(@max_collapsed_ids)
    |> Enum.reverse()
  end

  defp transaction_result({:ok, :ok}), do: :ok
  defp transaction_result({:error, reason}), do: {:error, reason}

  defp valid_id?(id) when is_binary(id), do: Regex.match?(@id_pattern, id)
  defp valid_id?(_), do: false
end
