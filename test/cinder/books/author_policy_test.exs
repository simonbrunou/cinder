defmodule Cinder.Books.AuthorPolicyTest do
  @moduledoc """
  `Cinder.Books.set_author_policy/3`, `preview_author_policy/2`, and `apply_author_policy/4` —
  B5b's choke-points. Mox calls happen in this test's own process (no poller involved), so plain
  private mode is enough; `Cinder.Books.BibliographyRefresherTest` covers the unattended sweep.
  """
  use Cinder.DataCase, async: true

  import Mox

  alias Cinder.Books
  alias Cinder.Books.{BookAuthorPolicy, BookTarget, Identifier, PrimaryMetadataMock}
  alias Cinder.Catalog

  setup :verify_on_exit!

  setup do
    stub(PrimaryMetadataMock, :provider, fn -> :openlibrary end)
    :ok
  end

  setup do
    {:ok, profile} =
      Catalog.create_profile(%{name: "Author Policy eBooks", kind: :ebook, handling: :standard})

    %{profile: profile, author: author_fixture()}
  end

  describe "set_author_policy/3" do
    test "future/all upserts a row but creates zero targets", %{author: author, profile: profile} do
      assert {:ok, %BookAuthorPolicy{policy: :future}} =
               Books.set_author_policy(author, :future, profile)

      assert Books.author_policy(author.id) == :future
      assert Repo.aggregate(BookTarget, :count) == 0

      assert {:ok, %BookAuthorPolicy{policy: :all}} =
               Books.set_author_policy(author, :all, profile)

      assert Books.author_policy(author.id) == :all
      assert Repo.aggregate(BookTarget, :count) == 0
      # Upsert, not a second row.
      assert Repo.aggregate(BookAuthorPolicy, :count) == 1
    end

    test "reverting to specific deletes the stored row", %{author: author, profile: profile} do
      {:ok, _policy} = Books.set_author_policy(author, :all, profile)

      assert {:ok, nil} = Books.set_author_policy(author, :specific, nil)
      assert Books.author_policy(author.id) == :specific
      assert Repo.aggregate(BookAuthorPolicy, :count) == 0
    end

    test "no stored row reads back as :specific", %{author: author} do
      assert Books.author_policy(author.id) == :specific
    end

    test "every write broadcasts {:book_author_policy_updated, author_id}, like every other
          write in this module",
         %{author: author, profile: profile} do
      Books.subscribe_targets()

      author_id = author.id
      {:ok, _} = Books.set_author_policy(author, :all, profile)
      assert_receive {:book_author_policy_updated, ^author_id}

      {:ok, _} = Books.set_author_policy(author, :specific, nil)
      assert_receive {:book_author_policy_updated, ^author_id}
    end
  end

  describe "preview_author_policy/2" do
    test "an author with no provider identity refuses rather than guessing", %{author: author} do
      Repo.delete_all(from i in Identifier, where: i.author_id == ^author.id)

      assert {:error, :no_provider_identity} = Books.preview_author_policy(author, :all)
    end

    test "eligible excludes an already-monitored work and an ambiguous one, and confirming
          monitors only the genuinely eligible one",
         %{author: author, profile: profile} do
      monitored_work = imported_work("OLMON1W")
      {:ok, _target} = Books.monitor_target(monitored_work, :ebook, profile)

      expect(PrimaryMetadataMock, :bibliography, fn "A1" ->
        {:ok, [candidate("OLMON1W"), candidate("OLNEW1W"), candidate("OLBAD1W")]}
      end)

      expect(PrimaryMetadataMock, :get_work, fn "OLNEW1W" -> {:ok, provider_work("OLNEW1W")} end)
      expect(PrimaryMetadataMock, :get_work, fn "OLBAD1W" -> {:error, :timeout} end)

      assert {:ok, %{eligible: eligible, ambiguous_count: 1, remaining: 0}} =
               Books.preview_author_policy(author, :all)

      assert [%{work: %{foreign_id: "OLNEW1W"}}] = eligible

      # apply_author_policy/4 operates on exactly this held list — no bibliography/get_work stub
      # is registered beyond what preview already consumed, so a re-fetch here would raise.
      assert {:ok, 1} = Books.apply_author_policy(author, :all, profile, eligible)
      assert Repo.aggregate(BookTarget, :count) == 2
      assert Books.author_policy(author.id) == :all
    end

    test ":future excludes a past work and includes nil/future ones; :all excludes neither", %{
      author: author
    } do
      expect(PrimaryMetadataMock, :bibliography, 2, fn "A1" ->
        {:ok, [candidate("OLPAST"), candidate("OLNIL"), candidate("OLFUTURE")]}
      end)

      stub(PrimaryMetadataMock, :get_work, fn
        "OLPAST" -> {:ok, provider_work("OLPAST", first_published_on: ~D[2000-01-01])}
        "OLNIL" -> {:ok, provider_work("OLNIL", first_published_on: nil)}
        "OLFUTURE" -> {:ok, provider_work("OLFUTURE", first_published_on: ~D[2999-01-01])}
      end)

      assert {:ok, %{eligible: future_eligible}} = Books.preview_author_policy(author, :future)

      assert future_eligible |> Enum.map(& &1.work.foreign_id) |> Enum.sort() ==
               ["OLFUTURE", "OLNIL"]

      assert {:ok, %{eligible: all_eligible}} = Books.preview_author_policy(author, :all)
      assert length(all_eligible) == 3
    end

    test "the cheap local filter runs before the cap: already-monitored candidates never reach
          Identity.resolve, so the capped window is genuinely new work",
         %{author: author, profile: profile} do
      monitored_candidates =
        for n <- 1..55 do
          fid = "OLMON#{n}W"
          work = imported_work(fid)
          {:ok, _target} = Books.monitor_target(work, :ebook, profile)
          candidate(fid)
        end

      new_candidates = for n <- 1..5, do: candidate("OLNEWCAP#{n}W")

      expect(PrimaryMetadataMock, :bibliography, fn "A1" ->
        {:ok, monitored_candidates ++ new_candidates}
      end)

      # Exactly 5 calls. A cap-before-filter implementation would take the first 50 raw
      # candidates — all 55 already-monitored ones sort before the 5 new ones — filter every one
      # of them out as already-monitored, and never resolve anything: 0 calls, failing this
      # expectation's count rather than the assertions below.
      expect(PrimaryMetadataMock, :get_work, 5, fn fid -> {:ok, provider_work(fid)} end)

      assert {:ok, %{eligible: eligible, ambiguous_count: 0, remaining: 0}} =
               Books.preview_author_policy(author, :all)

      assert length(eligible) == 5

      assert eligible |> Enum.map(& &1.work.foreign_id) |> Enum.sort() ==
               Enum.map(new_candidates, & &1.foreign_id) |> Enum.sort()
    end

    test "more not-yet-monitored candidates than the cap are reported as remaining", %{
      author: author
    } do
      candidates = for n <- 1..60, do: candidate("OLBIG#{n}W")

      expect(PrimaryMetadataMock, :bibliography, fn "A1" -> {:ok, candidates} end)
      stub(PrimaryMetadataMock, :get_work, fn fid -> {:ok, provider_work(fid)} end)

      assert {:ok, %{eligible: eligible, remaining: 10}} =
               Books.preview_author_policy(author, :all)

      assert length(eligible) == Books.max_bibliography_candidates()
    end
  end

  describe "apply_author_policy/4" do
    test "an empty eligible list monitors nothing but still records the policy", %{
      author: author,
      profile: profile
    } do
      assert {:ok, 0} = Books.apply_author_policy(author, :all, profile, [])
      assert Repo.aggregate(BookTarget, :count) == 0
      assert Books.author_policy(author.id) == :all
    end

    test "a candidate independently monitored between preview and confirm keeps its own profile
          and status, and is not counted as created",
         %{author: author, profile: profile} do
      expect(PrimaryMetadataMock, :bibliography, fn "A1" -> {:ok, [candidate("OLRACEW")]} end)
      expect(PrimaryMetadataMock, :get_work, fn "OLRACEW" -> {:ok, provider_work("OLRACEW")} end)

      assert {:ok, %{eligible: [resolution]}} = Books.preview_author_policy(author, :all)

      # The race: something else — a direct per-work approval, a different admin's confirm, a
      # prior refresher tick — monitors the very same work under a DIFFERENT profile before this
      # held preview is ever confirmed.
      {:ok, race_profile} =
        Catalog.create_profile(%{name: "Raced eBooks", kind: :ebook, handling: :standard})

      {:ok, work} = Books.import_resolution(resolution)
      {:ok, raced_target} = Books.monitor_target(work, :ebook, race_profile)

      # The stale confirm must not overwrite what the race already set — not silently, and not
      # counted as a creation it did not actually perform.
      assert {:ok, 0} = Books.apply_author_policy(author, :all, profile, [resolution])

      reloaded = Repo.get!(BookTarget, raced_target.id)
      assert reloaded.status == :monitored
      assert reloaded.profile_id == race_profile.id
    end
  end

  describe "apply_bibliography_refresh/4 (#512)" do
    test "matches the current stored policy: writes targets exactly like apply_author_policy/4",
         %{author: author, profile: profile} do
      {:ok, _policy} = Books.set_author_policy(author, :all, profile)

      resolution = %{provider: :openlibrary, work: provider_work("OLREFRESH1W")}

      assert {:ok, 1} = Books.apply_bibliography_refresh(author, :all, profile, [resolution])
      assert Repo.aggregate(BookTarget, :count) == 1
      # Unlike apply_author_policy/4, this never re-upserts the row it just read as current.
      assert Books.author_policy(author.id) == :all
    end

    test "the stored policy was deleted (reverted to :specific) mid-tick: refuses the whole batch",
         %{author: author, profile: profile} do
      {:ok, _policy} = Books.set_author_policy(author, :all, profile)
      {:ok, nil} = Books.set_author_policy(author, :specific, nil)

      resolution = %{provider: :openlibrary, work: provider_work("OLSTALE1W")}

      # No get_work expectation registered — a write attempt would raise Mox.UnexpectedCallError
      # rather than silently succeeding.
      assert {:ok, 0} = Books.apply_bibliography_refresh(author, :all, profile, [resolution])

      assert Repo.aggregate(BookTarget, :count) == 0
      assert Books.author_policy(author.id) == :specific
    end

    test "the stored policy atom changed (:all -> :future) mid-tick: refuses the stale :all batch",
         %{author: author, profile: profile} do
      {:ok, _policy} = Books.set_author_policy(author, :all, profile)
      {:ok, _policy} = Books.set_author_policy(author, :future, profile)

      resolution = %{provider: :openlibrary, work: provider_work("OLSTALE2W")}

      assert {:ok, 0} = Books.apply_bibliography_refresh(author, :all, profile, [resolution])

      assert Repo.aggregate(BookTarget, :count) == 0
      assert Books.author_policy(author.id) == :future
    end

    test "the stored profile changed mid-tick: refuses the stale batch even with the same policy atom",
         %{author: author, profile: profile} do
      {:ok, other_profile} =
        Catalog.create_profile(%{name: "Other eBooks", kind: :ebook, handling: :standard})

      {:ok, _policy} = Books.set_author_policy(author, :all, profile)
      {:ok, _policy} = Books.set_author_policy(author, :all, other_profile)

      resolution = %{provider: :openlibrary, work: provider_work("OLSTALE3W")}

      assert {:ok, 0} = Books.apply_bibliography_refresh(author, :all, profile, [resolution])

      assert Repo.aggregate(BookTarget, :count) == 0
      assert Repo.get_by!(BookAuthorPolicy, author_id: author.id).profile_id == other_profile.id
    end

    # Codex review on PR #563: the original single up-front check still let a candidate queued
    # AFTER a mid-batch change slip through under the superseded policy. This proves the
    # TIGHTENED per-candidate revalidation actually closes that: the policy is revoked from
    # inside the very first candidate's own write (via a `:telemetry` hook on its `book_works`
    # insert, the same idiom `Cinder.Requests.BookRequestTest` uses for a TOCTOU race), strictly
    # between the two candidates' own writes within ONE call.
    test "a policy revoked BETWEEN two candidates' own writes within one batch stops the second, not just a future batch",
         %{author: author, profile: profile} do
      {:ok, _policy} = Books.set_author_policy(author, :all, profile)

      resolution1 = %{provider: :openlibrary, work: provider_work("OLMIDBATCH1W")}
      resolution2 = %{provider: :openlibrary, work: provider_work("OLMIDBATCH2W")}

      handler = "revoke-mid-batch-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:cinder, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if metadata[:source] == "book_works" do
            :telemetry.detach(handler)
            {:ok, nil} = Books.set_author_policy(author, :specific, nil)
            send(test_pid, :revoked)
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:ok, 1} =
               Books.apply_bibliography_refresh(author, :all, profile, [resolution1, resolution2])

      assert_received :revoked
      assert Repo.aggregate(BookTarget, :count) == 1
      assert Books.author_policy(author.id) == :specific
    end
  end

  defp author_fixture do
    {:ok, author} =
      Books.upsert_author(%{
        name: "Prolific Author",
        identifier: %{provider: "openlibrary", kind: "author", foreign_id: "A1"}
      })

    author
  end

  defp imported_work(foreign_id) do
    {:ok, work} =
      Books.import_resolution(%{provider: :openlibrary, work: provider_work(foreign_id)})

    work
  end

  defp candidate(foreign_id, overrides \\ []) do
    overrides = Map.new(overrides)

    %{
      provider: :openlibrary,
      foreign_id: foreign_id,
      title: Map.get(overrides, :title, "Work #{foreign_id}"),
      contributors: [%{foreign_id: "A1", name: "Prolific Author", role: "author"}],
      contributors_incomplete: false,
      first_published_year: Map.get(overrides, :first_published_year),
      edition_count: 1
    }
  end

  defp provider_work(foreign_id, overrides \\ []) do
    overrides = Map.new(overrides)

    %{
      provider: :openlibrary,
      foreign_id: foreign_id,
      title: Map.get(overrides, :title, "Work #{foreign_id}"),
      first_published_on: Map.get(overrides, :first_published_on, ~D[2000-01-01]),
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
