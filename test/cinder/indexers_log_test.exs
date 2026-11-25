defmodule Cinder.IndexersLogTest do
  # Not async: the test lowers the global Logger level to :debug so the capture holds Ecto's query
  # lines, and an async module running meanwhile would log its own debug lines into its captures.
  # `Logger.put_process_level/2` alone does not reach the capture (run on 2026-11-25).
  use Cinder.DataCase, async: false

  import ExUnit.CaptureLog

  alias Cinder.Indexers

  @key "nzb-api-key-0123456789"

  test "the log of a create, an edit and a failed edit holds no API key and no ciphertext" do
    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)

    {log, ciphertexts} =
      with_log([level: :debug], fn ->
        {:ok, created} =
          Indexers.create(
            nil,
            %{name: "Geek", type: :newznab, base_url: "https://i.example", api_path: "/api"},
            %{"api_key" => @key}
          )

        {:ok, edited} =
          Indexers.update(nil, created.id, 1, %{name: "Geek 2"}, %{"api_key" => "k2-xyz"})

        {:error, _} =
          Indexers.update(nil, created.id, 2, %{base_url: "ftp://x"}, %{"api_key" => "k3-xyz"})

        [created.secrets_ciphertext, edited.secrets_ciphertext]
      end)
      |> then(fn {ciphertexts, log} -> {log, ciphertexts} end)

    # The controls: the capture holds the create's insert, and both writes made a ciphertext.
    assert log =~ ~s(INSERT INTO "configured_indexers")
    assert Enum.all?(ciphertexts, &is_binary/1)

    for text <- [@key, "k2-xyz", "k3-xyz" | ciphertexts] do
      refute log =~ text
    end
  end
end
