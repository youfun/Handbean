defmodule NativeElixirPdfUtilities.Validators.LimitsValidator do
  @moduledoc false

  alias NativeElixirPdfUtilities.Limits

  @max_configured_integer 9_223_372_036_854_775_807

  @doc false
  @spec validate(term()) :: {:ok, Limits.t()} | {:error, String.t()}
  def validate(config) do
    case Keyword.keyword?(config) do
      true ->
        keys = Keyword.keys(config)
        known_keys = Limits.keys()
        unknown_keys = Enum.reject(keys, &(&1 in known_keys))

        cond do
          unknown_keys != [] ->
            {:error, "unknown resource limit keys: #{inspect(Enum.uniq(unknown_keys))}"}

          length(keys) != length(Enum.uniq(keys)) ->
            {:error, "resource limit keys must not be repeated"}

          true ->
            limits = Map.merge(Limits.defaults(), Map.new(config))

            case Enum.find(limits, fn {_key, value} ->
                   not is_integer(value) or value <= 0 or value > @max_configured_integer
                 end) do
              {key, value} ->
                {:error,
                 "resource limit #{inspect(key)} must be a positive integer no greater than #{@max_configured_integer}; got: #{inspect(value)}"}

              nil ->
                validate_relationships(limits)
            end
        end

      false ->
        {:error, "resource limits must be configured as a keyword list"}
    end
  end

  defp validate_relationships(limits) do
    cond do
      limits.max_aggregate_font_source_bytes < limits.max_font_source_bytes ->
        {:error,
         "resource limit :max_aggregate_font_source_bytes must be greater than or equal to :max_font_source_bytes"}

      limits.max_aggregate_image_source_bytes < limits.max_image_source_bytes ->
        {:error,
         "resource limit :max_aggregate_image_source_bytes must be greater than or equal to :max_image_source_bytes"}

      limits.max_aggregate_decoded_image_bytes < limits.max_decoded_image_bytes ->
        {:error,
         "resource limit :max_aggregate_decoded_image_bytes must be greater than or equal to :max_decoded_image_bytes"}

      limits.max_pdf_object_stream_entries > limits.max_pdf_objects ->
        {:error, "resource limit :max_pdf_object_stream_entries must not exceed :max_pdf_objects"}

      limits.max_pdf_info_total_bytes < limits.max_pdf_info_value_bytes ->
        {:error,
         "resource limit :max_pdf_info_total_bytes must be greater than or equal to :max_pdf_info_value_bytes"}

      limits.max_pdf_outline_total_title_bytes < limits.max_pdf_outline_title_bytes ->
        {:error,
         "resource limit :max_pdf_outline_total_title_bytes must be greater than or equal to :max_pdf_outline_title_bytes"}

      limits.max_cid_width_entries > 65_536 ->
        {:error, "resource limit :max_cid_width_entries must not exceed the PDF CID range"}

      true ->
        {:ok, limits}
    end
  end
end
