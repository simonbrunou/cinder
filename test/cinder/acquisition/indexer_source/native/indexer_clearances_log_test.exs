defmodule Cinder.Acquisition.IndexerSource.Native.IndexerClearancesLogTest do
  # Not async: the test lowers the global Logger level to :debug so the capture holds Ecto's query
  # lines, as `IndexerCookiesLogTest` does, and an async module running meanwhile would log its
  # own debug lines into its captures.
  use Cinder.DataCase, async: false

  import ExUnit.CaptureLog

  alias Cinder.Acquisition.IndexerSource.Native.IndexerClearances
  alias Cinder.Indexers
  alias Cinder.Repo

  @now ~U[2026-11-27 12:00:00.000000Z]

  defp clearance(value),
    do: %{user_agent: "UA/1", cookies: [{"i.example", "cf_clearance", value}]}

  test "the log of a clearance's store and of its replacement holds no cookie and no ciphertext" do
    {:ok, indexer} =
      Indexers.create(
        nil,
        %{name: "Clearance", type: :newznab, base_url: "https://i.example", api_path: "/api"},
        %{"api_key" => "nzb-key-0123456789"}
      )

    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)

    {ciphertexts, log} =
      with_log([level: :debug], fn ->
        :written = IndexerClearances.store(indexer, clearance("clear-77"), @now)
        stored = Repo.get(IndexerClearances, indexer.id).ciphertext
        :written = IndexerClearances.store(indexer, clearance("clear-88"), @now)
        [stored, Repo.get(IndexerClearances, indexer.id).ciphertext]
      end)

    # The controls: the capture holds the table's statements, and each write made a ciphertext.
    assert log =~ ~s("native_indexer_clearances")
    assert [first, second] = ciphertexts
    assert is_binary(first) and is_binary(second) and first != second

    for text <- ["clear-77", "clear-88" | ciphertexts] do
      refute String.contains?(log, text)
    end
  end
end
