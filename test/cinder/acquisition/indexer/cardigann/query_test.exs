defmodule Cinder.Acquisition.Indexer.Cardigann.QueryTest do
  # The search URLs `Query.plan/4` builds in a definition's encoding (#1678), on a definition
  # written for Cinder (`Cinder.CardigannFixtures`).
  use ExUnit.Case, async: true

  import Cinder.CardigannFixtures

  alias Cinder.Acquisition.Indexer.Cardigann.Query
  alias Cinder.Indexers.Definitions.Loader

  @now ~U[2026-11-26 12:00:00Z]

  defp urls(encoding, text, edit \\ & &1) do
    {:ok, definition} =
      nyaa_like(&(&1 |> Map.put("encoding", encoding) |> edit.())) |> bytes() |> Loader.load()

    config = %{base_url: nyaa_base(), values: %{}}

    {:ok, planned} =
      Query.plan(definition, config, {:search_tv_query, text, categories: [5070]}, @now)

    for {:ok, %{pages: pages}} <- planned, page <- pages, do: page.url
  end

  defp query(url), do: URI.parse(url).query

  test "the keywords go out in the definition's encoding" do
    # "Фрирен" in windows-1251, then in UTF-8.
    assert [url | _] = urls("windows-1251", "Фрирен")
    assert query(url) =~ "q=%D4%F0%E8%F0%E5%ED"

    # The issue's own example: "А" is 0xC0 in windows-1251.
    assert [url | _] = urls("windows-1251", "А")
    assert query(url) =~ "q=%C0"

    assert [url | _] = urls("UTF-8", "Фрирен")
    assert query(url) =~ "q=%D0%A4%D1%80%D0%B8%D1%80%D0%B5%D0%BD"
  end

  test "a urlencode keyword filter writes the definition's bytes, then the URL encodes its %" do
    edit = &put_in(&1, ["search", "keywordsfilters"], [%{"name" => "urlencode"}])

    assert [url | _] = urls("windows-1251", "Дюна", edit)
    assert query(url) =~ "q=%25C4%25FE%25ED%25E0"
  end

  test "an input's key and value go out in it too, and a character it lacks as ?" do
    edit = fn definition ->
      update_in(definition, ["search", "inputs"], fn %{values: values} ->
        obj(values ++ [{"жанр", "Аниме ✓"}])
      end)
    end

    assert [url | _] = urls("windows-1251", "x", edit)
    # "жанр" is E6 E0 ED F0, "Аниме" C0 ED E8 EC E5; "✓" has no windows-1251 byte.
    assert query(url) =~ "%E6%E0%ED%F0=%C0%ED%E8%EC%E5%20%3F"
  end

  defp pages(encoding, text, edit) do
    {:ok, definition} =
      nyaa_like(&(&1 |> Map.put("encoding", encoding) |> edit.())) |> bytes() |> Loader.load()

    assert definition.unsupported == []
    config = %{base_url: nyaa_base(), values: %{}}

    {:ok, planned} =
      Query.plan(definition, config, {:search_tv_query, text, categories: [5070]}, @now)

    for {:ok, %{pages: pages}} <- planned, page <- pages, do: page
  end

  defp one_path(path), do: &put_in(&1, ["search", "paths"], [path])

  # The `dotnet_encode` row and the POST test's `$raw` body ran in `dotnet fsi` (SDK 8.0.427,
  # .NET 8.0.33) on 2026-11-27: `WebUtility.UrlEncode(text)`, then for `$raw` Prowlarr's
  # `GetQueryString` pass, `encoding.GetString(WebUtility.UrlEncodeToBytes(encoding.GetBytes(v),
  # 0, n))` with windows-1251 from `CodePagesEncodingProvider`.
  test "a POST path's form body goes out in the definition's encoding, its URL with no query" do
    post = %{
      "path" => "/search",
      "method" => "post",
      "inputs" => obj([{"q", "{{ .Keywords }}"}, {"$raw", "x={{ .Keywords }}"}])
    }

    assert [page] = pages("windows-1251", "Дюна", one_path(post))
    assert page.method == :post
    assert page.url == nyaa_base() <> "search"
    # The plain value once, in windows-1251. The `$raw` value twice: the template's
    # `WebUtility.UrlEncode` writes UTF-8 whatever the definition's encoding, then the query
    # builder encodes that text again.
    assert page.body ==
             "f=0&c=0_0&s=id&o=desc&q=%C4%FE%ED%E0&x=%25D0%2594%25D1%258E%25D0%25BD%25D0%25B0"
  end

  test "a $raw key keeps its brackets percent-encoded, so the URL still parses" do
    raw = %{"path" => "/", "inputs" => obj([{"$raw", "kat[]=1&filter[a][]=2&a#b=3"}])}

    assert [page] = pages("UTF-8", "x", one_path(raw))

    assert URI.parse(page.url).query ==
             "f=0&c=0_0&s=id&o=desc&kat%5B%5D=1&filter%5Ba%5D%5B%5D=2&a%23b=3"

    assert {:ok, _uri} = URI.new(page.url)
  end

  # Ran in `dotnet fsi`, as the note above the POST test says.
  test "dotnet_encode/2 leaves -_.!*() and letters, writes + for a space and upper-case hex" do
    assert Query.dotnet_encode("Spider-Man (2002)! ~x*_.'é/") ==
             "Spider-Man+(2002)!+%7Ex*_.%27%C3%A9%2F"
  end
end
