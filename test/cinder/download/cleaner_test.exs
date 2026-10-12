defmodule Cinder.Download.CleanerTest do
  # async: false — the sweep runs in its own process against the test-owned (shared Sandbox)
  # connection, and status/0 stamps process-global :persistent_term.
  use Cinder.DataCase, async: false

  import Mox

  @moduletag :capture_log

  alias Cinder.Books
  alias Cinder.Catalog.Grab
  alias Cinder.Download.{Cleaner, ClientMock, Intent, SabnzbdClientMock}

  import Cinder.CatalogFixtures

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    on_exit(fn -> :persistent_term.erase({Cleaner, :last_run}) end)
    start_supervised!({Cleaner, interval: 60_000})
    # The usenet half of the sweep is exercised in its own test; elsewhere it has nothing to say.
    stub(SabnzbdClientMock, :list_managed, fn -> {:ok, []} end)
    :ok
  end

  defp entry(attrs) do
    Map.merge(%{id: "hash-1", operation_key: Ecto.UUID.generate(), state: :downloading}, attrs)
  end

  defp intent_for(key, remote_id) do
    Repo.insert!(%Intent{
      operation_key: key,
      kind: :movie,
      target_id: 1,
      protocol: :torrent,
      release: %{"title" => "R"},
      status: :submitted,
      remote_id: remote_id
    })
  end

  defp configure_limits(limits) do
    original = Application.get_env(:cinder, Cleaner, [])
    Application.put_env(:cinder, Cleaner, Keyword.merge(original, limits))
    on_exit(fn -> Application.put_env(:cinder, Cleaner, original) end)
  end

  test "removes an unclaimed in-flight download" do
    orphan = entry(%{id: "orphan", state: :downloading})

    expect(ClientMock, :list_managed, fn -> {:ok, [orphan]} end)

    expect(ClientMock, :remove, fn "orphan", opts ->
      assert Keyword.fetch!(opts, :delete_files),
             "a partial nothing owns is junk — take its files"

      :ok
    end)

    assert :ok = Cleaner.poll()
  end

  test "removes an unclaimed errored download" do
    expect(ClientMock, :list_managed, fn -> {:ok, [entry(%{id: "bad", state: :error})]} end)
    expect(ClientMock, :remove, fn "bad", _opts -> :ok end)

    assert :ok = Cleaner.poll()
  end

  test "never removes a completed download, claimed or not — seeding survives" do
    expect(ClientMock, :list_managed, fn ->
      {:ok, [entry(%{id: "seeding", state: :completed})]}
    end)

    # No `remove` expectation: verify_on_exit! fails the test if the sweep calls it.

    assert :ok = Cleaner.poll()
  end

  describe "completed usenet entries (#684)" do
    # A usenet job reports neither a ratio nor a seeding time and has nothing to seed, so once no
    # intent/movie/grab/book grab claims it the payload is dead weight — where the operator asked
    # for removal after a Usenet import, and once the client says it completed long enough ago
    # that its import is certainly done.
    setup do
      saved = Application.get_env(:cinder, :move_on_import)
      Application.put_env(:cinder, :move_on_import, true)

      on_exit(fn ->
        if is_nil(saved),
          do: Application.delete_env(:cinder, :move_on_import),
          else: Application.put_env(:cinder, :move_on_import, saved)
      end)

      stub(ClientMock, :list_managed, fn -> {:ok, []} end)
      :ok
    end

    defp completed_usenet(attrs) do
      entry(Map.merge(%{state: :completed, completed_at: System.os_time(:second) - 7200}, attrs))
    end

    # `Download.best_effort_remove/2` swallows a Mox.UnexpectedCallError, so a missing `remove`
    # expectation can't prove a "keeps" test: record every removal and refute it explicitly.
    defp record_removals(mock) do
      parent = self()

      stub(mock, :remove, fn id, opts ->
        send(parent, {:removed, id, opts})
        :ok
      end)
    end

    test "removes an unclaimed completed usenet entry together with its files" do
      stub(SabnzbdClientMock, :list_managed, fn ->
        {:ok, [completed_usenet(%{id: "nzo-done"})]}
      end)

      record_removals(SabnzbdClientMock)

      assert :ok = Cleaner.poll()
      assert_received {:removed, "nzo-done", opts}
      assert Keyword.fetch!(opts, :delete_files)
    end

    test "keeps a completed usenet entry a movie, grab or intent still claims" do
      key = Ecto.UUID.generate()

      Repo.insert!(%Intent{
        operation_key: key,
        kind: :movie,
        target_id: 1,
        protocol: :usenet,
        release: %{"title" => "R"},
        status: :submitted,
        remote_id: "nzo-intent"
      })

      movie_fixture(%{status: :downloaded, download_id: "nzo-movie", download_protocol: :usenet})

      stub(SabnzbdClientMock, :list_managed, fn ->
        {:ok,
         [
           completed_usenet(%{id: "nzo-intent", operation_key: key}),
           completed_usenet(%{id: "nzo-movie"})
         ]}
      end)

      record_removals(SabnzbdClientMock)

      assert :ok = Cleaner.poll()
      refute_received {:removed, _id, _opts}
    end

    test "keeps a completed usenet entry while move_on_import is off" do
      Application.put_env(:cinder, :move_on_import, false)

      stub(SabnzbdClientMock, :list_managed, fn ->
        {:ok, [completed_usenet(%{id: "nzo-kept"})]}
      end)

      record_removals(SabnzbdClientMock)

      assert :ok = Cleaner.poll()
      refute_received {:removed, _id, _opts}
    end

    # An import releases its owner before it finishes linking sidecars, so a just-completed job
    # can look unowned while its import is still running.
    test "keeps a just-completed usenet entry and one reporting no completion time" do
      stub(SabnzbdClientMock, :list_managed, fn ->
        {:ok,
         [
           completed_usenet(%{id: "nzo-fresh", completed_at: System.os_time(:second) - 60}),
           Map.delete(completed_usenet(%{id: "nzo-untimed"}), :completed_at)
         ]}
      end)

      record_removals(SabnzbdClientMock)

      assert :ok = Cleaner.poll()
      refute_received {:removed, _id, _opts}
    end

    test "still leaves a completed torrent below its limits alone" do
      configure_limits(ratio_limit: "2", seed_time_limit_hours: "48")

      # Replaces setup's empty torrent listing with the one under test.
      stub(ClientMock, :list_managed, fn ->
        {:ok, [entry(%{id: "young", state: :completed, ratio: 1.0, seeding_time: 3600})]}
      end)

      record_removals(ClientMock)

      assert :ok = Cleaner.poll()
      refute_received {:removed, _id, _opts}
    end
  end

  test "removes an unclaimed completed torrent after the opt-in ratio is reached" do
    configure_limits(ratio_limit: "1.5")

    expect(ClientMock, :list_managed, fn ->
      {:ok, [entry(%{id: "seeded", state: :completed, ratio: 1.5, seeding_time: 60})]}
    end)

    expect(ClientMock, :remove, fn "seeded", opts ->
      assert Keyword.fetch!(opts, :delete_files)
      :ok
    end)

    assert :ok = Cleaner.poll()
  end

  test "removes an unclaimed completed torrent after the opt-in seed time is reached" do
    configure_limits(seed_time_limit_hours: "2")

    expect(ClientMock, :list_managed, fn ->
      {:ok, [entry(%{id: "old-seed", state: :completed, ratio: 0.5, seeding_time: 7200})]}
    end)

    expect(ClientMock, :remove, fn "old-seed", _opts -> :ok end)

    assert :ok = Cleaner.poll()
  end

  test "keeps completed torrents below limits or missing native metrics" do
    configure_limits(ratio_limit: "2", seed_time_limit_hours: "48")

    expect(ClientMock, :list_managed, fn ->
      {:ok,
       [
         entry(%{id: "young", state: :completed, ratio: 1.0, seeding_time: 3600}),
         entry(%{id: "unknown", state: :completed, ratio: nil, seeding_time: nil})
       ]}
    end)

    assert :ok = Cleaner.poll()
  end

  test "keeps a completed torrent that still has an owner even after a limit" do
    configure_limits(ratio_limit: "1")
    key = Ecto.UUID.generate()
    intent_for(key, "owned-seed")

    expect(ClientMock, :list_managed, fn ->
      {:ok, [entry(%{id: "owned-seed", operation_key: key, state: :completed, ratio: 5.0})]}
    end)

    assert :ok = Cleaner.poll()
  end

  test "removes a fully-imported movie's completed torrent after the opt-in ratio is reached" do
    # A movie import success writes status: :available and clears content_path but deliberately
    # keeps download_id/download_protocol (see poller.ex's import commit) — it needs no more
    # source bytes, so it must release ownership for the explicitly enabled cleanup, unlike a
    # movie still mid-download/mid-import/held.
    movie =
      movie_fixture(%{
        status: :available,
        download_id: "seeded",
        download_protocol: :torrent,
        file_path: "/media/Movie.mkv",
        content_path: nil
      })

    assert movie.status == :available
    configure_limits(ratio_limit: "1.5")

    expect(ClientMock, :list_managed, fn ->
      {:ok, [entry(%{id: "seeded", state: :completed, ratio: 1.5, seeding_time: 60})]}
    end)

    expect(ClientMock, :remove, fn "seeded", opts ->
      assert Keyword.fetch!(opts, :delete_files)
      :ok
    end)

    assert :ok = Cleaner.poll()
  end

  test "keeps a completed torrent whose movie is still importing, even after a limit" do
    movie =
      movie_fixture(%{status: :downloaded, download_id: "importing", download_protocol: :torrent})

    assert movie.status == :downloaded
    configure_limits(ratio_limit: "1")

    expect(ClientMock, :list_managed, fn ->
      {:ok, [entry(%{id: "importing", state: :completed, ratio: 5.0})]}
    end)

    assert :ok = Cleaner.poll()
  end

  test "keeps a completed torrent whose movie is held for verification, even after a limit" do
    movie =
      movie_fixture(%{status: :import_failed, download_id: "held", download_protocol: :torrent})

    assert movie.status == :import_failed
    configure_limits(ratio_limit: "1")

    expect(ClientMock, :list_managed, fn ->
      {:ok, [entry(%{id: "held", state: :completed, ratio: 5.0})]}
    end)

    assert :ok = Cleaner.poll()
  end

  test "leaves a download whose intent still exists" do
    key = Ecto.UUID.generate()
    intent_for(key, "live")

    expect(ClientMock, :list_managed, fn -> {:ok, [entry(%{id: "live", operation_key: key})]} end)

    assert :ok = Cleaner.poll()
  end

  test "leaves a download a movie still points at, even with no intent row" do
    movie =
      movie_fixture(%{status: :downloading, download_id: "owned", download_protocol: :torrent})

    assert movie.download_id == "owned"

    expect(ClientMock, :list_managed, fn -> {:ok, [entry(%{id: "owned"})]} end)

    assert :ok = Cleaner.poll()
  end

  test "leaves a download a grab still points at" do
    Repo.insert!(%Grab{download_id: "grabbed", download_protocol: :torrent, release_title: "R"})

    expect(ClientMock, :list_managed, fn -> {:ok, [entry(%{id: "grabbed"})]} end)

    assert :ok = Cleaner.poll()
  end

  test "leaves a download a book grab still points at" do
    # Regression: a book intent is completed at SUBMISSION time, so from the moment the download
    # starts its `book_grabs` row is the ONLY thing claiming it. Before this was taught to the
    # sweep, every in-flight book download looked orphaned and was removed with `delete_files`
    # on the next tick. No `remove` expectation: reaching the client at all fails this test.
    {:ok, work} =
      Books.upsert_work(%{
        title: "The Dispossessed",
        identifier: %{
          provider: "openlibrary",
          kind: "work",
          foreign_id: "OL#{System.unique_integer([:positive])}W"
        }
      })

    {:ok, target} = Books.ensure_target(work, :ebook)
    {:ok, _grab} = Books.Grabs.create(target.id, "book-download", :torrent, "R")

    expect(ClientMock, :list_managed, fn -> {:ok, [entry(%{id: "book-download"})]} end)

    assert :ok = Cleaner.poll()
  end

  test "a download id claimed on one protocol does not shield the same id's orphan on another" do
    # #397: `download_id` is client-local (a qBittorrent infohash, a SABnzbd nzo_id, an NZBGet
    # integer) with no cross-client uniqueness guarantee. A torrent grab owning "cross-protocol"
    # must not make an unrelated usenet entry with the same id read as claimed, and vice versa.
    Repo.insert!(%Grab{
      download_id: "cross-protocol",
      download_protocol: :torrent,
      release_title: "R"
    })

    expect(ClientMock, :list_managed, fn ->
      {:ok, [entry(%{id: "cross-protocol", state: :downloading})]}
    end)

    stub(SabnzbdClientMock, :list_managed, fn ->
      {:ok, [entry(%{id: "cross-protocol", state: :downloading})]}
    end)

    # No `remove` expectation for the torrent client: the grab owns it there.
    expect(SabnzbdClientMock, :remove, fn "cross-protocol", opts ->
      assert Keyword.fetch!(opts, :delete_files)
      :ok
    end)

    assert :ok = Cleaner.poll()
  end

  test "a movie with no recorded protocol (a pre-download_protocol row) is claimed only on torrent" do
    # `movies.download_protocol` is nullable — rows from before the column existed. Every other
    # read site (`Download.client_for/1`) resolves that nil to :torrent, and the sweep's ownership
    # check must match: claim it on the torrent sweep, but NOT blanket-claim it on usenet too
    # (that would just reopen #397 for legacy rows).
    movie = movie_fixture(%{status: :downloading, download_id: "legacy"})
    assert movie.download_protocol == nil

    expect(ClientMock, :list_managed, fn -> {:ok, [entry(%{id: "legacy"})]} end)

    stub(SabnzbdClientMock, :list_managed, fn ->
      {:ok, [entry(%{id: "legacy", state: :downloading})]}
    end)

    expect(SabnzbdClientMock, :remove, fn "legacy", _opts -> :ok end)

    assert :ok = Cleaner.poll()
  end

  test "sweeps usenet through its own client" do
    expect(ClientMock, :list_managed, fn -> {:ok, []} end)

    stub(SabnzbdClientMock, :list_managed, fn ->
      {:ok, [entry(%{id: "nzo-orphan", state: :error})]}
    end)

    expect(SabnzbdClientMock, :remove, fn "nzo-orphan", _opts -> :ok end)

    assert :ok = Cleaner.poll()
  end

  test "a listing failure is logged, not raised, and the other protocol still sweeps" do
    expect(ClientMock, :list_managed, fn -> {:error, :econnrefused} end)

    stub(SabnzbdClientMock, :list_managed, fn ->
      {:ok, [entry(%{id: "nzo", state: :downloading})]}
    end)

    expect(SabnzbdClientMock, :remove, fn "nzo", _opts -> :ok end)

    assert :ok = Cleaner.poll()
  end

  test "does nothing at all when disabled" do
    original = Application.get_env(:cinder, Cleaner, [])
    Application.put_env(:cinder, Cleaner, enabled: false)
    on_exit(fn -> Application.put_env(:cinder, Cleaner, original) end)

    # No list_managed expectation on either client: a disabled sweep must not even ask.
    assert :ok = Cleaner.poll()
  end
end
