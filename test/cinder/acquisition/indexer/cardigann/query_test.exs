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
end
