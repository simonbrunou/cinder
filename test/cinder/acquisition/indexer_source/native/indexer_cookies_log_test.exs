defmodule Cinder.Acquisition.IndexerSource.Native.IndexerCookiesLogTest do
  # Not async: the test lowers the global Logger level to :debug so the capture holds Ecto's query
  # lines, as `Cinder.IndexersLogTest` does, and an async module running meanwhile would log its
  # own debug lines into its captures.
  use Cinder.DataCase, async: false

  import ExUnit.CaptureLog

  alias Cinder.Acquisition.Indexer.Cardigann.Jar
  alias Cinder.Acquisition.IndexerSource.Native.IndexerCookies
  alias Cinder.Indexers
  alias Cinder.Repo

  @now ~U[2026-11-27 12:00:00.000000Z]

  defp jar(value), do: Jar.put_string(Jar.new(), URI.parse("https://site.test/"), "sid=#{value}")

  test "the log of a login's store and of a later update holds no cookie and no ciphertext" do
    {:ok, indexer} =
      Indexers.create(
        nil,
        %{name: "Cookies", type: :newznab, base_url: "https://i.example", api_path: "/api"},
        %{"api_key" => "nzb-key-0123456789"}
      )

    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)

    {ciphertexts, log} =
      with_log([level: :debug], fn ->
        :written = IndexerCookies.store_login(indexer, jar("plain-cookie-77"), @now)
        stored = Repo.get(IndexerCookies, indexer.id).ciphertext
        :written = IndexerCookies.update(indexer, @now, jar("plain-cookie-88"))
        [stored, Repo.get(IndexerCookies, indexer.id).ciphertext]
      end)

    # The controls: the capture holds the table's statements, and each write made a ciphertext.
    assert log =~ ~s("native_indexer_cookies")
    assert [first, second] = ciphertexts
    assert is_binary(first) and is_binary(second) and first != second

    for text <- ["plain-cookie-77", "plain-cookie-88" | ciphertexts] do
      refute String.contains?(log, text)
    end
  end
end
