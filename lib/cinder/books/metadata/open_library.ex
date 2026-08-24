defmodule Cinder.Books.Metadata.OpenLibrary do
  @moduledoc """
  Primary `Cinder.Books.Metadata` impl, backed by `Req` against Open Library's public API.
  No credential — the search and works endpoints are open.

  Two requests per `get_work/1`: `search.json?q=key:...` re-uses the search normalizer to get the
  work plus its contributors in one shot (the `/works/{id}.json` document carries only author
  *keys*, which would cost one request per contributor), and `/works/{id}/editions.json` for the
  edition layer.

  Open Library records `physical_format` per edition and has no format at all for most digital
  ones, so a work here can legitimately land with **zero** editions. That is honest — inventing an
  edition Cinder cannot verify is what the parity contract forbids — and the Hardcover secondary
  is what carries dense edition/format detail.
  """
  @behaviour Cinder.Books.Metadata

  alias Cinder.HTTPPolicy

  @default_base_url "https://openlibrary.org"
  @max_response_bytes 4 * 1024 * 1024
  @search_limit 10
  @editions_limit 50
  @search_fields "key,title,author_name,author_key,first_publish_year,edition_count"

  @impl true
  def provider, do: :openlibrary

  @impl true
  def search(query) when is_binary(query) do
    with {:ok, docs} <- search_docs(q: query, fields: @search_fields, limit: @search_limit) do
      {:ok, Enum.flat_map(docs, &normalize_candidate/1)}
    end
  end

  @impl true
  def get_work(foreign_id) when is_binary(foreign_id) do
    with {:ok, docs} <- search_docs(q: ~s(key:"/works/#{foreign_id}"), fields: @search_fields),
         {:ok, candidate} <- one_candidate(docs, foreign_id),
         {:ok, editions} <- editions(foreign_id) do
      {:ok,
       %{
         provider: candidate.provider,
         foreign_id: candidate.foreign_id,
         title: candidate.title,
         first_published_on: year_date(candidate.first_published_year),
         overview: nil,
         contributors: candidate.contributors,
         contributors_incomplete: candidate.contributors == [],
         editions: editions,
         series: []
       }}
    end
  end

  defp search_docs(params) do
    case request(url: "/search.json", params: params) do
      {:ok, %{status: 200, body: %{"docs" => docs}}} when is_list(docs) -> {:ok, docs}
      {:ok, %{status: 200}} -> {:error, :unexpected_response}
      other -> error(other)
    end
  end

  defp one_candidate(docs, foreign_id) do
    case Enum.flat_map(docs, &normalize_candidate/1) do
      [%{foreign_id: ^foreign_id} = candidate | _] -> {:ok, candidate}
      _other -> {:error, :not_found}
    end
  end

  defp editions(foreign_id) do
    case request(url: "/works/#{foreign_id}/editions.json", params: [limit: @editions_limit]) do
      {:ok, %{status: 200, body: %{"entries" => entries}}} when is_list(entries) ->
        {:ok, Enum.flat_map(entries, &normalize_edition/1)}

      {:ok, %{status: 200}} ->
        {:error, :unexpected_response}

      other ->
        error(other)
    end
  end

  # A doc with no work key or no title identifies nothing and is dropped rather than repaired.
  defp normalize_candidate(%{"key" => "/works/" <> foreign_id, "title" => title} = doc)
       when is_binary(title) do
    [
      %{
        provider: provider(),
        foreign_id: foreign_id,
        title: title,
        contributors: contributors(doc),
        first_published_year: doc["first_publish_year"],
        edition_count: doc["edition_count"] || 0
      }
    ]
  end

  defp normalize_candidate(_doc), do: []

  # author_name and author_key are positional parallel lists. A name with no key cannot be
  # identified, so it is dropped and surfaces as `contributors_incomplete` on the work.
  defp contributors(doc) do
    doc["author_name"]
    |> List.wrap()
    |> Enum.zip(List.wrap(doc["author_key"]))
    |> Enum.map(fn {name, key} -> %{foreign_id: key, name: name, role: "author"} end)
  end

  defp normalize_edition(%{"key" => "/books/" <> foreign_id, "title" => title} = entry)
       when is_binary(title) do
    case media_kind(entry["physical_format"]) do
      nil ->
        []

      kind ->
        [
          %{
            foreign_id: foreign_id,
            media_kind: kind,
            title: title,
            language: language(entry),
            format: entry["physical_format"],
            publisher: entry["publishers"] |> List.wrap() |> first_string(),
            release_date: nil,
            abridged: nil,
            isbn13: entry["isbn_13"] |> List.wrap() |> first_string(),
            asin: nil
          }
        ]
    end
  end

  defp normalize_edition(_entry), do: []

  # `physical_format` is free text and mostly describes print, which has no Cinder media kind.
  # Anything not recognisably digital is skipped rather than guessed at.
  defp media_kind(format) do
    format = format |> to_string() |> String.downcase()

    cond do
      String.contains?(format, "audio") -> :audiobook
      String.contains?(format, ["ebook", "e-book", "kindle", "nook", "epub"]) -> :ebook
      true -> nil
    end
  end

  defp language(entry) do
    entry["languages"]
    |> List.wrap()
    |> Enum.find_value(fn
      %{"key" => "/languages/" <> code} -> code
      _other -> nil
    end)
  end

  defp first_string(list), do: Enum.find(list, &is_binary/1)

  defp year_date(year) when is_integer(year) and year > 0, do: Date.new!(year, 1, 1)
  defp year_date(_year), do: nil

  defp request(opts) do
    config = Application.get_env(:cinder, __MODULE__, [])

    # retry: false — same reasoning as the TMDB client: a hung provider should fail fast rather
    # than hold a search or a refresher tick for a minute of backoff.
    [
      base_url: Keyword.get(config, :base_url) || @default_base_url,
      receive_timeout: 15_000,
      pool_timeout: 5_000,
      connect_options: [timeout: 5_000],
      retry: false
    ]
    |> Keyword.merge(opts)
    |> Keyword.merge(Keyword.get(config, :req_options, []))
    |> Keyword.put(:redirect, false)
    |> Req.new()
    |> HTTPPolicy.bounded_request(@max_response_bytes)
  end

  defp error({:ok, %{status: status}}), do: {:error, {:openlibrary_status, status}}
  defp error({:error, reason}), do: {:error, reason}
end
