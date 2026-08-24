defmodule Cinder.Books.Metadata.Hardcover do
  @moduledoc """
  Secondary `Cinder.Books.Metadata` impl, speaking the Bookshelf Hardcover metadata-proxy shape
  frozen in `test/support/fixtures/books/provider-v1.json`: `GET /search?q=` returns bare id
  triples, `GET /work/{foreign_id}` returns the work in full.

  Because search returns no titles, judging a candidate means fetching it — so `search/1` fetches
  the first five hits and builds candidates from their work documents. That is up to six requests
  for a search, which is affordable precisely because this adapter is the *secondary*: the
  resolver only reaches it when Open Library had no reliable answer.

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
      candidates =
        hits
        |> Enum.map(& &1["work_id"])
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.take(@max_search_fetches)
        |> Enum.flat_map(&fetch_candidate/1)

      {:ok, candidates}
    end
  end

  # One hit that cannot be fetched drops out of the candidate list; the resolver judges what is
  # left rather than failing the whole search over one bad id.
  defp fetch_candidate(work_id) do
    case get_work(to_string(work_id)) do
      {:ok, work} -> [candidate(work)]
      {:error, _reason} -> []
    end
  end

  @impl true
  def get_work(foreign_id) when is_binary(foreign_id) do
    case request(url: "/work/#{foreign_id}") do
      {:ok, %{status: 200, body: %{"foreign_id" => _, "title" => title} = body}}
      when is_binary(title) ->
        {:ok, normalize_work(body)}

      {:ok, %{status: 200}} ->
        {:error, :unexpected_response}

      other ->
        error(other)
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
      first_published_year: work.first_published_on && work.first_published_on.year,
      edition_count: length(work.editions)
    }
  end

  defp normalize_work(body) do
    authors = body |> Map.get("authors") |> List.wrap() |> Enum.flat_map(&normalize_author/1)

    %{
      provider: provider(),
      foreign_id: to_string(body["foreign_id"]),
      title: body["title"],
      first_published_on: date(body["release_date"]),
      overview: nil,
      contributors: authors,
      contributors_incomplete: authors == [],
      editions: body |> Map.get("editions") |> List.wrap() |> Enum.flat_map(&normalize_edition/1),
      series: body |> Map.get("series") |> List.wrap() |> Enum.flat_map(&normalize_series/1)
    }
  end

  defp normalize_author(%{"foreign_id" => id, "name" => name})
       when is_binary(name) and not is_nil(id),
       do: [%{foreign_id: to_string(id), name: name, role: "author"}]

  defp normalize_author(_author), do: []

  defp normalize_edition(%{"foreign_id" => id, "title" => title} = entry)
       when is_binary(title) do
    case media_kind(entry) do
      nil ->
        []

      kind ->
        [
          %{
            foreign_id: to_string(id),
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
    do: [%{name: title, position: entry["position"] && to_string(entry["position"])}]

  defp normalize_series(_entry), do: []

  # `is_ebook` is set for Kindle editions only — the proxy leaves it false for its own "ebook"
  # format — so the format string decides and the flag is a fallback. Print bindings map to no
  # Cinder media kind and are dropped: `book_editions.media_kind` allows ebook/audiobook only.
  defp media_kind(entry) do
    format = entry["format"] |> to_string() |> String.downcase()

    cond do
      String.contains?(format, "audio") -> :audiobook
      String.contains?(format, ["ebook", "e-book", "kindle", "nook", "epub"]) -> :ebook
      entry["is_ebook"] == true -> :ebook
      true -> nil
    end
  end

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
