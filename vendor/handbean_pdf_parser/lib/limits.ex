defmodule NativeElixirPdfUtilities.Limits do
  @moduledoc """
  Runtime resource limits used by PDF parsing, information access, text
  extraction, merging, page transforms, splitting, and HTML-to-PDF rendering.

  Applications can override individual defaults in `config/config.exs` or
  `config/runtime.exs`:

      config :native_elixir_pdf_utilities,
        limits: [
          max_svg_bytes: 10_000_000,
          max_svg_raster_dimension: 16_284
        ]

  Configuration is validated when the library application starts. Values are
  process-wide, and changing them requires restarting the application.
  """

  @defaults %{
    max_aggregate_html_source_bytes: 10_000_000,
    max_aggregate_css_source_bytes: 20_000_000,
    max_html_source_bytes: 2_000_000,
    max_css_source_bytes: 1_000_000,
    max_html_nodes: 25_000,
    max_html_depth: 128,
    max_css_rules: 10_000,
    max_css_work: 5_000_000,
    max_layout_boxes: 100_000,
    max_rendered_text_bytes: 10_000_000,
    max_layout_text_work: 20_000_000,
    max_layout_measurement_cache_bytes: 2_000_000,
    max_layout_measurement_cache_entries: 10_000,
    max_table_grid_work: 1_000_000,
    max_rendered_pages: 1_000,
    max_rendered_pdf_bytes: 50_000_000,
    max_font_source_bytes: 10_000_000,
    max_aggregate_font_source_bytes: 40_000_000,
    max_font_count: 128,
    max_font_candidates: 256,
    max_font_discoveries: 64,
    max_font_cache_bytes: 100_000_000,
    max_system_font_cache_bytes: 100_000_000,
    max_pdf_attachments: 1_000,
    max_pdf_attachment_bytes: 10_000_000,
    max_pdf_attachment_total_bytes: 25_000_000,
    max_mime_container_bytes: 10_000_000,
    max_mime_container_entries: 10_000,
    max_appearance_text_bytes: 5_000_000,
    max_appearance_widgets: 10_000,
    max_pdf_form_fields: 10_000,
    max_pdf_form_depth: 64,
    max_pdf_form_text_bytes: 1_000_000,
    max_svg_nodes: 25_000,
    max_svg_depth: 128,
    max_svg_path_bytes: 1_000_000,
    max_svg_filter_primitives: 256,
    max_svg_references: 1_000,
    max_svg_output_bytes: 10_000_000,
    max_svg_bytes: 5_000_000,
    max_svg_raster_dimension: 8_192,
    max_svg_raster_pixels: 16_777_216,
    max_png_working_bytes: 160_000_000,
    max_image_count: 1_000,
    max_image_source_bytes: 10_000_000,
    max_aggregate_image_source_bytes: 50_000_000,
    max_decoded_image_bytes: 40_000_000,
    max_aggregate_decoded_image_bytes: 80_000_000,
    max_background_image_tiles: 10_000,
    max_layout_cardinality: 1_000,
    max_css_variable_bytes: 1_000_000,
    max_css_variable_total_bytes: 10_000_000,
    max_css_variable_work: 100_000,
    max_css_variable_depth: 64,
    max_css_numeric_magnitude: 1_000_000_000,
    max_pdf_reader_decoded_bytes: 50_000_000,
    max_pdf_reader_tokens: 1_000_000,
    max_pdf_reader_values: 500_000,
    max_pdf_reader_work: 250_000_000,
    max_pdf_container_entries: 100_000,
    max_pdf_numeric_token_bytes: 1_024,
    max_pdf_input_bytes: 50_000_000,
    max_pdf_numeric_magnitude: 1_000_000_000,
    max_pdf_objects: 100_000,
    max_pdf_object_stream_entries: 10_000,
    max_pdf_pages: 10_000,
    max_pdf_page_tree_depth: 1_000,
    max_pdf_reference_chain_depth: 1_000,
    max_pdf_reference_resolution_work: 25_000,
    max_pdf_value_depth: 100,
    max_pdf_decoded_stream_bytes: 25_000_000,
    max_pdf_decompression_ratio: 100,
    max_pdf_xref_length_candidates: 1_000,
    max_pdf_xref_revisions: 1_000,
    max_pdf_info_value_bytes: 1_000_000,
    max_pdf_info_total_bytes: 5_000_000,
    max_pdf_outline_items: 10_000,
    max_pdf_outline_depth: 64,
    max_pdf_outline_title_bytes: 16_384,
    max_pdf_outline_total_title_bytes: 5_000_000,
    max_pdf_name_tree_nodes: 10_000,
    max_pdf_named_destinations: 10_000,
    max_stamp_text_bytes: 1_000_000,
    max_stamp_decoded_content_bytes: 50_000_000,
    max_merge_inputs: 100,
    max_assembled_pdf_bytes: 50_000_000,
    max_aggregate_merge_input_bytes: 100_000_000,
    max_merged_objects: 100_000,
    max_merged_pages: 10_000,
    max_split_outputs: 1_000,
    max_split_object_writes: 1_000_000,
    max_aggregate_split_output_bytes: 100_000_000,
    max_extracted_text_bytes: 50_000_000,
    max_cmap_expanded_bytes: 10_000_000,
    max_text_decoded_content_bytes: 50_000_000,
    max_text_parsed_instructions: 100_000,
    max_text_stream_uses: 100_000,
    max_text_instruction_uses: 1_000_000,
    max_text_form_expansions: 10_000,
    max_text_spans: 25_000,
    max_text_layout_whitespace_bytes: 1_000_000,
    max_cmap_work: 1_000_000,
    max_cmap_bytes: 1_000_000,
    max_cmap_entries: 100_000,
    max_cid_width_entries: 65_536,
    max_form_xobject_depth: 20,
    max_font_kerning_pairs: 100_000,
    max_font_cmap_work: 1_000_000,
    max_font_subset_work: 100_000,
    max_font_cache_entries: 64,
    max_system_font_cache_entries: 64
  }

  @persistent_key {__MODULE__, :effective}

  @typedoc "A configurable resource-limit name."
  @type key ::
          :max_pdf_attachments
          | :max_aggregate_html_source_bytes
          | :max_aggregate_css_source_bytes
          | :max_html_source_bytes
          | :max_css_source_bytes
          | :max_html_nodes
          | :max_html_depth
          | :max_css_rules
          | :max_css_work
          | :max_layout_boxes
          | :max_rendered_text_bytes
          | :max_layout_text_work
          | :max_layout_measurement_cache_bytes
          | :max_layout_measurement_cache_entries
          | :max_table_grid_work
          | :max_rendered_pages
          | :max_rendered_pdf_bytes
          | :max_font_source_bytes
          | :max_aggregate_font_source_bytes
          | :max_font_count
          | :max_font_candidates
          | :max_font_discoveries
          | :max_font_cache_bytes
          | :max_system_font_cache_bytes
          | :max_pdf_attachment_bytes
          | :max_pdf_attachment_total_bytes
          | :max_mime_container_bytes
          | :max_mime_container_entries
          | :max_appearance_text_bytes
          | :max_appearance_widgets
          | :max_pdf_form_fields
          | :max_pdf_form_depth
          | :max_pdf_form_text_bytes
          | :max_svg_nodes
          | :max_svg_depth
          | :max_svg_path_bytes
          | :max_svg_filter_primitives
          | :max_svg_references
          | :max_svg_output_bytes
          | :max_svg_bytes
          | :max_svg_raster_dimension
          | :max_svg_raster_pixels
          | :max_png_working_bytes
          | :max_image_count
          | :max_image_source_bytes
          | :max_aggregate_image_source_bytes
          | :max_decoded_image_bytes
          | :max_aggregate_decoded_image_bytes
          | :max_background_image_tiles
          | :max_layout_cardinality
          | :max_css_variable_bytes
          | :max_css_variable_total_bytes
          | :max_css_variable_work
          | :max_css_variable_depth
          | :max_css_numeric_magnitude
          | :max_pdf_reader_decoded_bytes
          | :max_pdf_reader_tokens
          | :max_pdf_reader_values
          | :max_pdf_reader_work
          | :max_pdf_container_entries
          | :max_pdf_numeric_token_bytes
          | :max_pdf_input_bytes
          | :max_pdf_numeric_magnitude
          | :max_pdf_objects
          | :max_pdf_object_stream_entries
          | :max_pdf_pages
          | :max_pdf_page_tree_depth
          | :max_pdf_reference_chain_depth
          | :max_pdf_reference_resolution_work
          | :max_pdf_value_depth
          | :max_pdf_decoded_stream_bytes
          | :max_pdf_decompression_ratio
          | :max_pdf_xref_length_candidates
          | :max_pdf_xref_revisions
          | :max_pdf_info_value_bytes
          | :max_pdf_info_total_bytes
          | :max_pdf_outline_items
          | :max_pdf_outline_depth
          | :max_pdf_outline_title_bytes
          | :max_pdf_outline_total_title_bytes
          | :max_pdf_name_tree_nodes
          | :max_pdf_named_destinations
          | :max_stamp_text_bytes
          | :max_stamp_decoded_content_bytes
          | :max_merge_inputs
          | :max_assembled_pdf_bytes
          | :max_aggregate_merge_input_bytes
          | :max_merged_objects
          | :max_merged_pages
          | :max_split_outputs
          | :max_split_object_writes
          | :max_aggregate_split_output_bytes
          | :max_extracted_text_bytes
          | :max_cmap_expanded_bytes
          | :max_text_decoded_content_bytes
          | :max_text_parsed_instructions
          | :max_text_stream_uses
          | :max_text_instruction_uses
          | :max_text_form_expansions
          | :max_text_spans
          | :max_text_layout_whitespace_bytes
          | :max_cmap_work
          | :max_cmap_bytes
          | :max_cmap_entries
          | :max_cid_width_entries
          | :max_form_xobject_depth
          | :max_font_kerning_pairs
          | :max_font_cmap_work
          | :max_font_subset_work
          | :max_font_cache_entries
          | :max_system_font_cache_entries

  @typedoc "The complete validated resource-limit configuration."
  @type t :: %{required(key()) => pos_integer()}

  @doc "Returns the library's built-in resource limits."
  @spec defaults() :: t()
  def defaults do
    @defaults
  end

  @doc "Returns the effective resource limits loaded for this application instance."
  @spec effective() :: t()
  def effective do
    :persistent_term.get(@persistent_key, @defaults)
  end

  @doc false
  @spec keys() :: [key()]
  def keys do
    Map.keys(@defaults)
  end

  @doc false
  @spec get(key()) :: pos_integer()
  def get(key) do
    Map.fetch!(effective(), key)
  end

  @doc false
  @spec install(t()) :: :ok
  def install(limits) do
    :persistent_term.put(@persistent_key, limits)
  end
end
