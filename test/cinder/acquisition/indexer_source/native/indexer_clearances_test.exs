defmodule Cinder.Acquisition.IndexerSource.Native.IndexerClearancesTest do
  # The clearance table (#1682): the row's life beside its configured indexer, its 30-day
  # expiry, its `config_version` guard and the scoped ciphertext. Every expected time is a
  # literal.
  use Cinder.DataCase, async: true

  import Ecto.Query

  alias Cinder.Acquisition.Indexer.Cardigann.Jar
  alias Cinder.Acquisition.IndexerSource.Native.{IndexerClearances, IndexerCookies}
  alias Cinder.Indexers
  alias Cinder.Indexers.ConfiguredIndexer
  alias Cinder.Repo
  alias Cinder.SecretCodec

  @now ~U[2026-11-27 12:00:00.000000Z]
  @clearance %{
    user_agent: "Mozilla/5.0 FlareSolverrTest",
    cookies: [{"site.test", "cf_clearance", "clear-1"}, {"site.test", "__cf_bm", "bm"}]
  }

  defp indexer! do
    attrs = %{
      name: "Clearance #{System.unique_integer([:positive])}",
      type: :newznab,
      base_url: "https://indexer.example",
      api_path: "/api"
    }

    {:ok, row} = Indexers.create(nil, attrs, %{"api_key" => "nzb-key-0123456789"})
    row
  end

  defp row(id), do: Repo.get(IndexerClearances, id)

  defp bump!(indexer) do
    Repo.update_all(from(c in ConfiguredIndexer, where: c.id == ^indexer.id),
      inc: [config_version: 1]
    )

    Repo.get!(ConfiguredIndexer, indexer.id)
  end

  test "a clearance reads back until 30 days after its solve" do
    indexer = indexer!()
    assert IndexerClearances.read(indexer, @now) == nil
    assert IndexerClearances.store(indexer, @clearance, @now) == :written

    assert IndexerClearances.lifetime_days() == 30
    assert row(indexer.id).expires_at == ~U[2026-12-27 12:00:00.000000Z]
    assert IndexerClearances.read(indexer, ~U[2026-12-27 11:59:59.999999Z]) == @clearance
    assert IndexerClearances.read(indexer, ~U[2026-12-27 12:00:00.000000Z]) == nil
  end

  test "a new solve replaces the row" do
    indexer = indexer!()
    :written = IndexerClearances.store(indexer, @clearance, @now)
    newer = %{user_agent: "agent 2", cookies: [{"site.test", "cf_clearance", "clear-2"}]}
    assert IndexerClearances.store(indexer, newer, DateTime.add(@now, 60)) == :written
    assert IndexerClearances.read(indexer, DateTime.add(@now, 120)) == newer
  end

  test "an edit that raises config_version retires the clearance and refuses an older solve" do
    indexer = indexer!()
    :written = IndexerClearances.store(indexer, @clearance, @now)
    edited = bump!(indexer)

    # The solve that started before the edit is refused, and the row under the older version
    # reads nil for the edited indexer and is deleted.
    assert IndexerClearances.store(indexer, @clearance, @now) == :refused
    assert IndexerClearances.read(edited, @now) == nil
    assert row(indexer.id) == nil

    assert IndexerClearances.store(edited, @clearance, @now) == :written
    assert IndexerClearances.read(edited, @now) == @clearance
    # A struct read before the edit reads nothing from the newer row, and leaves it.
    assert IndexerClearances.read(indexer, @now) == nil
    refute row(indexer.id) == nil
  end

  test "a deleted indexer takes its row, and a store for it is refused" do
    indexer = indexer!()
    :written = IndexerClearances.store(indexer, @clearance, @now)
    :ok = Indexers.delete(nil, indexer.id)
    assert row(indexer.id) == nil
    assert IndexerClearances.store(indexer, @clearance, @now) == :refused
  end

  test "a ciphertext of another indexer, of a login row or that does not decrypt reads nil" do
    one = indexer!()
    other = indexer!()
    :written = IndexerClearances.store(one, @clearance, @now)
    :written = IndexerClearances.store(other, @clearance, @now)
    copied = row(one.id).ciphertext

    Repo.update_all(from(c in IndexerClearances, where: c.configured_indexer_id == ^other.id),
      set: [ciphertext: copied]
    )

    assert IndexerClearances.read(other, @now) == nil

    jar = Jar.put_string(Jar.new(), URI.parse("https://site.test/"), "sid=1")
    :written = IndexerCookies.store_login(one, jar, @now)
    cookie_row = Repo.get(IndexerCookies, one.id).ciphertext

    for ciphertext <- [cookie_row, "not a ciphertext", SecretCodec.encode("{}")] do
      Repo.update_all(from(c in IndexerClearances, where: c.configured_indexer_id == ^one.id),
        set: [ciphertext: ciphertext]
      )

      assert IndexerClearances.read(one, @now) == nil
    end
  end

  # The write's log is `IndexerClearancesLogTest`'s, which lowers the global Logger level.
  test "the row holds the clearance only as ciphertext" do
    indexer = indexer!()
    :written = IndexerClearances.store(indexer, @clearance, @now)

    refute row(indexer.id).ciphertext =~ "clear-1"
    refute inspect(row(indexer.id)) =~ row(indexer.id).ciphertext
  end
end
