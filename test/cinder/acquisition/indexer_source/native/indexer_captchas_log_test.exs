defmodule Cinder.Acquisition.IndexerSource.Native.IndexerCaptchasLogTest do
  # Not async: the test lowers the global Logger level to :debug so the capture holds Ecto's query
  # lines, as `Cinder.IndexersLogTest` does, and an async module running meanwhile would log its
  # own debug lines into its captures.
  use Cinder.DataCase, async: false

  import ExUnit.CaptureLog

  alias Cinder.Acquisition.Indexer.Cardigann.Jar
  alias Cinder.Acquisition.IndexerSource.Native.IndexerCaptchas
  alias Cinder.Indexers
  alias Cinder.Repo

  @now ~U[2026-11-27 12:00:00.000000Z]
  @binding %{address: "https://site.test/", blob_sha: "sha-1"}

  defp session(value) do
    %{
      binding: @binding,
      jar: Jar.put_string(Jar.new(), URI.parse("https://site.test/"), "sid=#{value}"),
      landing: "https://site.test/login.php",
      form: %{"action" => "/takelogin.php"}
    }
  end

  test "the log of two captcha loads and a take holds no cookie and no ciphertext" do
    {:ok, indexer} =
      Indexers.create(
        nil,
        %{name: "Captchas", type: :newznab, base_url: "https://i.example", api_path: "/api"},
        %{"api_key" => "nzb-key-0123456789"}
      )

    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)

    {ciphertexts, log} =
      with_log([level: :debug], fn ->
        {:ok, _old} = IndexerCaptchas.store(indexer.id, session("plain-cookie-77"), @now)
        stored = Repo.get(IndexerCaptchas, indexer.id).ciphertext
        {:ok, token} = IndexerCaptchas.store(indexer.id, session("plain-cookie-88"), @now)
        replaced = Repo.get(IndexerCaptchas, indexer.id).ciphertext
        {:ok, _session} = IndexerCaptchas.take(indexer.id, token, @binding, @now)
        [stored, replaced]
      end)

    # The controls: the capture holds the table's statements, and each write made a ciphertext.
    assert log =~ ~s("native_indexer_captchas")
    assert [first, second] = ciphertexts
    assert is_binary(first) and is_binary(second) and first != second

    for text <- ["plain-cookie-77", "plain-cookie-88" | ciphertexts] do
      refute String.contains?(log, text)
    end
  end
end
