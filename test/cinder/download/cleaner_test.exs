defmodule Cinder.Download.CleanerTest do
  # async: false — the sweep runs in its own process against the test-owned (shared Sandbox)
  # connection, and status/0 stamps process-global :persistent_term.
  use Cinder.DataCase, async: false

  import Mox

  @moduletag :capture_log

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
    Application.put_env(:cinder, Cleaner, enabled: false)
    on_exit(fn -> Application.put_env(:cinder, Cleaner, enabled: true) end)

    # No list_managed expectation on either client: a disabled sweep must not even ask.
    assert :ok = Cleaner.poll()
  end
end
