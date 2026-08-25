defmodule Cinder.Requests.BookRequestTest do
  use Cinder.DataCase, async: false

  import Cinder.AccountsFixtures

  alias Cinder.Books
  alias Cinder.Books.BookTarget
  alias Cinder.Catalog
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

    test "a held target is never re-armed", %{work: work} do
      {:ok, target} = Books.ensure_target(work, :ebook)

      {:ok, _} =
        Books.transition_target(target, %{status: :held, hold_reason: "identity conflict"},
          expect: :unmonitored
        )

      admin = admin_fixture()
      assert {:ok, _} = Requests.create_request(admin, attrs(work, :ebook))

      assert [%BookTarget{status: :held, hold_reason: "identity conflict"}] =
               Books.list_targets(work)
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
end
