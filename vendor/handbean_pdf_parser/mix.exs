defmodule HandbeanPdfParser.MixProject do
  use Mix.Project

  def project do
    [app: :handbean_pdf_parser, version: "1.0.0", elixir: "~> 1.19", deps: []]
  end

  def application do
    [mod: {HandbeanPdfParser.Application, []}]
  end
end
