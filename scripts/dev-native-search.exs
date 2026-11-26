# Runs movie searches through `Cinder.Acquisition.IndexerSource.Native` over real HTTP, against
# a Newznab and Torznab listener this script serves on 127.0.0.1, for a native-indexer PR's test
# path. Run it from the repo root, with MIX_ENV=dev (any other env stops it before it writes):
#
#     MIX_ENV=dev mix run --no-start scripts/dev-native-search.exs
#
# It migrates the dev database, starts the app (with no web server while `PHX_SERVER` is unset)
# with the log level at `:warning`, and serves the listener on port 4199 (`DEV_NATIVE_PORT` sets
# another). It then deletes any configured indexer named as below, which drops its stored caps
# and backoff rows with it and writes a `delete_configured_indexer` row to `admin_audit`, and
# creates them again on the listener:
#
# - "Dev NZB" (Newznab): one NZB item for `t=movie&imdbid=0000001`, whose link `/nzb/get/1.nzb`
#   answers a one-file NZB;
# - "Dev Torznab" (Torznab): one magnet item for `t=movie&imdbid=0000001`;
# - "Dev limited" (Newznab): 429 with `Retry-After: 3600` to every request;
# - "Dev rejected" (Newznab): `<error code="100">`, rejected credentials, to every request;
# - "Dev flaky" (Newznab): 502 to the run's first request to it, then Dev NZB's answers;
# - "Dev text-only" (Torznab): caps whose movie-search lists `q` but no `imdbid`, and two magnet
#   items for `t=search&q=Movie 2020`, `Movie.2020.1080p.WEB-DL.x264-TXT` and
#   `Movie.Part.Two.2022.1080p.WEB-DL.x264-TXT`. `Native.search/1` sends it no search request;
#   the standard movie search of BEST_RELEASE and JUDGED sends it that text (#1632).
#
# A `t=caps` request to Dev NZB or Dev Torznab gets caps with `search`, `movie-search` and
# `tv-search`, and any other request to them or to Dev text-only an empty feed. Native also
# searches every other indexer `Cinder.Indexers.searchable/0` returns, so their rows and
# outcomes show too (`IndexerSource.Native`'s moduledoc names those it sends no request to). The
# script prints:
#
# - `HEAD`: the commit the run uses;
# - `ROWS`: `Native.search("tt1")`'s rows, each with its title, indexer name, protocol,
#   indexer source, link and link origin, or the error it answered;
# - `REPORT`: that search's report, one outcome per indexer;
# - `STATUS`: each dev indexer's backoff state after it (`IndexerStatus.read/1`);
# - `REPORT2`: a second `Native.search("tt1")`'s report, where an indexer in backoff reads
#   skipped and one with rejected credentials failed, with no request sent to either;
# - `BEST_RELEASE`: `Cinder.Acquisition.best_release/3`'s pick through Native;
# - `JUDGED`: each row of `Cinder.Acquisition.judge_movie/3` through Native, with its title,
#   indexer name, query origins, the stage that dropped it (nil when kept) and its verdict. The
#   Title.Year rule drops Dev text-only's `Movie.Part.Two` row at `:title_guard`;
# - `REQUESTS`: each request the listener received, in the order it answered them, with the
#   milliseconds from the script starting the listener to the request's arrival and the status it
#   answered, and a `--` line where REPORT2's, BEST_RELEASE's and JUDGED's searches start. Dev
#   flaky's 502 and the retry 2 s later show here.
#
# Edit `DevNativeSearch.Listener.answer/3` for another answer: an `<error>` code, another status,
# caps without `movie-search`, or a download link that redirects or answers 429. A grab through
# Native goes after `JUDGED` and before `REQUESTS`, with a `--` line of its own and its result
# printed the same way.
defmodule DevNativeSearch.Listener do
  @behaviour Plug

  import Plug.Conn

  @caps ~s(<?xml version="1.0" encoding="UTF-8"?><caps><searching>) <>
          ~s(<search available="yes" supportedParams="q"/>) <>
          ~s(<movie-search available="yes" supportedParams="q,imdbid"/>) <>
          ~s(<tv-search available="yes" supportedParams="q,season,ep,tvdbid"/>) <>
          ~s(</searching><categories><category id="2000" name="Movies"/>) <>
          ~s(<category id="5000" name="TV"/></categories></caps>)

  # Dev text-only's caps: the same, with `imdbid` gone from movie-search. The raise stops the
  # script when an edit to `@caps` leaves nothing for the replace to match.
  @text_caps String.replace(@caps, ~s(supportedParams="q,imdbid"), ~s(supportedParams="q"))
  if @text_caps == @caps, do: raise("@caps lost movie-search's \"q,imdbid\"; fix @text_caps")

  @nzb ~s(<?xml version="1.0" encoding="UTF-8"?>) <>
         ~s(<nzb xmlns="http://www.newzbin.com/DTD/2003/nzb"><file poster="dev" date="0" ) <>
         ~s(subject="Movie.2020.1080p.BluRay.x264-GRP.mkv"><groups><group>alt.binaries.dev) <>
         ~s(</group></groups><segments><segment bytes="1" number="1">dev@example) <>
         ~s(</segment></segments></file></nzb>)

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn = fetch_query_params(conn)
    line = conn.request_path <> "?" <> conn.query_string
    at = System.monotonic_time(:millisecond) - :persistent_term.get(:dev_native_search_t0)

    conn
    |> register_before_send(fn conn ->
      Agent.update(DevNativeSearch.Log, &["+#{at}ms #{conn.status} #{conn.method} #{line}" | &1])
      conn
    end)
    |> answer(conn.path_info, conn.query_params)
  end

  defp answer(conn, ["limited" | _], _query) do
    conn |> put_resp_header("retry-after", "3600") |> send_resp(429, "")
  end

  defp answer(conn, ["rejected" | _], _query) do
    xml(conn, ~s(<?xml version="1.0" encoding="UTF-8"?><error code="100" description="Bad key"/>))
  end

  # Dev flaky's first request of the run gets a 502; its later ones answer as Dev NZB's do.
  defp answer(conn, ["flaky" | rest], query) do
    if Agent.get_and_update(DevNativeSearch.Flaky, &{&1, false}),
      do: send_resp(conn, 502, ""),
      else: answer(conn, ["nzb" | rest], query)
  end

  defp answer(conn, ["nzb", "get" | _], _query) do
    conn |> put_resp_content_type("application/x-nzb") |> send_resp(200, @nzb)
  end

  defp answer(conn, ["text" | _], %{"t" => "caps"}), do: xml(conn, @text_caps)

  defp answer(conn, _path, %{"t" => "caps"}), do: xml(conn, @caps)

  defp answer(conn, ["text" | _], %{"t" => "search", "q" => "Movie 2020"}) do
    items =
      for {title, hash} <- [
            {"Movie.2020.1080p.WEB-DL.x264-TXT", "1111111111111111111111111111111111111111"},
            {"Movie.Part.Two.2022.1080p.WEB-DL.x264-TXT",
             "2222222222222222222222222222222222222222"}
          ] do
        link = ~s(<torznab:attr name="magneturl" value="magnet:?xt=urn:btih:#{hash}"/>)
        item(title, link, 7_000_000_000)
      end

    xml(conn, rss(Enum.join(items)))
  end

  defp answer(conn, ["nzb" | _], %{"t" => "movie", "imdbid" => "0000001"}) do
    link = ~s(<enclosure url="#{base()}/nzb/get/1.nzb" length="1" type="application/x-nzb"/>)
    xml(conn, rss(item("Movie.2020.1080p.BluRay.x264-GRP", link, 8_000_000_000)))
  end

  defp answer(conn, ["tor" | _], %{"t" => "movie", "imdbid" => "0000001"}) do
    magnet = "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567"
    link = ~s(<torznab:attr name="magneturl" value="#{magnet}"/>)
    xml(conn, rss(item("Movie.2020.2160p.WEB-DL.x265-TOR", link, 12_000_000_000)))
  end

  defp answer(conn, _path, _query), do: xml(conn, rss(""))

  def base, do: "http://127.0.0.1:#{port()}"

  def port, do: String.to_integer(System.get_env("DEV_NATIVE_PORT", "4199"))

  defp rss(items) do
    ~s(<?xml version="1.0" encoding="UTF-8"?><rss version="2.0" ) <>
      ~s(xmlns:newznab="http://www.newznab.com/DTD/2010/feeds/attributes/" ) <>
      ~s(xmlns:torznab="http://torznab.com/schemas/2015/feed"><channel><title>Dev</title>) <>
      items <> "</channel></rss>"
  end

  defp item(title, link, size) do
    "<item><title>#{title}</title>#{link}" <>
      "<pubDate>Wed, 25 Nov 2026 10:30:00 +0000</pubDate>" <>
      ~s(<newznab:attr name="size" value="#{size}"/>) <>
      ~s(<newznab:attr name="category" value="2000"/></item>)
  end

  defp xml(conn, body) do
    conn |> put_resp_content_type("application/rss+xml") |> send_resp(200, body)
  end
end

if Mix.env() != :dev, do: Mix.raise("scripts/dev-native-search.exs runs with MIX_ENV=dev only")

Logger.configure(level: :warning)
{:ok, _, _} = Ecto.Migrator.with_repo(Cinder.Repo, &Ecto.Migrator.run(&1, :up, all: true))
{:ok, _} = Application.ensure_all_started(:cinder)
{:ok, _} = Agent.start_link(fn -> [] end, name: DevNativeSearch.Log)
{:ok, _} = Agent.start_link(fn -> true end, name: DevNativeSearch.Flaky)
:persistent_term.put(:dev_native_search_t0, System.monotonic_time(:millisecond))

{:ok, _} =
  Bandit.start_link(
    plug: DevNativeSearch.Listener,
    ip: {127, 0, 0, 1},
    port: DevNativeSearch.Listener.port(),
    startup_log: false
  )

alias Cinder.Acquisition
alias Cinder.Acquisition.IndexerSource.Native
alias Cinder.Acquisition.IndexerSource.Native.IndexerStatus
alias Cinder.Indexers

dev_indexers = [
  {"Dev NZB", :newznab, "/nzb/api"},
  {"Dev Torznab", :torznab, "/tor/api"},
  {"Dev limited", :newznab, "/limited/api"},
  {"Dev rejected", :newznab, "/rejected/api"},
  {"Dev flaky", :newznab, "/flaky/api"},
  {"Dev text-only", :torznab, "/text/api"}
]

names = MapSet.new(dev_indexers, &elem(&1, 0))
for %{name: name, id: id} <- Indexers.list(), name in names, do: :ok = Indexers.delete(nil, id)

for {name, type, path} <- dev_indexers do
  attrs = %{name: name, type: type, base_url: DevNativeSearch.Listener.base(), api_path: path}
  {:ok, _} = Indexers.create(nil, attrs, %{"api_key" => "dev-native-key-0123456789"})
end

{head, 0} = System.cmd("git", ["rev-parse", "HEAD"])
IO.puts("HEAD " <> String.trim(head))

context = %{imdb_id: "tt1", title: "Movie", year: 2020, aliases: [], localized_titles: []}
fields = [:title, :indexer_name, :protocol, :indexer_source, :download_url, :download_url_origin]

case Native.search("tt1") do
  {:ok, rows, report} ->
    IO.inspect(Enum.map(rows, &Map.take(&1, fields)), label: "ROWS", limit: :infinity)
    IO.inspect(report, label: "REPORT", limit: :infinity)

  other ->
    IO.inspect(other, label: "ROWS", limit: :infinity)
end

dev_rows = Enum.filter(Indexers.list(), &(&1.name in names))

status_fields = [
  :backoff,
  :backoff_until,
  :level,
  :failures_in_row,
  :last_failure,
  :last_failure_code,
  :last_failure_at,
  :credentials_rejected,
  :credentials_rejected_by,
  :credentials_rejected_code,
  :last_success_at
]

statuses = IndexerStatus.read(dev_rows)

for indexer <- dev_rows do
  IO.inspect({indexer.name, Map.take(statuses[indexer.id], status_fields)}, label: "STATUS")
end

Agent.update(DevNativeSearch.Log, &["-- REPORT2 search" | &1])

case Native.search("tt1") do
  {:ok, _rows, report} -> IO.inspect(report, label: "REPORT2", limit: :infinity)
  other -> IO.inspect(other, label: "REPORT2", limit: :infinity)
end

Agent.update(DevNativeSearch.Log, &["-- BEST_RELEASE search" | &1])

pick =
  case Acquisition.best_release("tt1", context, indexer_source: Native) do
    {:ok, release} -> {:ok, release.title, release.protocol, release.indexer_source}
    other -> other
  end

IO.inspect(pick, label: "BEST_RELEASE")

Agent.update(DevNativeSearch.Log, &["-- JUDGED search" | &1])

case Acquisition.judge_movie("tt1", context, indexer_source: Native) do
  {:ok, judged} ->
    for row <- judged.rows do
      release = row.release

      IO.inspect(
        {release.title, release.indexer_name, release.query_origins, row.dropped_at, row.verdict},
        label: "JUDGED",
        limit: :infinity
      )
    end

  other ->
    IO.inspect(other, label: "JUDGED", limit: :infinity)
end

IO.puts("REQUESTS:")
DevNativeSearch.Log |> Agent.get(&Enum.reverse/1) |> Enum.each(&IO.puts("  " <> &1))
