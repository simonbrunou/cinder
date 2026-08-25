defmodule Cinder.Books.RefresherTest do
  # The Refresher runs in its own process, so the mocks must be global; shared Sandbox
  # (async: false) lets that process use the test-owned DB connection.
  use Cinder.DataCase, async: false

  import ExUnit.CaptureLog
  import Mox

  alias Cinder.Books
  alias Cinder.Books.{Edition, Identifier, PrimaryMetadataMock, Refresher, SecondaryMetadataMock}
  alias Cinder.Books.Work

  setup :set_mox_global
  setup :verify_on_exit!

  # A poll stamps last-run into process-global :persistent_term; erase it so a recorded run
  # can't bleed into a suite that reads Cinder.Jobs.statuses/0.
  setup do
    on_exit(fn -> :persistent_term.erase({Refresher, :last_run}) end)
    :ok
  end

  setup do
    stub(PrimaryMetadataMock, :provider, fn -> :openlibrary end)
    stub(SecondaryMetadataMock, :provider, fn -> :hardcover end)
    :ok
  end

  test "a refresh folds the provider's current view back into the work" do
    work = imported_work()

    expect(PrimaryMetadataMock, :get_work, fn "OL50548W" ->
      {:ok, provider_work(title: "Beloved (25th Anniversary)", overview: "Revised.")}
    end)

    assert :ok = Refresher.refresh_one(reload(work))

    refreshed = Repo.get!(Work, work.id)
    assert refreshed.title == "Beloved (25th Anniversary)"
    assert refreshed.overview == "Revised."
  end

  test "a provider outage leaves the catalog byte-identical" do
    work = imported_work()
    before = snapshot()

    expect(PrimaryMetadataMock, :get_work, fn "OL50548W" -> {:error, :timeout} end)

    # Returning `{:error, _}` rather than raising is the point: `isolate/2` only logs what it
    # rescues, so an exception here would reappear on every tick, forever, with nothing parked.
    assert {:error, :unresolved} = Refresher.refresh_one(reload(work))
    assert snapshot() == before
  end

  test "a payload that omits a field does not clear the stored one" do
    work = imported_work()

    expect(PrimaryMetadataMock, :get_work, fn "OL50548W" ->
      {:ok, provider_work(overview: nil, first_published_on: nil, publisher: nil)}
    end)

    assert :ok = Refresher.refresh_one(reload(work))

    refreshed = Repo.get!(Work, work.id)
    assert refreshed.overview == "A ghost story."
    assert refreshed.first_published_on == ~D[1987-09-16]
    assert Repo.one(from e in Edition, select: e.publisher) == "Vintage"
  end

  test "a work with no provider work identity is skipped rather than searched" do
    work = imported_work()
    Repo.delete_all(from i in Identifier, where: i.work_id == ^work.id)

    assert {:error, :no_provider_identity} = Refresher.refresh_one(reload(work))
  end

  test "the refresh set is works with a monitoring target, and only those" do
    monitored = imported_work()
    _unmonitored = imported_work(work_foreign_id: "OL999W", edition_foreign_id: "OL999M")

    {:ok, _target} = Books.ensure_target(monitored, :ebook)

    assert Enum.map(Books.list_works_for_refresh(), & &1.id) == [monitored.id]
  end

  test "one work failing does not stop the pass" do
    first = imported_work()
    second = imported_work(work_foreign_id: "OL999W", edition_foreign_id: "OL999M")
    {:ok, _} = Books.ensure_target(first, :ebook)
    {:ok, _} = Books.ensure_target(second, :ebook)

    stub(PrimaryMetadataMock, :get_work, fn
      "OL50548W" ->
        {:error, :timeout}

      "OL999W" ->
        {:ok,
         provider_work(
           work_foreign_id: "OL999W",
           edition_foreign_id: "OL999M",
           title: "Refreshed"
         )}
    end)

    start_supervised!({Refresher, interval: 60_000})

    log = capture_log(fn -> assert :ok = Refresher.poll() end)

    assert Repo.get!(Work, first.id).title == "Beloved"
    assert Repo.get!(Work, second.id).title == "Refreshed"

    # Non-vacuous because the assertions above prove the failing work really did fail: had it
    # raised, `isolate/2` would have rescued and logged it here instead.
    refute log =~ "books refresher skipped"
  end

  defp imported_work(overrides \\ []) do
    {:ok, work} = Books.import_resolution(resolution(overrides))
    work
  end

  defp reload(work), do: Repo.preload(Repo.get!(Work, work.id), :identifiers)

  # Everything a refresh must not silently change.
  defp snapshot do
    %{
      works:
        Repo.all(
          from w in Work, order_by: w.id, select: {w.title, w.overview, w.first_published_on}
        ),
      editions:
        Repo.all(from e in Edition, order_by: e.id, select: {e.title, e.publisher, e.media_kind}),
      identifiers:
        Repo.all(from i in Identifier, order_by: i.id, select: {i.provider, i.kind, i.foreign_id})
    }
  end

  defp resolution(overrides), do: %{provider: :openlibrary, work: provider_work(overrides)}

  defp provider_work(overrides) do
    overrides = Map.new(overrides)

    %{
      provider: :openlibrary,
      foreign_id: Map.get(overrides, :work_foreign_id, "OL50548W"),
      title: Map.get(overrides, :title, "Beloved"),
      first_published_on: Map.get(overrides, :first_published_on, ~D[1987-09-16]),
      overview: Map.get(overrides, :overview, "A ghost story."),
      contributors: [%{foreign_id: "OL30084A", name: "Toni Morrison", role: "author"}],
      contributors_incomplete: false,
      editions: [
        %{
          foreign_id: Map.get(overrides, :edition_foreign_id, "OL2M"),
          media_kind: :ebook,
          title: "Beloved",
          language: "eng",
          format: "Ebook",
          publisher: Map.get(overrides, :publisher, "Vintage"),
          release_date: ~D[2004-06-08],
          abridged: nil,
          isbn13: nil,
          asin: nil
        }
      ],
      series: []
    }
  end
end
