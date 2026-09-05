defmodule Cinder.Books.BibliographyRefresherTest do
  # The sweep runs in its own process, so the mocks must be global; shared Sandbox (async: false)
  # lets that process use the test-owned DB connection — mirrors `Cinder.Books.RefresherTest`.
  use Cinder.DataCase, async: false

  import ExUnit.CaptureLog
  import Mox

  alias Cinder.Books
  alias Cinder.Books.{BibliographyRefresher, BookTarget, PrimaryMetadataMock}
  alias Cinder.Catalog

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    on_exit(fn -> :persistent_term.erase({BibliographyRefresher, :last_run}) end)
    # The suite's global Logger level is :warning (config/test.exs); `capture_log`'s own
    # `:level` option only filters the capturing handler, not the primary level a message must
    # clear to reach any handler at all — so the module needs its own override to make its
    # :info lines observable here, restored unconditionally after each test.
    Logger.put_module_level(BibliographyRefresher, :info)
    on_exit(fn -> Logger.delete_module_level(BibliographyRefresher) end)
    # Long interval: every test drives the sweep synchronously via poll/0, never the timer.
    start_supervised!({BibliographyRefresher, interval: 60_000})
    :ok
  end

  setup do
    stub(PrimaryMetadataMock, :provider, fn -> :openlibrary end)
    {:ok, profile} = Catalog.create_profile(%{name: "Ebooks", kind: :ebook, handling: :standard})
    %{profile: profile}
  end

  test "an author with no policy row is never visited" do
    _author = author_fixture("A1")

    # No `bibliography`/`get_work` stub is registered at all — a visit would raise
    # `Mox.UnexpectedCallError` rather than silently succeeding.
    poll()

    assert Repo.aggregate(BookTarget, :count) == 0
  end

  test "an ambiguous bibliography entry is never monitored by the sweep", %{profile: profile} do
    author = author_fixture("A1")
    {:ok, _policy} = Books.set_author_policy(author, :all, profile)

    expect(PrimaryMetadataMock, :bibliography, fn "A1" -> {:ok, [candidate("OLBADW")]} end)
    expect(PrimaryMetadataMock, :get_work, fn "OLBADW" -> {:error, :timeout} end)

    log = capture_log(fn -> poll() end)

    assert Repo.aggregate(BookTarget, :count) == 0
    refute log =~ "monitored"
  end

  test "a provider outage during a tick leaves every existing target byte-identical", %{
    profile: profile
  } do
    author = author_fixture("A1")
    {:ok, _policy} = Books.set_author_policy(author, :all, profile)

    existing_work = imported_work("OLEXIST")
    {:ok, existing_target} = Books.monitor_target(existing_work, :ebook, profile)
    before = snapshot()

    expect(PrimaryMetadataMock, :bibliography, fn "A1" -> {:error, :timeout} end)

    capture_log(fn -> poll() end)

    assert snapshot() == before
    assert Repo.get!(BookTarget, existing_target.id).status == :monitored
  end

  test "one author's failure — a tagged error or a genuine exception — does not stop the pass
        for the next author",
       %{profile: profile} do
    failing_author = author_fixture("AFAIL")
    {:ok, _policy1} = Books.set_author_policy(failing_author, :all, profile)

    raising_author = author_fixture("ARAISE")
    {:ok, _policy2} = Books.set_author_policy(raising_author, :all, profile)

    succeeding_author = author_fixture("AOK")
    {:ok, _policy3} = Books.set_author_policy(succeeding_author, :all, profile)

    expect(PrimaryMetadataMock, :bibliography, fn "AFAIL" -> {:error, :timeout} end)
    expect(PrimaryMetadataMock, :bibliography, fn "ARAISE" -> raise "boom" end)

    expect(PrimaryMetadataMock, :bibliography, fn "AOK" ->
      {:ok, [candidate("OLGOODW")]}
    end)

    expect(PrimaryMetadataMock, :get_work, fn "OLGOODW" -> {:ok, provider_work("OLGOODW")} end)

    log = capture_log(fn -> poll() end)

    assert log =~ "monitored 1 new work"

    assert [%BookTarget{status: :monitored}] =
             Repo.all(
               from t in BookTarget, join: w in assoc(t, :work), where: w.title == "Work OLGOODW"
             )
  end

  # #512: a bibliography refresh loads a policy/profile, does provider I/O that can take real
  # wall time, then used to unconditionally re-apply that STALE policy/profile — reinstating a
  # row the admin had since deleted or changed. This exercises the actual concurrent interleaving
  # (a real Task blocked on the provider mock, not just a unit call), not merely a function-level
  # assertion.
  test "an admin reverting to Selected works mid-tick is not undone by the stale batch", %{
    profile: profile
  } do
    author = author_fixture("A1")
    {:ok, _policy} = Books.set_author_policy(author, :all, profile)

    test_pid = self()

    expect(PrimaryMetadataMock, :bibliography, fn "A1" ->
      send(test_pid, {:bibliography_called, self()})

      receive do
        :release -> :ok
      end

      {:ok, [candidate("OLNEW1W")]}
    end)

    expect(PrimaryMetadataMock, :get_work, fn "OLNEW1W" -> {:ok, provider_work("OLNEW1W")} end)

    task = Task.async(&poll/0)
    assert_receive {:bibliography_called, provider_pid}

    # The admin reverts to Selected works while this tick's bibliography fetch is still pending.
    {:ok, nil} = Books.set_author_policy(author, :specific, nil)

    send(provider_pid, :release)
    Task.await(task)

    assert Repo.aggregate(BookTarget, :count) == 0
    assert Books.author_policy(author.id) == :specific
  end

  test "an admin switching :all to :future mid-tick is not overwritten by the stale :all batch",
       %{profile: profile} do
    author = author_fixture("A1")
    {:ok, _policy} = Books.set_author_policy(author, :all, profile)

    test_pid = self()

    expect(PrimaryMetadataMock, :bibliography, fn "A1" ->
      send(test_pid, {:bibliography_called, self()})

      receive do
        :release -> :ok
      end

      {:ok, [candidate("OLNEW2W")]}
    end)

    expect(PrimaryMetadataMock, :get_work, fn "OLNEW2W" -> {:ok, provider_work("OLNEW2W")} end)

    task = Task.async(&poll/0)
    assert_receive {:bibliography_called, provider_pid}

    {:ok, _policy} = Books.set_author_policy(author, :future, profile)

    send(provider_pid, :release)
    Task.await(task)

    assert Repo.aggregate(BookTarget, :count) == 0
    assert Books.author_policy(author.id) == :future
  end

  test "quiet logging: a tick that creates zero targets logs nothing at :info", %{
    profile: profile
  } do
    author = author_fixture("A1")
    {:ok, _policy} = Books.set_author_policy(author, :all, profile)

    monitored_work = imported_work("OLMON")
    {:ok, _target} = Books.monitor_target(monitored_work, :ebook, profile)

    expect(PrimaryMetadataMock, :bibliography, fn "A1" -> {:ok, [candidate("OLMON")]} end)

    log = capture_log(fn -> poll() end)

    refute log =~ "monitored"
  end

  defp poll, do: assert(:ok = BibliographyRefresher.poll())

  defp snapshot do
    Repo.all(from t in BookTarget, order_by: t.id, select: {t.id, t.status, t.profile_id})
  end

  defp author_fixture(foreign_id) do
    {:ok, author} =
      Books.upsert_author(%{
        name: "Author #{foreign_id}",
        identifier: %{provider: "openlibrary", kind: "author", foreign_id: foreign_id}
      })

    author
  end

  defp imported_work(foreign_id) do
    {:ok, work} =
      Books.import_resolution(%{provider: :openlibrary, work: provider_work(foreign_id)})

    work
  end

  defp candidate(foreign_id) do
    %{
      provider: :openlibrary,
      foreign_id: foreign_id,
      title: "Work #{foreign_id}",
      contributors: [%{foreign_id: "A1", name: "Prolific Author", role: "author"}],
      contributors_incomplete: false,
      first_published_year: nil,
      edition_count: 1
    }
  end

  defp provider_work(foreign_id) do
    %{
      provider: :openlibrary,
      foreign_id: foreign_id,
      title: "Work #{foreign_id}",
      first_published_on: ~D[2000-01-01],
      overview: nil,
      contributors: [%{foreign_id: "A1", name: "Prolific Author", role: "author"}],
      contributors_incomplete: false,
      editions: [
        %{
          foreign_id: foreign_id <> "-ED",
          media_kind: :ebook,
          title: "Work #{foreign_id}",
          language: "eng",
          format: nil,
          publisher: nil,
          release_date: nil,
          abridged: nil,
          isbn13: nil,
          asin: nil
        }
      ],
      series: []
    }
  end
end
