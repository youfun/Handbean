defmodule HandbeanPdfParser.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _arguments) do
    # This is the only Handbean-authored module in the extraction-only vendor.
    # Upstream defaults cover its generation APIs too; cap the extraction APIs
    # independently of application configuration or per-request input.
    {:ok, limits} =
      NativeElixirPdfUtilities.Validators.LimitsValidator.validate(
        max_pdf_input_bytes: 16 * 1024 * 1024,
        max_pdf_reader_decoded_bytes: 16 * 1024 * 1024,
        max_pdf_decoded_stream_bytes: 8 * 1024 * 1024,
        max_text_decoded_content_bytes: 16 * 1024 * 1024,
        max_extracted_text_bytes: 2 * 1024 * 1024,
        max_cmap_expanded_bytes: 2 * 1024 * 1024,
        max_pdf_pages: 1_000,
        max_pdf_objects: 25_000,
        max_pdf_page_tree_depth: 64,
        max_pdf_reference_chain_depth: 64,
        max_pdf_reader_tokens: 250_000,
        max_pdf_reader_values: 125_000,
        max_pdf_reader_work: 50_000_000,
        max_text_instruction_uses: 250_000,
        max_text_form_expansions: 2_000,
        max_text_spans: 25_000
      )

    :ok = NativeElixirPdfUtilities.Limits.install(limits)
    Supervisor.start_link([], strategy: :one_for_one, name: HandbeanPdfParser.Supervisor)
  end
end
