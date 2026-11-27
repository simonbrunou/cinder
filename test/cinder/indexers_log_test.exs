defmodule Cinder.IndexersLogTest do
  # Not async: the test lowers the global Logger level to :debug so the capture holds Ecto's query
  # lines, and an async module running meanwhile would log its own debug lines into its captures.
  # `Logger.put_process_level/2` alone does not reach the capture (run on 2026-11-25).
  use Cinder.DataCase, async: false

  import ExUnit.CaptureLog

  alias Cinder.DefinitionFixtures
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

  # A Switch (#1907) seals a new ciphertext from the secrets it builds and writes it in the
  # edit's update.
  test "the log of a Switch holds no secret and no ciphertext" do
    base = DefinitionFixtures.definition()
    DefinitionFixtures.mirror!(base)
    row = DefinitionFixtures.cardigann!(base, %{"password" => "stored-pw-xyz"})
    newer = DefinitionFixtures.definition("newer", %{"replaces" => ["tracker"]})
    {:ok, {:loaded, _}} = DefinitionFixtures.apply_files([{"v11", "newer.yml", newer}])

    attrs = %{
      definition: "newer.yml",
      definition_blob_sha: DefinitionFixtures.blob_sha(newer),
      base_url: row.base_url
    }

    typed = %{"username" => "typed-user-xyz"}
    {:ok, hosts} = Indexers.switch_hosts(row.id, row.lock_version, attrs, typed)
    attrs = Map.put(attrs, :switch_hosts_digest, Indexers.hosts_digest(hosts))

    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)

    {switched, log} =
      with_log([level: :debug], fn ->
        {:ok, switched} = Indexers.update(nil, row.id, row.lock_version, attrs, typed)
        switched
      end)

    # The controls: the capture holds the Switch's reads of the row, and it wrote a ciphertext.
    assert log =~ ~s(FROM "configured_indexers")
    assert is_binary(switched.secrets_ciphertext)
    assert switched.secrets_ciphertext != row.secrets_ciphertext

    refute log =~ ~s(UPDATE "configured_indexers")

    for text <- ["stored-pw-xyz", "typed-user-xyz", switched.secrets_ciphertext] do
      refute log =~ text
    end
  end
end
