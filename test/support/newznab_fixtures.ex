defmodule Cinder.NewznabFixtures do
  @moduledoc """
  Hand-written Newznab and Torznab answers (#1624 point 1) and a `Cinder.NewznabStub` router for
  the tests that search configured indexers through the real adapters
  (`Cinder.Acquisition.Indexer.Newznab`, `Cinder.Acquisition.Indexer.Torznab`), alone or through
  `Cinder.Acquisition.IndexerSource.Native`. The element names follow Prowlarr's parsers
  (`b0b5774`), as `Cinder.Acquisition.Indexer.Newznab.Items` reads them.

  `route/1` stubs `Cinder.NewznabStub` with one answer function per base URL host. Each function
  takes the conn and its decoded query (`"apikey"` included) and answers through `respond/2`. A
  `t=caps` request a function does not answer itself gets `caps/1` with every mode. The stub
  sends the test process `{:newznab_request, host, query}` for each request.
  """

  import ExUnit.Assertions
  import Ecto.Query, only: [from: 2]

  alias Cinder.Acquisition.IndexerSource.Native.IndexerStatus
  alias Cinder.Indexers
  alias Cinder.Repo

  @key "nzb-key-0123456789"

  @modes %{
    "search" => ~s(available="yes" supportedParams="q"),
    "tv-search" => ~s(available="yes" supportedParams="q,season,ep,tvdbid"),
    "movie-search" => ~s(available="yes" supportedParams="q,imdbid"),
    "book-search" => ~s(available="yes" supportedParams="q,title,author")
  }

  @categories [2000, 2040, 3000, 3030, 5000, 5040, 5070, 7000, 7020]

  @doc "The API key every indexer `indexer!/3` creates holds."
  def key, do: @key

  @doc """
  Creates an enabled configured indexer of `type` on `https://<host>` with the API path `/api`
  and the key `key/0`, and returns it with its secrets.
  """
  def indexer!(type, host, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          name: "#{type} #{host}",
          type: type,
          base_url: "https://#{host}",
          api_path: "/api"
        },
        overrides
      )

    {:ok, row} = Indexers.create(nil, attrs, %{"api_key" => @key})
    {:ok, indexer} = Indexers.fetch_with_secrets(row.id)
    indexer
  end

  @doc """
  Deletes `indexer`'s backoff state, so the next request to it is sent whatever an earlier answer
  in the test recorded: each request reads that state once it holds the indexer's slot
  (`Cinder.Acquisition.Indexer.leased/4`).
  """
  def clear_status!(indexer) do
    Repo.delete_all(from(s in IndexerStatus, where: s.configured_indexer_id == ^indexer.id))
    :ok
  end

  @doc "A `t=caps` answer; `modes:` and `categories:` replace the defaults above."
  def caps(opts \\ []) do
    modes = Keyword.get(opts, :modes, @modes)
    categories = Keyword.get(opts, :categories, @categories)
    mode_lines = for {name, attrs} <- Enum.sort(modes), attrs, do: "<#{name} #{attrs}/>"
    category_lines = for id <- categories, do: ~s(<category id="#{id}" name="c#{id}"/>)

    ~s(<?xml version="1.0" encoding="UTF-8"?>) <>
      "<caps><searching>#{mode_lines}</searching><categories>#{category_lines}</categories></caps>"
  end

  @doc "An RSS answer holding `items` (strings from `item/2`)."
  def rss(items \\ []) do
    ~s(<?xml version="1.0" encoding="UTF-8"?>) <>
      ~s(<rss version="2.0" xmlns:newznab="http://www.newznab.com/DTD/2010/feeds/attributes/" ) <>
      ~s(xmlns:torznab="http://torznab.com/schemas/2015/feed"><channel><title>Indexer</title>) <>
      Enum.join(items) <> "</channel></rss>"
  end

  @doc """
  One item titled `title` with the link `link`: `{:nzb, url}`, `{:torrent, url}` or
  `{:magnet, url}`, plus `size:` (bytes), `category:` (an id) and `tvdbid:` attributes.
  """
  def item(title, link, opts \\ []) do
    attrs =
      for {name, key} <- [size: :size, category: :category, tvdbid: :tvdbid],
          value = Keyword.get(opts, key),
          do: ~s(<newznab:attr name="#{name}" value="#{value}"/>)

    "<item><title>#{escape(title)}</title>#{link(link)}" <>
      "<pubDate>Wed, 25 Nov 2026 10:30:00 +0000</pubDate>#{Enum.join(attrs)}</item>"
  end

  defp link({:nzb, url}),
    do: ~s(<enclosure url="#{escape(url)}" length="1" type="application/x-nzb"/>)

  defp link({:torrent, url}),
    do: ~s(<enclosure url="#{escape(url)}" length="1" type="application/x-bittorrent"/>)

  defp link({:magnet, url}), do: ~s(<torznab:attr name="magneturl" value="#{escape(url)}"/>)

  defp escape(text), do: text |> String.replace("&", "&amp;") |> String.replace("\"", "&quot;")

  @doc "A Newznab `<error>` answer."
  def error(code, description),
    do:
      ~s(<?xml version="1.0" encoding="UTF-8"?><error code="#{code}" description="#{description}"/>)

  @doc """
  Answers `conn` with `answer`: `{status, body}`, `{status, headers, body}` (a header list),
  `{:transport, reason}`, or a body for HTTP 200.
  """
  def respond(conn, {:transport, reason}), do: Req.Test.transport_error(conn, reason)
  def respond(conn, {status, body}) when is_integer(status), do: respond(conn, {status, [], body})

  def respond(conn, {status, headers, body}) when is_integer(status) do
    headers
    |> Enum.reduce(conn, fn {name, value}, conn ->
      Plug.Conn.put_resp_header(conn, name, value)
    end)
    |> Plug.Conn.send_resp(status, body)
  end

  def respond(conn, body) when is_binary(body), do: Plug.Conn.send_resp(conn, 200, body)

  @doc "Stubs `Cinder.NewznabStub` with `routes`, a map of host to answer function; see the moduledoc."
  def route(routes) do
    test_pid = self()

    Req.Test.stub(Cinder.NewznabStub, fn conn ->
      query = conn.query_params
      send(test_pid, {:newznab_request, conn.host, query})
      fun = Map.get(routes, conn.host) || flunk("no route for #{conn.host}")

      case {query, fun.(conn, query)} do
        {%{"t" => "caps"}, :default} -> respond(conn, caps())
        {_query, :default} -> respond(conn, rss())
        {_query, %Plug.Conn{} = conn} -> conn
        {_query, answer} -> respond(conn, answer)
      end
    end)
  end

  @doc "The search requests (no `t=caps`) the stub received for `host` so far, in order."
  def searches(host) do
    receive_all([])
    |> Enum.filter(fn {request_host, query} -> request_host == host and query["t"] != "caps" end)
    |> Enum.map(&elem(&1, 1))
  end

  defp receive_all(acc) do
    receive do
      {:newznab_request, host, query} -> receive_all([{host, query} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
