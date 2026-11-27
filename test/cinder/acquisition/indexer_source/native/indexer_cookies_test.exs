defmodule Cinder.Acquisition.IndexerSource.Native.IndexerCookiesTest do
  # The cookie table (#1680): the row's life beside its configured indexer, its 30-day expiry,
  # the `credentials_version` rules and the scoped ciphertext. Every expected time is a literal.
  use Cinder.DataCase, async: true

  import Ecto.Query

  alias Cinder.Acquisition.Indexer.Cardigann.Jar
  alias Cinder.Acquisition.IndexerSource.Native.IndexerCookies
  alias Cinder.Indexers
  alias Cinder.Repo

  @now ~U[2026-11-27 12:00:00.000000Z]

  defp indexer!(name \\ "Cookies #{System.unique_integer([:positive])}") do
    attrs = %{
      name: name,
      type: :newznab,
      base_url: "https://indexer.example",
      api_path: "/api"
    }

    {:ok, row} = Indexers.create(nil, attrs, %{"api_key" => "nzb-key-0123456789"})
    row
  end

  defp jar(value \\ "abc"),
    do: Jar.put_string(Jar.new(), URI.parse("https://site.test/"), "sid=#{value}")

  defp row(id), do: Repo.get(IndexerCookies, id)

  test "a login's jar reads back until 30 days after the login" do
    indexer = indexer!()
    assert IndexerCookies.store_login(indexer, jar(), @now) == :written

    assert row(indexer.id).expires_at == ~U[2026-12-27 12:00:00.000000Z]
    assert row(indexer.id).logged_in_at == @now
    assert IndexerCookies.lifetime_days() == 30

    assert {:ok, %{jar: read, logged_in_at: @now}} =
             IndexerCookies.read(indexer, ~U[2026-12-27 11:59:59.999999Z])

    assert Jar.to_list(read) == [["https", "site.test", 443, "sid", "abc"]]
    assert IndexerCookies.read(indexer, ~U[2026-12-27 12:00:00.000000Z]) == :miss
  end

  test "the stored ciphertext holds no cookie value" do
    indexer = indexer!()
    :written = IndexerCookies.store_login(indexer, jar("cookie-value-1234"), @now)
    refute row(indexer.id).ciphertext =~ "cookie-value-1234"
    refute inspect(row(indexer.id)) =~ row(indexer.id).ciphertext
    refute inspect(jar("cookie-value-1234")) =~ "cookie-value-1234"
  end

  test "a row of an older credentials_version is a miss and is deleted" do
    indexer = indexer!()
    :written = IndexerCookies.store_login(indexer, jar(), @now)

    {:ok, edited} =
      Indexers.update(nil, indexer.id, indexer.lock_version, %{}, %{
        "api_key" => "new-key-0123456789"
      })

    assert edited.credentials_version > indexer.credentials_version
    assert IndexerCookies.read(edited, @now) == :miss
    assert row(indexer.id) == nil
  end

  test "a row read for an indexer struct older than the row stays" do
    indexer = indexer!()
    :written = IndexerCookies.store_login(indexer, jar(), @now)
    older = %{indexer | credentials_version: indexer.credentials_version - 1}
    assert IndexerCookies.read(older, @now) == :miss
    assert row(indexer.id) != nil
  end

  test "a login that started under an older credentials_version is refused" do
    indexer = indexer!()

    {:ok, _edited} =
      Indexers.update(nil, indexer.id, indexer.lock_version, %{}, %{
        "api_key" => "new-key-0123456789"
      })

    assert IndexerCookies.store_login(indexer, jar(), @now) == :refused
    assert row(indexer.id) == nil
  end

  test "a row copied to another indexer's id reads as unreadable" do
    first = indexer!()
    second = indexer!()
    :written = IndexerCookies.store_login(first, jar(), @now)
    :written = IndexerCookies.store_login(second, jar("other"), @now)

    Repo.update_all(from(c in IndexerCookies, where: c.configured_indexer_id == ^second.id),
      set: [ciphertext: row(first.id).ciphertext]
    )

    assert {:ok, _session} = IndexerCookies.read(first, @now)
    assert IndexerCookies.read(second, @now) == :miss
  end

  test "a row that does not decrypt is a miss" do
    indexer = indexer!()
    :written = IndexerCookies.store_login(indexer, jar(), @now)

    Repo.update_all(from(c in IndexerCookies, where: c.configured_indexer_id == ^indexer.id),
      set: [ciphertext: Base.encode64("not a vault ciphertext")]
    )

    assert IndexerCookies.read(indexer, @now) == :miss
  end

  test "an update keeps the login's times and is refused once another login replaced the row" do
    indexer = indexer!()
    :written = IndexerCookies.store_login(indexer, jar(), @now)
    assert IndexerCookies.update(indexer, @now, jar("updated")) == :written

    assert {:ok, %{jar: read}} = IndexerCookies.read(indexer, @now)
    assert Jar.to_list(read) == [["https", "site.test", 443, "sid", "updated"]]
    assert row(indexer.id).expires_at == ~U[2026-12-27 12:00:00.000000Z]

    later = DateTime.add(@now, 60, :second)
    :written = IndexerCookies.store_login(indexer, jar("relogin"), later)
    assert IndexerCookies.update(indexer, @now, jar("stale")) == :refused
    assert {:ok, %{jar: read}} = IndexerCookies.read(indexer, @now)
    assert Jar.to_list(read) == [["https", "site.test", 443, "sid", "relogin"]]
  end

  test "deleting the configured indexer deletes its row" do
    indexer = indexer!()
    :written = IndexerCookies.store_login(indexer, jar(), @now)
    assert :ok = Indexers.delete(nil, indexer.id)
    assert row(indexer.id) == nil
  end
end
