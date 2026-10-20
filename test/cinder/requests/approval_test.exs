defmodule Cinder.Requests.ApprovalTest do
  # The approval shape, crossed with every request target kind: an admin approval of a pending
  # request and an auto-approval at request time must run the same transaction, with the same
  # quota rule and one announcement after commit. Driven through `Requests`' public interface.
  use Cinder.DataCase, async: false

  import Mox
  import Cinder.AccountsFixtures

  alias Cinder.Accounts
  alias Cinder.Books
  alias Cinder.Books.BookTarget
  alias Cinder.Catalog
  alias Cinder.Catalog.{Movie, Series}
  alias Cinder.Requests
  alias Cinder.Requests.Request
  alias Cinder.Settings

  @kinds [:movie, :season, :book]
  @paths [:admin_approval, :auto_approval]

  setup do
    stub(Cinder.Catalog.TMDBMock, :get_movie, fn id ->
      {:ok, %{tmdb_id: id, imdb_id: nil, title: "Movie #{id}", year: 1999, poster_path: nil}}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_movie_alternative_titles, fn _id -> {:ok, []} end)

    stub(Cinder.Catalog.TMDBMock, :get_series, fn id ->
      {:ok,
       %{
         tmdb_id: id,
         tvdb_id: 1,
         title: "Series #{id}",
         year: 2011,
         poster_path: nil,
         seasons: [%{season_number: 1}, %{season_number: 2}]
       }}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_season, fn _id, n, _locale ->
      {:ok,
       %{
         season_number: n,
         episodes: [
           %{tmdb_episode_id: n, episode_number: 1, title: "e", air_date: ~D[2011-01-01]}
         ]
       }}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_series_alternative_titles, fn _id -> {:ok, []} end)
    stub(Cinder.Catalog.TMDBMock, :get_episode_groups, fn _id -> {:ok, []} end)

    {:ok, ebook} = Catalog.create_profile(%{name: "Ebooks", kind: :ebook, handling: :standard})

    {:ok, work} =
      Books.upsert_work(%{
        title: "A Work",
        first_published_on: ~D[1999-05-04],
        identifier: %{provider: "openlibrary", kind: "work", foreign_id: "OLAPPROVAL"}
      })

    %{work: work, profiles: %{movie: standard(:movies), season: standard(:tv), book: ebook}}
  end

  describe "one announcement, after the target's own publish" do
    for kind <- @kinds, path <- @paths do
      test "#{kind} #{path}", ctx do
        subscribe_all()

        assert {:ok, %Request{status: :approved} = approved} =
                 approve(unquote(path), attrs(unquote(kind), ctx), ctx.profiles[unquote(kind)])

        approved_id = approved.id

        assert [:target, {:approved, ^approved_id}, {:notified, ^approved_id}] =
                 approval_messages(unquote(kind))
      end
    end

    # An existing movie is not created again: its publish re-reads it after commit and, when the
    # approval changed its profile, announces the update instead.
    for path <- @paths do
      test "existing movie #{path}", ctx do
        {:ok, _movie} = Catalog.add_movie(%{tmdb_id: 603, title: "Existing"})
        attrs = Map.put(attrs(:movie, ctx), :proposed_profile_id, ctx.profiles.movie.id)
        subscribe_all()

        assert {:ok, %Request{status: :approved} = approved} =
                 approve(unquote(path), attrs, ctx.profiles.movie)

        approved_id = approved.id

        assert [:target, {:approved, ^approved_id}, {:notified, ^approved_id}] =
                 approval_messages(:existing_movie)
      end
    end
  end

  describe "the quota decision" do
    # A flip turns a pending row the quota already counts into an approved one: it never grows the
    # count, and the admin is the authority. So a quota lowered after the request was filed must
    # not block the approval. The approved row counts while its target is outstanding, so a
    # re-count here would refuse whatever `auto_approve_all` says.
    for kind <- @kinds, auto_approve_all <- ["false", "true"] do
      test "an admin approval is never refused for the requester's quota " <>
             "(#{kind}, auto_approve_all #{auto_approve_all})",
           ctx do
        admin = admin_fixture()
        user = user_fixture()
        {:ok, request} = Requests.create_request(user, attrs(unquote(kind), ctx))
        {:ok, _user} = Accounts.update_user_quota(admin, user, 0)
        Settings.put("auto_approve_all", unquote(auto_approve_all))

        assert {:ok, %Request{status: :approved}} =
                 Requests.approve_request(request, admin, ctx.profiles[unquote(kind)])

        assert target_exists?(unquote(kind), ctx)
      end
    end

    # An auto-approval adds a row, so it re-counts inside the transaction after the target is
    # persisted (#650). A request landing after the pre-check, during the round-trips before the
    # transaction, is what that re-count catches.
    for kind <- @kinds do
      test "an auto-approval refused by the in-transaction re-count leaves nothing (#{kind})",
           ctx do
        Settings.put("auto_approve_all", "true")
        admin = admin_fixture()
        {:ok, user} = Accounts.update_user_quota(admin, user_fixture(), 1)
        competing_request_after_precheck(unquote(kind), user)
        subscribe_all()

        assert {:error, :quota_exceeded} =
                 Requests.create_request(user, attrs(unquote(kind), ctx))

        refute target_exists?(unquote(kind), ctx)
        assert [%Request{title: "Concurrent"}] = Requests.list_for_user(user)
        assert approval_messages(unquote(kind)) == []
      end
    end
  end

  describe "a target type with no approval adapter" do
    # My requests' "Request again" copies a row's target type, so a legacy "series" row reaches
    # create_request/2. Filed pending, it would sit in the approval queue with no admin able to
    # approve it (#770); auto-approved, it used to mint a movie from a series id (#744). Every
    # requester path is refused before any other check, so a requester at quota 0 hears why.
    for type <- ["series", "episode"],
        requester <- [:admin, :member, :member_at_quota, :auto_approved_member] do
      test "#{type} is refused at filing time for #{requester}, with no row written" do
        user = requester(unquote(requester))

        assert {:error, :unsupported_target} =
                 Requests.create_request(user, %{
                   target_type: unquote(type),
                   target_id: 1399,
                   season_number: 1
                 })

        refute Requests.approvable_target?(%{target_type: unquote(type), target_id: 1399})
        assert Repo.aggregate(Movie, :count) == 0
        assert Repo.aggregate(Series, :count) == 0
        assert Repo.aggregate(Request, :count) == 0
      end
    end

    test "is refused before its proposed profile is checked", %{profiles: profiles} do
      assert {:error, :unsupported_target} =
               Requests.create_request(user_fixture(), %{
                 target_type: "series",
                 target_id: 1399,
                 proposed_profile_id: profiles.movie.id
               })

      assert Repo.aggregate(Request, :count) == 0
    end

    test "is refused on admin approval and stays pending", %{profiles: profiles} do
      admin = admin_fixture()
      request = legacy_request!(user_fixture(), "series")

      assert {:error, :unsupported_target} =
               Requests.approve_request(request, admin, profiles.season)

      assert Repo.reload!(request).status == :pending
      assert Repo.aggregate(Series, :count) == 0
    end

    for kind <- @kinds do
      test "#{kind} is an approvable target", ctx do
        assert Requests.approvable_target?(attrs(unquote(kind), ctx))
      end
    end
  end

  defp requester(:admin), do: admin_fixture()
  defp requester(:member), do: user_fixture()

  defp requester(:member_at_quota) do
    {:ok, user} = Accounts.update_user_quota(admin_fixture(), user_fixture(), 0)
    user
  end

  defp requester(:auto_approved_member) do
    Settings.put("auto_approve_all", "true")
    user_fixture()
  end

  # A row from before #770, filed when nothing refused a target type without an adapter.
  defp legacy_request!(user, type) do
    Repo.insert!(%Request{
      user_id: user.id,
      target_type: type,
      target_id: 1399,
      title: "Legacy #{type}",
      status: :pending
    })
  end

  defp approve(:admin_approval, attrs, profile) do
    {:ok, request} = Requests.create_request(user_fixture(), attrs)
    Requests.approve_request(request, admin_fixture(), profile)
  end

  defp approve(:auto_approval, attrs, _profile),
    do: Requests.create_request(admin_fixture(), attrs)

  defp attrs(:movie, _ctx), do: %{target_type: "movie", target_id: 603, title: "M"}

  defp attrs(:season, _ctx),
    do: %{target_type: "season", target_id: 1399, season_number: 2, title: "S"}

  defp attrs(:book, %{work: work}),
    do: %{target_type: "book", target_id: work.id, media_kind: :ebook}

  defp target_exists?(:movie, _ctx), do: Catalog.get_movie_by_tmdb_id(603) != nil
  defp target_exists?(:season, _ctx), do: Catalog.get_series_by_tmdb_id(1399) != nil
  defp target_exists?(:book, %{work: work}), do: Books.list_targets(work) != []

  defp standard(kind), do: Enum.find(Catalog.list_profiles(kind), &(&1.handling == :standard))

  # A second request filed after this one's quota pre-check and before its transaction: during the
  # adapter's provider round-trip for a movie or season.
  defp competing_request_after_precheck(:movie, user) do
    stub(Cinder.Catalog.TMDBMock, :get_movie_alternative_titles, fn _id ->
      insert_competing!(user)
      {:ok, []}
    end)
  end

  defp competing_request_after_precheck(:season, user) do
    stub(Cinder.Catalog.TMDBMock, :get_series_alternative_titles, fn _id ->
      insert_competing!(user)
      {:ok, []}
    end)
  end

  # A book request makes no provider call to hook, so the competing row lands on the first
  # `book_works` read: the request snapshot's, which also runs after the pre-check.
  defp competing_request_after_precheck(:book, user) do
    handler = "competing-#{System.unique_integer([:positive])}"
    on_exit(fn -> :telemetry.detach(handler) end)

    :telemetry.attach(
      handler,
      [:cinder, :repo, :query],
      &__MODULE__.insert_competing_on_work_read/4,
      %{handler: handler, user: user}
    )
  end

  def insert_competing_on_work_read(_event, _measurements, %{source: "book_works"}, config) do
    :telemetry.detach(config.handler)
    insert_competing!(config.user)
  end

  def insert_competing_on_work_read(_event, _measurements, _metadata, _config), do: :ok

  defp insert_competing!(user) do
    Repo.insert!(%Request{
      user_id: user.id,
      target_type: "movie",
      target_id: 999_999,
      title: "Concurrent",
      status: :pending
    })
  end

  defp subscribe_all do
    Requests.subscribe()
    Catalog.subscribe()
    Catalog.subscribe_series()
    Books.subscribe_targets()
    Cinder.TestNotifier.subscribe()
  end

  # Every broadcast is sent from the caller before the call returns, so the mailbox already holds
  # them in order.
  defp approval_messages(kind) do
    receive do
      message ->
        case tag(kind, message) do
          nil -> approval_messages(kind)
          tag -> [tag | approval_messages(kind)]
        end
    after
      0 -> []
    end
  end

  defp tag(:movie, {:movie_created, %Movie{}}), do: :target
  defp tag(:existing_movie, {:movie_updated, %Movie{}}), do: :target
  defp tag(:existing_movie, {:movie_created, %Movie{}}), do: :created_again
  defp tag(:season, {:series_updated, _id}), do: :target
  defp tag(:book, {:book_target_updated, %BookTarget{}}), do: :target
  defp tag(_kind, {:request_approved, %Request{id: id}}), do: {:approved, id}
  defp tag(_kind, {:notify, {:request_approved, %Request{id: id}}}), do: {:notified, id}
  defp tag(_kind, _message), do: nil
end
