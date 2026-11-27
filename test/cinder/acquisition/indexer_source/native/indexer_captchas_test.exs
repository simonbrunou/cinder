defmodule Cinder.Acquisition.IndexerSource.Native.IndexerCaptchasTest do
  # The captcha session table (#1681): the row's life beside its configured indexer, its
  # 5-minute expiry, the one-use take, the load token and the binding, and the scoped ciphertext.
  # Every expected time is a literal.
  use Cinder.DataCase, async: true

  import Ecto.Query

  alias Cinder.Acquisition.Indexer.Cardigann.Jar
  alias Cinder.Acquisition.IndexerSource.Native.{IndexerCaptchas, IndexerCookies}
  alias Cinder.Indexers
  alias Cinder.Repo
  alias Cinder.SecretCodec

  @now ~U[2026-11-27 12:00:00.000000Z]
  @binding %{address: "https://site.test/", blob_sha: "sha-1"}

  defp indexer! do
    attrs = %{
      name: "Captcha #{System.unique_integer([:positive])}",
      type: :newznab,
      base_url: "https://indexer.example",
      api_path: "/api"
    }

    {:ok, row} = Indexers.create(nil, attrs, %{"api_key" => "nzb-key-0123456789"})
    row
  end

  defp session(cookie \\ "landing-cookie-1") do
    %{
      binding: @binding,
      jar: Jar.put_string(Jar.new(), URI.parse("https://site.test/"), "sid=#{cookie}"),
      landing: "https://site.test/login.php",
      form: %{"action" => "/takelogin.php", "kept" => [["tok", "t0k3n"]]}
    }
  end

  defp row(id), do: Repo.get(IndexerCaptchas, id)

  defp at(seconds), do: DateTime.add(@now, seconds, :second)

  test "a session lives 5 minutes after its load" do
    indexer = indexer!()
    assert {:ok, token} = IndexerCaptchas.store(indexer.id, session(), @now)

    assert IndexerCaptchas.lifetime_seconds() == 300
    assert row(indexer.id).expires_at == ~U[2026-11-27 12:05:00.000000Z]

    assert IndexerCaptchas.live?(indexer.id, token, @binding, ~U[2026-11-27 12:04:59.999999Z])
    refute IndexerCaptchas.live?(indexer.id, token, @binding, ~U[2026-11-27 12:05:00.000000Z])

    assert IndexerCaptchas.take(indexer.id, token, @binding, ~U[2026-11-27 12:05:00.000000Z]) ==
             :miss

    # An expired row is gone once a take found it.
    assert row(indexer.id) == nil
  end

  test "take answers the stored session once, and deletes it" do
    indexer = indexer!()
    {:ok, token} = IndexerCaptchas.store(indexer.id, session(), @now)

    assert {:ok, taken} = IndexerCaptchas.take(indexer.id, token, @binding, at(60))
    assert Jar.to_list(taken.jar) == [["https", "site.test", 443, "sid", "landing-cookie-1"]]
    assert taken.landing == "https://site.test/login.php"
    assert taken.form == %{"action" => "/takelogin.php", "kept" => [["tok", "t0k3n"]]}

    assert row(indexer.id) == nil
    assert IndexerCaptchas.take(indexer.id, token, @binding, at(61)) == :miss
  end

  test "a new load replaces the row, and the older load's token reads as a miss it leaves" do
    indexer = indexer!()
    {:ok, old} = IndexerCaptchas.store(indexer.id, session("one"), @now)
    {:ok, new} = IndexerCaptchas.store(indexer.id, session("two"), at(10))

    assert old != new
    refute IndexerCaptchas.live?(indexer.id, old, @binding, at(20))
    assert IndexerCaptchas.take(indexer.id, old, @binding, at(20)) == :miss

    # The newer load's session stays for its own answer, and lives from its own load.
    assert row(indexer.id).expires_at == ~U[2026-11-27 12:05:10.000000Z]
    assert {:ok, taken} = IndexerCaptchas.take(indexer.id, new, @binding, at(20))
    assert [["https", "site.test", 443, "sid", "two"]] = Jar.to_list(taken.jar)
  end

  test "a session loaded under another base URL or copy is a miss, and is deleted" do
    for binding <- [
          %{@binding | address: "https://mirror.test/"},
          %{@binding | blob_sha: "sha-2"}
        ] do
      indexer = indexer!()
      {:ok, token} = IndexerCaptchas.store(indexer.id, session(), @now)

      refute IndexerCaptchas.live?(indexer.id, token, binding, at(1))
      assert IndexerCaptchas.take(indexer.id, token, binding, at(1)) == :miss
      assert row(indexer.id) == nil
    end
  end

  test "a row that does not decrypt, or that names another indexer, is a miss" do
    one = indexer!()
    two = indexer!()
    {:ok, token} = IndexerCaptchas.store(one.id, session(), @now)
    {:ok, _token} = IndexerCaptchas.store(two.id, session(), @now)

    # A copy of one's row under two's id.
    Repo.update_all(
      from(c in IndexerCaptchas, where: c.configured_indexer_id == ^two.id),
      set: [ciphertext: row(one.id).ciphertext]
    )

    refute IndexerCaptchas.live?(two.id, token, @binding, at(1))
    assert IndexerCaptchas.take(two.id, token, @binding, at(1)) == :miss

    Repo.update_all(
      from(c in IndexerCaptchas, where: c.configured_indexer_id == ^one.id),
      set: [ciphertext: "not-a-ciphertext"]
    )

    refute IndexerCaptchas.live?(one.id, token, @binding, at(1))
    assert IndexerCaptchas.take(one.id, token, @binding, at(1)) == :miss
  end

  test "a cookie row's ciphertext does not read as a captcha session" do
    indexer = indexer!()
    {:ok, token} = IndexerCaptchas.store(indexer.id, session(), @now)
    jar = Jar.put_string(Jar.new(), URI.parse("https://site.test/"), "sid=x")
    :written = IndexerCookies.store_login(indexer, jar, @now)

    Repo.update_all(
      from(c in IndexerCaptchas, where: c.configured_indexer_id == ^indexer.id),
      set: [ciphertext: Repo.get(IndexerCookies, indexer.id).ciphertext]
    )

    assert IndexerCaptchas.take(indexer.id, token, @binding, at(1)) == :miss
  end

  test "the stored ciphertext holds no cookie value, and names its scope and indexer" do
    indexer = indexer!()
    {:ok, _token} = IndexerCaptchas.store(indexer.id, session("cookie-value-1234"), @now)

    ciphertext = row(indexer.id).ciphertext
    refute ciphertext =~ "cookie-value-1234"
    refute inspect(row(indexer.id)) =~ ciphertext

    {:ok, json} = SecretCodec.decode(ciphertext)

    assert %{"scope" => "indexer_cookies", "kind" => "captcha", "id" => id} = Jason.decode!(json)
    assert id == indexer.id
  end

  test "deleting the configured indexer deletes its session, and delete/1 drops it" do
    indexer = indexer!()
    {:ok, _token} = IndexerCaptchas.store(indexer.id, session(), @now)
    assert :ok = Indexers.delete(nil, indexer.id)
    assert row(indexer.id) == nil

    other = indexer!()
    {:ok, _token} = IndexerCaptchas.store(other.id, session(), @now)
    assert IndexerCaptchas.delete(other.id) == :ok
    assert row(other.id) == nil
  end

  test "a store for an indexer that is gone writes nothing" do
    indexer = indexer!()
    :ok = Indexers.delete(nil, indexer.id)
    assert IndexerCaptchas.store(indexer.id, session(), @now) == :refused
    assert row(indexer.id) == nil
  end
end
