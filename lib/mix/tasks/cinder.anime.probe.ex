defmodule Mix.Tasks.Cinder.Anime.Probe do
  @moduledoc false

  use Mix.Task

  alias Mix.Tasks.Cinder.Anime.Probe.{Corpus, HTTP, Report}

  @shortdoc "Probe anime metadata/indexer contracts without downloading"
  @switches [corpus: :string, json: :string, markdown: :string]

  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)
    if rest != [] or invalid != [], do: Mix.raise("invalid anime probe options")

    Mix.Task.run("app.start")

    corpus_path = opts[:corpus] || "test/support/fixtures/anime/corpus-v1.json"
    json_path = opts[:json] || "docs/audits/data/anime-provider-contracts-v1.json"
    markdown_path = opts[:markdown] || "docs/audits/2026-07-12-anime-provider-contracts.md"
    corpus = Corpus.load!(corpus_path)

    tmdb = required_config!(Cinder.Catalog.TMDB.HTTP, :token)
    prowlarr = required_config!(Cinder.Acquisition.Indexer.Prowlarr, :api_key)

    observations =
      Enum.map(corpus.titles, fn title ->
        case HTTP.fetch_title(title, tmdb, prowlarr) do
          {:ok, observation} ->
            observation

          {:error, reason} ->
            Mix.raise("anime probe failed: #{Cinder.HTTPPolicy.sanitize_log(reason)}")
        end
      end)

    report = Report.build(corpus, observations)
    json = Jason.encode_to_iodata!(report, pretty: true)
    markdown = Report.markdown(report)

    atomic_write!(json_path, json)
    atomic_write!(markdown_path, markdown)

    Mix.shell().info("Anime provider decision: #{report.decision}")
    Mix.shell().info("A0 status: #{report.a0_status}")
  end

  defp required_config!(module, key) do
    config = Application.get_env(:cinder, module, [])

    if is_nil(config[key]) or config[key] == "",
      do: Mix.raise("#{inspect(module)} #{key} is not configured")

    config
  end

  defp atomic_write!(path, contents) do
    File.mkdir_p!(Path.dirname(path))
    temporary = path <> ".tmp-#{System.unique_integer([:positive])}"

    try do
      File.write!(temporary, contents)
      File.rename!(temporary, path)
    after
      File.rm(temporary)
    end
  end
end
