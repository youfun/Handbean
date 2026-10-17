defmodule HandbeanProbe.Platform.IOS.Adapter.Nif do
  @moduledoc false

  @behaviour HandbeanProbe.Platform.IOS.Adapter

  @impl true
  def open_url(url) when is_binary(url) and url != "" do
    nif_call(fn -> :mob_nif.open_url(url) end)
  end

  def open_url(_), do: {:error, :invalid_url}

  @impl true
  def share_text(text) when is_binary(text) and text != "" do
    nif_call(fn -> :mob_nif.share_text(text) end)
  end

  def share_text(_), do: {:error, :empty}

  @impl true
  def pick_images do
    envelope = Handbean.JSON.encode!([%{"kind" => "semantic", "value" => "images"}])
    nif_call(fn -> :mob_nif.files_pick(envelope) end)
  end

  @impl true
  def present_file(path, mode) when is_binary(path) and mode in [:open, :share] do
    nif_call(fn ->
      case Code.ensure_loaded(:handbean_ios) do
        {:module, :handbean_ios} ->
          case :handbean_ios.present_file(path, Atom.to_string(mode)) do
            :ok -> :ok
            {:error, :nif_not_loaded} -> {:error, :nif_not_loaded}
            {:error, reason} -> {:error, reason}
            other -> {:error, other}
          end

        {:error, _} ->
          {:error, :nif_not_loaded}
      end
    end)
  end

  def present_file(_, _), do: {:error, :file_unavailable}

  defp nif_call(fun) when is_function(fun, 0) do
    case fun.() do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  rescue
    UndefinedFunctionError -> {:error, :nif_not_loaded}
    ErlangError -> {:error, :nif_not_loaded}
  catch
    :error, :undef -> {:error, :nif_not_loaded}
    :error, {:nif_not_loaded, _} -> {:error, :nif_not_loaded}
  end
end
