defmodule Cinder.Books.Metadata.Hardcover do
  @moduledoc """
  Secondary `Cinder.Books.Metadata` impl, speaking the Bookshelf Hardcover metadata-proxy shape
  frozen in `test/support/fixtures/books/provider-v1.json`: `GET /search?q=` returns bare id
  triples, `GET /work/{foreign_id}` returns the work in full.

  Because search returns no titles, judging a candidate means fetching it — so `search/1` fetches
  the first five hits and builds candidates from their work documents. That is up to six requests
  for a search, which is affordable precisely because this adapter is the *secondary*: the
  resolver only reaches it when Open Library had no reliable answer.

  `bibliography/1` (B5, not part of the frozen B0 corpus shape) assumes
  `GET /author/{foreign_id}/works` returns `{"works": [<work document>, ...]}` — full work
  documents directly, the same shape `get_work/1` normalizes, so one bounded request needs no
  per-candidate follow-up fetch the way bare-id `search/1` results do.

  The proxy is deployment-specific and has no sensible default. Unconfigured, every call returns
  `{:error, :not_configured}` and the resolver carries on with Open Library alone.
  """
  @behaviour Cinder.Books.Metadata

  alias Cinder.HTTPPolicy

  @max_response_bytes 4 * 1024 * 1024
  @max_search_fetches 5

  @impl true
  def provider, do: :hardcover

  @impl true
  def search(query) when is_binary(query) do
    with {:ok, hits} <- search_hits(query) do
      work_ids =
        hits
        |> Enum.flat_map(fn
          %{"work_id" => work_id} -> work_id |> id() |> List.wrap()
          _malformed -> []
        end)
        |> Enum.uniq()
        |> Enum.take(@max_search_fetches)

      case {work_ids, Enum.flat_map(work_ids, &fetch_candidate/1)} do
        {[], _candidates} -> {:ok, []}
        {_ids, []} -> {:error, :all_fetches_failed}
        {_ids, candidates} -> {:ok, candidates}
      end
    end
  end

  @impl true
  # The proxy's per-author endpoint returns full work documents directly (unlike `/search`,
  # which returns bare ids) — one bounded request, no per-candidate follow-up fetch needed.
  def bibliography(foreign_id) when is_binary(foreign_id) do
    case request(url: "/author/#{foreign_id}/works") do
      {:ok, %{status: 200, body: %{"works" => works}}} when is_list(works) ->
        {:ok, Enum.flat_map(works, &bibliography_candidate/1)}

      {:ok, %{status: 200}} ->
        {:error, :unexpected_response}

      other ->
        error(other)
    end
  end

  # One malformed work document drops out of the bibliography rather than failing the whole call.
  defp bibliography_candidate(body) do
    case normalize_work(body) do
      {:ok, work} -> [candidate(work)]
      {:error, _reason} -> []
    end
  end

  # One hit that cannot be fetched drops out of the candidate list; the resolver judges what is
  # left rather than failing the whole search over one bad id.
  defp fetch_candidate(work_id) do
    case get_work(work_id) do
      {:ok, work} -> [candidate(work)]
      {:error, _reason} -> []
    end
  end

  @impl true
  def get_work(foreign_id) when is_binary(foreign_id) do
    case request(url: "/work/#{foreign_id}") do
      {:ok, %{status: 200, body: %{} = body}} ->
        normalize_work(body)

      {:ok, %{status: 200}} ->
        {:error, :unexpected_response}

      other ->
        error(other)
    end
  end

  @impl true
  # Bounded, unauthenticated probe — mirrors OpenLibrary's. `request/1` itself already resolves
  # to `{:error, :not_configured}` when no `base_url` is set, so an unconfigured Hardcover shows
  # a clean row instead of a raised/opaque error.
  def health do
    case request(
           url: "/search",
           params: [q: "health"],
           receive_timeout: 3_000,
           connect_options: [timeout: 3_000]
         ) do
      {:error, :not_configured} = err -> err
      {:ok, %{status: status}} when status in 200..299 -> :ok
      other -> error(other)
    end
  end

  defp search_hits(query) do
    case request(url: "/search", params: [q: query]) do
      {:ok, %{status: 200, body: hits}} when is_list(hits) -> {:ok, hits}
      {:ok, %{status: 200}} -> {:error, :unexpected_response}
      other -> error(other)
    end
  end

  # The candidate view of an already-fetched work. `edition_count` is the observed edition list,
  # which is what the resolver's tie-break wants.
  defp candidate(work) do
    %{
      provider: provider(),
      foreign_id: work.foreign_id,
      title: work.title,
      contributors: work.contributors,
      contributors_incomplete: work.contributors_incomplete,
      first_published_year: work.first_published_on && work.first_published_on.year,
      edition_count: length(work.editions)
    }
  end

  defp normalize_work(%{"foreign_id" => raw_id, "title" => title} = body) when is_binary(title) do
    case id(raw_id) do
      nil ->
        {:error, :unexpected_response}

      foreign_id ->
        credited = body |> Map.get("authors") |> List.wrap()
        authors = Enum.flat_map(credited, &normalize_author/1)

        {:ok,
         %{
           provider: provider(),
           foreign_id: foreign_id,
           title: title,
           first_published_on: date(body["release_date"]),
           overview: nil,
           contributors: authors,
           # Two ways to be incomplete, and the second is the one that is easy to miss: nobody
           # credited at all, *or* a payload naming two people where only one carried a usable
           # id. Testing only for an empty list reports a partial drop as complete, and this flag
           # is the only signal an operator gets that a contributor is missing.
           contributors_incomplete: authors == [] or length(authors) != length(credited),
           editions:
             body |> Map.get("editions") |> List.wrap() |> Enum.flat_map(&normalize_edition/1),
           series: body |> Map.get("series") |> List.wrap() |> Enum.flat_map(&normalize_series/1)
         }}
    end
  end

  defp normalize_work(_body), do: {:error, :unexpected_response}

  # A provider id is a string or a number; anything else identifies nothing and is dropped rather
  # than coerced. `to_string/1` raises on a map or a list, and everything here runs inside the
  # refresher's `isolate/2`, which only logs what it rescues — a raise there recurs every tick.
  defp id(value) when is_binary(value), do: presence(value)
  defp id(value) when is_integer(value), do: Integer.to_string(value)
  defp id(_value), do: nil

  # A series position is lossless by contract: "1", "1.5" and "Book Two" all survive as written,
  # including when the proxy sends a number rather than a string.
  defp position(value) when is_binary(value), do: presence(value)
  defp position(value) when is_number(value), do: to_string(value)
  defp position(_value), do: nil

  defp normalize_author(%{"foreign_id" => raw_id, "name" => name}) when is_binary(name) do
    case id(raw_id) do
      nil -> []
      foreign_id -> [%{foreign_id: foreign_id, name: name, role: "author"}]
    end
  end

  defp normalize_author(_author), do: []

  defp normalize_edition(%{"foreign_id" => raw_id, "title" => title} = entry)
       when is_binary(title) do
    case {id(raw_id), media_kind(entry)} do
      {nil, _kind} ->
        []

      {_foreign_id, nil} ->
        []

      {foreign_id, kind} ->
        [
          %{
            foreign_id: foreign_id,
            media_kind: kind,
            title: title,
            language: presence(entry["language"]),
            format: presence(entry["format"]),
            publisher: presence(entry["publisher"]),
            release_date: date(entry["release_date"]),
            abridged: nil,
            isbn13: presence(entry["isbn13"]),
            asin: presence(entry["asin"])
          }
        ]
    end
  end

  defp normalize_edition(_entry), do: []

  defp normalize_series(%{"title" => title} = entry) when is_binary(title),
    do: [%{name: title, position: position(entry["position"])}]

  defp normalize_series(_entry), do: []

  # `is_ebook` is set for Kindle editions only — the proxy leaves it false for its own "ebook"
  # format — so the format string decides and the flag is a fallback. Print bindings map to no
  # Cinder media kind and are dropped: `book_editions.media_kind` allows ebook/audiobook only.
  defp media_kind(entry) do
    format = format_key(entry["format"])

    cond do
      String.contains?(format, "audio") -> :audiobook
      String.contains?(format, ["ebook", "e-book", "kindle", "nook", "epub"]) -> :ebook
      entry["is_ebook"] == true -> :ebook
      true -> nil
    end
  end

  # A format that is not a string tells us nothing, and `to_string/1` raises on a map or a list —
  # on the refresher's tick path, where `isolate/2` rescues without parking.
  defp format_key(format) when is_binary(format), do: String.downcase(format)
  defp format_key(_format), do: ""

  # The proxy stamps "YYYY-MM-DD HH:MM:SS"; only the date half is catalog data.
  defp date(value) when is_binary(value) do
    case value |> String.split(" ") |> hd() |> Date.from_iso8601() do
      {:ok, date} -> date
      {:error, _reason} -> nil
    end
  end

  defp date(_value), do: nil

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil

  defp request(opts) do
    config = Application.get_env(:cinder, __MODULE__, [])

    case Keyword.get(config, :base_url) do
      base_url when is_binary(base_url) and base_url != "" ->
        [
          base_url: base_url,
          receive_timeout: 15_000,
          pool_timeout: 5_000,
          connect_options: [timeout: 5_000],
          retry: false
        ]
        |> auth(Keyword.get(config, :api_key))
        |> Keyword.merge(opts)
        |> Keyword.merge(Keyword.get(config, :req_options, []))
        |> Keyword.put(:redirect, false)
        |> Req.new()
        |> HTTPPolicy.bounded_request(@max_response_bytes)

      _unset ->
        {:error, :not_configured}
    end
  end

  defp auth(opts, key) when is_binary(key) and key != "",
    do: Keyword.put(opts, :auth, {:bearer, key})

  defp auth(opts, _key), do: opts

  defp error({:ok, %{status: status}}), do: {:error, {:hardcover_status, status}}
  defp error({:error, reason}), do: {:error, reason}
end
