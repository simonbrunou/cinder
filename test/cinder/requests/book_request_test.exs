defmodule Cinder.Requests.BookRequestTest do
  use Cinder.DataCase, async: false

  import Cinder.AccountsFixtures

  alias Cinder.Books
  alias Cinder.Books.{BookTarget, Edition, Identifier, Work}
  alias Cinder.Catalog
  alias Cinder.LibraryKind
  alias Cinder.Requests
  alias Cinder.Requests.Request

  setup do
    {:ok, ebook} =
      Catalog.create_profile(%{name: "Ebooks", kind: :ebook, handling: :standard})

    {:ok, audiobook} =
      Catalog.create_profile(%{name: "Audiobooks", kind: :audiobook, handling: :standard})

    %{work: work_fixture(), ebook_profile: ebook, audiobook_profile: audiobook}
  end

  describe "the approval gate" do
    test "a non-admin book request is pending and creates NO target", %{work: work} do
      user = user_fixture()

      assert {:ok, request} = Requests.create_request(user, attrs(work, :ebook))
      assert request.status == :pending
      assert request.media_kind == :ebook
      assert request.title == work.title
      assert request.year == 1999
      assert Repo.aggregate(BookTarget, :count) == 0
    end

    test "an admin request auto-approves into one monitored target", %{
      work: work,
      ebook_profile: profile
    } do
      admin = admin_fixture()

      assert {:ok, request} = Requests.create_request(admin, attrs(work, :ebook))
      assert request.status == :approved

      assert [%BookTarget{media_kind: :ebook, status: :monitored, profile_id: profile_id}] =
               Books.list_targets(work)

      assert profile_id == profile.id
    end

    test "admin approval of a pending request arms the target", %{
      work: work,
      ebook_profile: profile
    } do
      user = user_fixture()
      admin = admin_fixture()

      {:ok, request} = Requests.create_request(user, attrs(work, :ebook))

      assert {:ok, approved} = Requests.approve_request(request, admin, profile)
      assert approved.status == :approved
      assert approved.proposed_profile_id == profile.id

      assert [%BookTarget{status: :monitored, profile_id: profile_id}] = Books.list_targets(work)
      assert profile_id == profile.id
    end

    test "denial leaves no target", %{work: work} do
      user = user_fixture()
      admin = admin_fixture()

      {:ok, request} = Requests.create_request(user, attrs(work, :ebook))

      assert {:ok, denied} = Requests.deny_request(request, admin, "not this one")
      assert denied.status == :denied
      assert Repo.aggregate(BookTarget, :count) == 0
    end

    test "an unknown work id never creates a request row" do
      user = user_fixture()

      assert {:error, :unknown_work} =
               Requests.create_request(user, %{
                 target_type: "book",
                 target_id: 999_999,
                 media_kind: :ebook
               })

      assert Repo.aggregate(Request, :count) == 0
    end
  end

  describe "the (work, media_kind) axis" do
    test "one work holds an independent ebook and audiobook request and target", %{
      work: work,
      ebook_profile: ebook,
      audiobook_profile: audiobook
    } do
      admin = admin_fixture()

      assert {:ok, _} = Requests.create_request(admin, attrs(work, :ebook))
      assert {:ok, _} = Requests.create_request(admin, attrs(work, :audiobook))

      assert [
               %BookTarget{media_kind: :ebook, profile_id: ebook_id},
               %BookTarget{media_kind: :audiobook, profile_id: audiobook_id}
             ] = Enum.sort_by(Books.list_targets(work), & &1.media_kind, :desc)

      assert ebook_id == ebook.id
      assert audiobook_id == audiobook.id
    end

    test "two pending requests differing only in media kind both insert", %{work: work} do
      user = user_fixture()

      assert {:ok, _} = Requests.create_request(user, attrs(work, :ebook))
      assert {:ok, _} = Requests.create_request(user, attrs(work, :audiobook))
      assert {:error, %Ecto.Changeset{}} = Requests.create_request(user, attrs(work, :ebook))
    end
  end

  describe "target status is not clobbered by a second approval" do
    test "an available target keeps its status and takes the profile", %{
      work: work,
      ebook_profile: profile
    } do
      {:ok, target} = Books.ensure_target(work, :ebook)
      {:ok, _} = Books.transition_target(target, %{status: :available}, expect: :unmonitored)

      admin = admin_fixture()
      assert {:ok, _} = Requests.create_request(admin, attrs(work, :ebook))

      assert [%BookTarget{status: :available, profile_id: profile_id}] = Books.list_targets(work)
      assert profile_id == profile.id
    end

    test "a held target refuses the approval instead of lying about it", %{work: work} do
      {:ok, target} = Books.ensure_target(work, :ebook)

      {:ok, _} =
        Books.transition_target(target, %{status: :held, hold_reason: "identity conflict"},
          expect: :unmonitored
        )

      admin = admin_fixture()

      # Approving would otherwise flip the request and mail "Cinder will watch for a copy"
      # while the target stays held and nothing ever searches.
      assert {:error, :target_held} = Requests.create_request(admin, attrs(work, :ebook))
      assert Repo.aggregate(Request, :count) == 0

      assert [%BookTarget{status: :held, hold_reason: "identity conflict"}] =
               Books.list_targets(work)
    end

    test "a held target also blocks an admin approving a pending request", %{
      work: work,
      ebook_profile: profile
    } do
      user = user_fixture()
      admin = admin_fixture()
      {:ok, request} = Requests.create_request(user, attrs(work, :ebook))

      {:ok, target} = Books.ensure_target(work, :ebook)

      {:ok, _} =
        Books.transition_target(target, %{status: :held, hold_reason: "disk conflict"},
          expect: :unmonitored
        )

      assert {:error, :target_held} = Requests.approve_request(request, admin, profile)
      assert %{status: :pending} = Repo.reload!(request)
    end
  end

  describe "profile kinds fail closed" do
    test "a TV profile cannot approve a book request", %{work: work} do
      {:ok, tv} = Catalog.create_profile(%{name: "TV std", kind: :tv, handling: :standard})
      user = user_fixture()
      admin = admin_fixture()

      {:ok, request} = Requests.create_request(user, attrs(work, :ebook))

      assert {:error, :invalid_media_profile} = Requests.approve_request(request, admin, tv)
      assert Repo.aggregate(BookTarget, :count) == 0
    end

    test "an audiobook profile cannot approve an ebook request", %{
      work: work,
      audiobook_profile: audiobook
    } do
      user = user_fixture()
      admin = admin_fixture()

      {:ok, request} = Requests.create_request(user, attrs(work, :ebook))

      assert {:error, :invalid_media_profile} =
               Requests.approve_request(request, admin, audiobook)

      assert Repo.aggregate(BookTarget, :count) == 0
    end

    test "proposing a TV profile on a book request is rejected before insert", %{work: work} do
      {:ok, tv} = Catalog.create_profile(%{name: "TV std", kind: :tv, handling: :standard})
      user = user_fixture()

      assert {:error, :invalid_media_profile} =
               Requests.create_request(
                 user,
                 work |> attrs(:ebook) |> Map.put(:proposed_profile_id, tv.id)
               )

      assert Repo.aggregate(Request, :count) == 0
    end

    test "auto-approval with no book profile configured creates nothing", %{work: work} do
      Repo.delete_all(Cinder.Catalog.Profile)
      admin = admin_fixture()

      assert {:error, :invalid_media_profile} =
               Requests.create_request(admin, attrs(work, :ebook))

      assert Repo.aggregate(Request, :count) == 0
      assert Repo.aggregate(BookTarget, :count) == 0
    end

    # Issue #362: the approval reads the profile, then `flip_pending/2` writes
    # `proposed_profile_id` with `update_all`, which skips Ecto's `to_constraints`. A second
    # admin re-kinding the profile in that window makes `requests_profile_integrity` ABORT, and
    # the caller must see a refusal rather than a raw Exqlite.Error 500. The telemetry hook is
    # the only deterministic way to land inside that window.
    test "a profile re-kinded between the profile read and the write is refused, not raised", %{
      work: work,
      ebook_profile: profile
    } do
      user = user_fixture()
      admin = admin_fixture()

      {:ok, request} = Requests.create_request(user, attrs(work, :ebook))

      handler = "rekind-#{System.unique_integer([:positive])}"
      abort_handler = "abort-#{System.unique_integer([:positive])}"

      on_exit(fn ->
        :telemetry.detach(handler)
        :telemetry.detach(abort_handler)
      end)

      :telemetry.attach(
        handler,
        [:cinder, :repo, :query],
        &__MODULE__.rekind_on_profile_read/4,
        %{handler: handler, profile: profile, test: self()}
      )

      :telemetry.attach(
        abort_handler,
        [:cinder, :repo, :query],
        &__MODULE__.report_aborted_request_write/4,
        %{test: self()}
      )

      assert {:error, :invalid_media_profile} = Requests.approve_request(request, admin, profile)

      # `:telemetry` swallows and logs handler exceptions, so without this the re-kind silently
      # not happening would degrade the test into a restatement of the plain wrong-kind refusal.
      assert_received :rekinded

      # The re-kind is pinned to the *first* `media_profiles` read, so an added preload upstream
      # could move the window ahead of `current_profile/2`'s check and leave this test passing on
      # the ordinary wrong-kind refusal instead of the race. This says which refusal it was: the
      # `requests` write reached the DB and the trigger aborted it. It is also the far end of the
      # constraint-name coupling — renaming the trigger without updating `flip_pending/2`'s rescue
      # fails here.
      assert_received {:aborted_request_write, message}
      assert message =~ "requests_profile_integrity"

      assert %Request{status: :pending, proposed_profile_id: nil} = Repo.reload!(request)
      assert Repo.aggregate(BookTarget, :count) == 0
    end
  end

  describe "the DB says the same thing the changeset does" do
    test "the requests profile-integrity trigger accepts a matching book profile", %{
      work: work,
      ebook_profile: profile
    } do
      user = user_fixture()

      assert {:ok, _} =
               Repo.insert(
                 Request.create_changeset(%Request{}, %{
                   user_id: user.id,
                   target_type: "book",
                   target_id: work.id,
                   media_kind: :ebook,
                   status: :pending,
                   proposed_profile_id: profile.id,
                   proposed_media_profile: :standard
                 })
               )
    end

    test "the trigger rejects a mismatched-kind profile the changeset never sees", %{
      work: work,
      audiobook_profile: audiobook
    } do
      user = user_fixture()

      assert {:error, changeset} =
               Repo.insert(
                 Request.create_changeset(%Request{}, %{
                   user_id: user.id,
                   target_type: "book",
                   target_id: work.id,
                   media_kind: :ebook,
                   status: :pending,
                   proposed_profile_id: audiobook.id,
                   proposed_media_profile: :standard
                 })
               )

      assert "is invalid" in errors_on(changeset).proposed_profile_id
    end

    test "re-kinding a profile a book request points at aborts in the DB, not just the app", %{
      work: work,
      ebook_profile: profile
    } do
      admin = admin_fixture()
      {:ok, _} = Requests.create_request(admin, attrs(work, :ebook))

      # The context refuses first...
      assert {:error, %Ecto.Changeset{}} = Catalog.update_profile(profile, %{kind: :audiobook})

      # ...and so does media_profiles_references_integrity_update, for a writer that bypasses it.
      # Deleting the book_target first isolates the requests arm from B2a's book_targets arm.
      Repo.delete_all(BookTarget)

      assert_raise Exqlite.Error, ~r/media_profiles_references_integrity/, fn ->
        Repo.query!("UPDATE media_profiles SET kind = 'audiobook' WHERE id = ?1", [profile.id])
      end
    end
  end

  describe "the API projection" do
    test "carries media_kind both ways", %{work: work} do
      user = user_fixture()
      {:ok, request} = Requests.create_request(user, attrs(work, :audiobook))

      assert %{media_kind: :audiobook, target_type: "book", target_id: target_id} =
               Requests.for_api(request)

      assert target_id == work.id

      assert [%{media_kind: :audiobook}] = Requests.export_for_user(user)
    end
  end

  describe "the two book formats stay distinguishable" do
    test "the shared request title names the format", %{work: work} do
      user = user_fixture()
      {:ok, ebook} = Requests.create_request(user, attrs(work, :ebook))
      {:ok, audiobook} = Requests.create_request(user, attrs(work, :audiobook))

      ebook_title = CinderWeb.LiveHelpers.request_title(ebook, "en")
      audiobook_title = CinderWeb.LiveHelpers.request_title(audiobook, "en")

      assert ebook_title =~ work.title
      assert audiobook_title =~ work.title
      refute ebook_title == audiobook_title
    end

    # The class fence, not one instance of it. `format_label/1` is the single source of the
    # user-visible spelling for the Discord and log transports, and `request_title/2` is the
    # single source for every UI surface. Both enumerate the book kinds literally, so a third
    # kind added to `LibraryKind.books/0` would raise in one and render bare in the other. This
    # fails at test time instead.
    test "every book kind has a format label and a distinct request title", %{work: work} do
      titles =
        Map.new(LibraryKind.books(), fn kind ->
          assert is_binary(LibraryKind.format_label(kind))

          request = %Request{
            target_type: "book",
            target_id: work.id,
            media_kind: kind,
            title: work.title,
            year: 1999
          }

          title = CinderWeb.LiveHelpers.request_title(request, "en")

          assert title != work.title, "LiveHelpers.request_title/2 renders #{kind} bare"

          # `format_label/1`'s docstring promises it matches the msgid the UI renders; without
          # this, a kind whose label and msgid disagree passes every other assertion here.
          assert title =~ LibraryKind.format_label(kind),
                 "#{kind}'s format_label/1 disagrees with the msgid request_title/2 renders"

          {kind, title}
        end)

      # Distinct from the bare title is not enough: two kinds sharing a clause would pass that.
      assert titles |> Map.values() |> Enum.uniq() |> length() == map_size(titles)

      assert LibraryKind.books()
             |> Enum.map(&LibraryKind.format_label/1)
             |> Enum.uniq()
             |> length() ==
               length(LibraryKind.books())
    end

    test "the delete audit records which format was removed", %{work: work} do
      user = user_fixture()
      admin = admin_fixture()
      {:ok, request} = Requests.create_request(user, attrs(work, :audiobook))

      assert {:ok, _} = Requests.delete_request(request, admin)

      assert %{detail: %{"media_kind" => "audiobook"}} =
               Repo.one(Cinder.Audit.AdminAudit)
    end
  end

  describe "the changeset's media-kind rule" do
    test "a book request without a media kind is rejected" do
      changeset =
        Request.create_changeset(%Request{}, %{
          user_id: 1,
          target_type: "book",
          target_id: 1,
          status: :pending
        })

      assert "can't be blank for a book request" in errors_on(changeset).media_kind
    end

    test "a movie request carrying a media kind is rejected" do
      changeset =
        Request.create_changeset(%Request{}, %{
          user_id: 1,
          target_type: "movie",
          target_id: 603,
          media_kind: :ebook,
          status: :pending
        })

      assert "is only valid for a book request" in errors_on(changeset).media_kind
    end
  end

  describe "the resolution entry point gates the catalog write" do
    test "an over-quota request imports nothing", %{work: existing} do
      admin = admin_fixture()
      user = user_fixture()
      {:ok, user} = Cinder.Accounts.update_user_quota(admin, user, 1)

      assert {:ok, %{status: :pending}} = Requests.create_request(user, attrs(existing, :ebook))

      before = {Repo.aggregate(Work, :count), Repo.aggregate(Edition, :count)}

      assert {:error, :quota_exceeded} =
               Requests.create_request(user, %{
                 target_type: "book",
                 resolution: resolution("OL-NEW"),
                 media_kind: :ebook
               })

      # The refused press must leave no work and no editions behind. Importing on the caller's
      # side instead would let an over-quota user grow the catalog on every rejected attempt.
      assert {Repo.aggregate(Work, :count), Repo.aggregate(Edition, :count)} == before
      refute Repo.get_by(Identifier, provider: "openlibrary", foreign_id: "OL-NEW")
    end

    test "an accepted request imports the work and points the request at it" do
      user = user_fixture()

      assert {:ok, request} =
               Requests.create_request(user, %{
                 target_type: "book",
                 resolution: resolution("OL-FRESH"),
                 media_kind: :ebook
               })

      assert %Identifier{work_id: work_id} =
               Repo.get_by(Identifier, provider: "openlibrary", foreign_id: "OL-FRESH")

      assert request.target_id == work_id
      assert request.title == "Beloved"
      assert request.year == 1987
      assert Repo.aggregate(BookTarget, :count) == 0
    end

    test "re-requesting a resolved work updates in place rather than duplicating" do
      one = user_fixture()
      two = user_fixture()

      assert {:ok, _} =
               Requests.create_request(one, %{
                 target_type: "book",
                 resolution: resolution("OL-SHARED"),
                 media_kind: :ebook
               })

      count = Repo.aggregate(Work, :count)

      assert {:ok, _} =
               Requests.create_request(two, %{
                 target_type: "book",
                 resolution: resolution("OL-SHARED"),
                 media_kind: :ebook
               })

      assert Repo.aggregate(Work, :count) == count
    end
  end

  # `Catalog.get_profile/1` inside `current_profile/2` is the approval's first `media_profiles`
  # read, and it is the read the TOCTOU window is defined against: firing here puts the re-kind
  # provably after the check and before `flip_pending/2`'s write, which is the race the approval
  # cannot re-validate away.
  def rekind_on_profile_read(_event, _measurements, %{source: "media_profiles"}, %{
        handler: handler,
        profile: profile,
        test: test
      }) do
    :telemetry.detach(handler)
    {:ok, _} = Catalog.update_profile(profile, %{kind: :audiobook})
    send(test, :rekinded)
  end

  def rekind_on_profile_read(_event, _measurements, _metadata, _config), do: :ok

  # Reports the trigger firing on the `requests` write itself, so the test can tell the raced
  # refusal apart from the plain wrong-kind one that never reaches the DB.
  def report_aborted_request_write(
        _event,
        _measurements,
        %{source: "requests", result: {:error, %Exqlite.Error{message: message}}},
        %{test: test}
      ) do
    send(test, {:aborted_request_write, message})
  end

  def report_aborted_request_write(_event, _measurements, _metadata, _config), do: :ok

  defp attrs(work, media_kind),
    do: %{target_type: "book", target_id: work.id, media_kind: media_kind}

  defp work_fixture do
    id = Integer.to_string(System.unique_integer([:positive]))

    {:ok, work} =
      Books.upsert_work(%{
        title: "Work #{id}",
        first_published_on: ~D[1999-05-04],
        identifier: %{provider: "openlibrary", kind: "work", foreign_id: id}
      })

    work
  end

  defp resolution(foreign_id) do
    %{
      provider: :openlibrary,
      work: %{
        provider: :openlibrary,
        foreign_id: foreign_id,
        title: "Beloved",
        first_published_on: ~D[1987-09-16],
        overview: "A ghost story.",
        contributors: [%{foreign_id: "OL30084A", name: "Toni Morrison", role: "author"}],
        contributors_incomplete: false,
        editions: [
          %{
            foreign_id: foreign_id <> "-M",
            media_kind: :ebook,
            title: "Beloved",
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
    }
  end
end
