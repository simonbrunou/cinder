defmodule Cinder.RequestsTest do
  use Cinder.DataCase, async: false
  import Mox
  alias Cinder.Catalog
  alias Cinder.Catalog.Movie
  alias Cinder.Catalog.TitleAlias
  alias Cinder.Requests
  alias Ecto.Adapters.SQL.Sandbox
  import Cinder.AccountsFixtures

  @attrs %{
    target_type: "movie",
    target_id: 603,
    title: "The Matrix",
    year: 1999,
    poster_path: "/p.jpg"
  }

  setup do
    stub(Cinder.Catalog.TMDBMock, :get_movie, fn id ->
      {:ok,
       %{
         tmdb_id: id,
         imdb_id: nil,
         title: "Movie #{id}",
         year: 1999,
         poster_path: "/p.jpg",
         original_language: "ja"
       }}
    end)

    stub(Cinder.Catalog.TMDBMock, :get_movie_alternative_titles, fn _id -> {:ok, []} end)
    :ok
  end

  test "a non-admin request is pending and creates NO movie (the gate)" do
    user = user_fixture()
    assert {:ok, req} = Requests.create_request(user, @attrs)
    assert req.status == :pending
    assert Repo.aggregate(Movie, :count) == 0
    assert Catalog.list_by_status(:requested) == []
  end

  test "a requester's anime proposal creates no movie until an admin confirms it" do
    user = user_fixture()
    admin = admin_fixture()

    assert {:ok, request} =
             Requests.create_request(user, Map.put(@attrs, :proposed_media_profile, :anime))

    assert request.proposed_media_profile == :anime
    assert Catalog.get_movie_by_tmdb_id(request.target_id) == nil

    assert {:ok, _approved} = Requests.approve_request(request, admin, :anime)
    assert Catalog.get_movie_by_tmdb_id(request.target_id).media_profile == :anime
  end

  test "auto approve without a proposal keeps Auto effectively Standard" do
    Cinder.Settings.put("auto_approve_all", "true")
    user = user_fixture()

    assert {:ok, %{status: :approved}} = Requests.create_request(user, @attrs)
    movie = Catalog.get_movie_by_tmdb_id(@attrs.target_id)
    assert movie.media_profile == :auto
    assert %{selected: :auto, effective: :standard} = Catalog.media_profile_summary(movie)
  end

  test "admin and auto-approved requests carry an explicit Anime proposal" do
    admin = admin_fixture()

    assert {:ok, %{status: :approved}} =
             Requests.create_request(
               admin,
               Map.put(@attrs, :proposed_media_profile, :anime)
             )

    assert Catalog.get_movie_by_tmdb_id(@attrs.target_id).media_profile == :anime

    Cinder.Settings.put("auto_approve_all", "true")
    user = user_fixture()
    attrs = @attrs |> Map.put(:target_id, 604) |> Map.put(:proposed_media_profile, :anime)
    assert {:ok, %{status: :approved}} = Requests.create_request(user, attrs)
    assert Catalog.get_movie_by_tmdb_id(604).media_profile == :anime
  end

  test "invalid profile values are rejected before request or catalog writes" do
    user = user_fixture()
    admin = admin_fixture()
    invalid = Map.put(@attrs, :proposed_media_profile, "forged")

    assert {:error, :invalid_media_profile} = Requests.create_request(user, invalid)
    assert {:error, :invalid_media_profile} = Requests.create_request(admin, invalid)
    assert Requests.list_requests() == []
    assert Catalog.get_movie_by_tmdb_id(@attrs.target_id) == nil

    {:ok, request} = Requests.create_request(user, @attrs)
    assert {:error, :invalid_media_profile} = Requests.approve_request(request, admin, :auto)
    assert Repo.reload!(request).status == :pending
    assert Catalog.get_movie_by_tmdb_id(@attrs.target_id) == nil
  end

  test "a confirmed profile only replaces Auto on an existing movie" do
    user = user_fixture()
    admin = admin_fixture()
    {:ok, movie} = Catalog.add_movie(%{tmdb_id: 603, title: "Existing"})

    {:ok, request} = Requests.create_request(user, @attrs)
    assert {:ok, _} = Requests.approve_request(request, admin, :anime)
    assert Repo.reload!(movie).media_profile == :anime

    {:ok, explicit} = Catalog.add_movie(%{tmdb_id: 604, title: "Explicit"})
    {:ok, explicit} = Catalog.set_media_profile(explicit, :standard)
    attrs = Map.put(@attrs, :target_id, 604)
    {:ok, request} = Requests.create_request(user, attrs)
    assert {:ok, _} = Requests.approve_request(request, admin, :anime)
    assert Repo.reload!(explicit).media_profile == :standard
  end

  test "approving a request for an existing PARKED movie is status-neutral: fills the pick, doesn't re-queue" do
    user = user_fixture()
    admin = admin_fixture()
    {:ok, movie} = Catalog.add_movie(%{tmdb_id: 603, title: "The Matrix"})
    {:ok, movie} = Catalog.transition(movie, %{status: :no_match, search_attempts: 3})

    attrs = Map.merge(@attrs, %{preferred_language: "french"})
    {:ok, req} = Requests.create_request(user, attrs)
    assert {:ok, _} = Requests.approve_request(req, admin, :standard)

    updated = Repo.reload!(movie)
    assert updated.status == :no_match
    assert updated.search_attempts == 3
    assert updated.preferred_language == "french"
    assert updated.media_profile == :standard
  end

  test "a racing deny wins after movie identity preparation and before any catalog write" do
    Mox.set_mox_global()
    parent = self()
    user = user_fixture()
    admin = admin_fixture()
    {:ok, request} = Requests.create_request(user, @attrs)

    stub(Cinder.Catalog.TMDBMock, :get_movie, fn id ->
      send(parent, {:movie_preparing, self()})

      receive do
        :continue ->
          {:ok,
           %{
             tmdb_id: id,
             imdb_id: nil,
             title: "The Matrix",
             year: 1999,
             poster_path: "/p.jpg",
             original_language: "en"
           }}
      end
    end)

    stub(Cinder.Catalog.TMDBMock, :get_movie_alternative_titles, fn _ ->
      {:ok, [%{title: "Matrix, The", country_code: "US"}]}
    end)

    task =
      Task.async(fn ->
        receive do
          :go -> Requests.approve_request(request, admin, :anime)
        end
      end)

    Sandbox.allow(Cinder.Repo, self(), task.pid)
    send(task.pid, :go)
    assert_receive {:movie_preparing, provider_task}

    assert {:ok, _} = Requests.deny_request(request, admin, "no")
    send(provider_task, :continue)

    assert {:error, :not_pending} = Task.await(task)
    assert Catalog.get_movie_by_tmdb_id(@attrs.target_id) == nil
    assert Repo.aggregate(TitleAlias, :count) == 0
  end

  test "an admin request auto-approves and creates the movie" do
    admin = admin_fixture()
    assert {:ok, req} = Requests.create_request(admin, @attrs)
    assert req.status == :approved
    assert req.approved_by_id == admin.id
    assert [%Movie{status: :requested, tmdb_id: 603}] = Catalog.list_by_status(:requested)
  end

  test "approve_request creates the movie and marks approved" do
    user = user_fixture()
    admin = admin_fixture()
    {:ok, req} = Requests.create_request(user, @attrs)
    Catalog.subscribe()
    assert {:ok, approved} = Requests.approve_request(req, admin, :standard)
    assert approved.status == :approved
    assert approved.approved_by_id == admin.id

    assert [%Movie{status: :requested, media_profile: :standard}] =
             Catalog.list_by_status(:requested)

    # Post-commit announcement: the approval's find-or-create runs inside the approval
    # transaction and never broadcasts itself (Cinder.Catalog.find_or_create_at_requested/2).
    assert_receive {:movie_created, %Movie{tmdb_id: 603}}
  end

  test "approving an already-available movie does not reset it" do
    user = user_fixture()
    admin = admin_fixture()
    {:ok, req} = Requests.create_request(user, @attrs)
    {:ok, movie} = Catalog.add_movie(%{tmdb_id: 603, title: "The Matrix"})
    {:ok, _} = Catalog.transition(movie, %{status: :available})
    {:ok, _} = Requests.approve_request(req, admin, :standard)
    assert [%Movie{status: :available}] = Catalog.list_by_status(:available)
    assert Catalog.list_by_status(:requested) == []
  end

  test "deny_request sets denied + reason" do
    user = user_fixture()
    admin = admin_fixture()
    {:ok, req} = Requests.create_request(user, @attrs)
    assert {:ok, denied} = Requests.deny_request(req, admin, "not for the household")
    assert denied.status == :denied
    assert denied.denial_reason == "not for the household"
  end

  test "approve/deny only act on pending requests" do
    user = user_fixture()
    admin = admin_fixture()
    {:ok, req} = Requests.create_request(user, @attrs)
    {:ok, approved} = Requests.approve_request(req, admin, :standard)
    assert {:error, :not_pending} = Requests.deny_request(approved, admin, "x")
  end

  test "a stale approve cannot overwrite a concurrent deny (guarded on DB status)" do
    user = user_fixture()
    admin = admin_fixture()
    {:ok, req} = Requests.create_request(user, @attrs)

    # Another admin session denies while this session still holds the :pending struct.
    {:ok, _} = Requests.deny_request(req, admin, "no")

    assert {:error, :not_pending} = Requests.approve_request(req, admin, :standard)
    # The deny stands and no movie was ever created.
    assert Repo.reload!(req).status == :denied
    assert Catalog.list_by_status(:requested) == []
  end

  test "a stale deny cannot overwrite a concurrent approve (guarded on DB status)" do
    user = user_fixture()
    admin = admin_fixture()
    {:ok, req} = Requests.create_request(user, @attrs)

    {:ok, _} = Requests.approve_request(req, admin, :standard)

    assert {:error, :not_pending} = Requests.deny_request(req, admin, "x")
    assert Repo.reload!(req).status == :approved
  end

  test "no duplicate pending request for the same target" do
    user = user_fixture()
    {:ok, _} = Requests.create_request(user, @attrs)
    assert {:error, _} = Requests.create_request(user, @attrs)
  end

  test "a user can re-request the same target after it was denied" do
    user = user_fixture()
    admin = admin_fixture()
    {:ok, req} = Requests.create_request(user, @attrs)
    {:ok, _} = Requests.deny_request(req, admin, "not this time")
    # The partial unique index only blocks duplicates WHERE status='pending',
    # so a denied row must not prevent a fresh pending request.
    assert {:ok, %{status: :pending}} = Requests.create_request(user, @attrs)
  end

  test "reopen_request returns a denied request to pending and clears the reason" do
    user = user_fixture()
    admin = admin_fixture()
    {:ok, req} = Requests.create_request(user, @attrs)
    {:ok, denied} = Requests.deny_request(req, admin, "not this time")

    assert {:ok, reopened} = Requests.reopen_request(denied, admin)
    assert reopened.status == :pending
    assert reopened.denial_reason == nil
  end

  test "reopen_request only acts on denied requests" do
    user = user_fixture()
    admin = admin_fixture()
    {:ok, req} = Requests.create_request(user, @attrs)
    assert {:error, :not_denied} = Requests.reopen_request(req, admin)
  end

  test "reopen_request returns {:error, changeset} when a pending request already holds the slot" do
    user = user_fixture()
    admin = admin_fixture()
    {:ok, req} = Requests.create_request(user, @attrs)
    {:ok, denied} = Requests.deny_request(req, admin, "no")
    # a fresh pending request now occupies that target's partial-unique pending slot
    {:ok, _pending} = Requests.create_request(user, @attrs)
    assert {:error, %Ecto.Changeset{}} = Requests.reopen_request(denied, admin)
  end

  test "auto_approve_all on → a non-admin add creates the movie" do
    Cinder.Settings.put("auto_approve_all", "true")
    user = user_fixture()
    assert {:ok, %{status: :approved}} = Requests.create_request(user, @attrs)
    assert [%Movie{status: :requested}] = Catalog.list_by_status(:requested)
  end

  test "concurrent-pending quota blocks the over-limit request (different targets)" do
    admin = admin_fixture()
    user = user_fixture()
    {:ok, user} = Cinder.Accounts.update_user_quota(admin, user, 1)

    assert {:ok, %{status: :pending}} = Requests.create_request(user, @attrs)
    other = Map.put(@attrs, :target_id, 604)
    assert {:error, :quota_exceeded} = Requests.create_request(user, other)
  end

  test "quota does not apply to admins or the auto_approve_all path" do
    admin = admin_fixture()
    {:ok, admin} = Cinder.Accounts.update_user_quota(admin, admin, 0)
    assert {:ok, %{status: :approved}} = Requests.create_request(admin, @attrs)

    Cinder.Settings.put("auto_approve_all", "true")
    user = user_fixture()
    {:ok, user} = Cinder.Accounts.update_user_quota(admin, user, 0)

    assert {:ok, %{status: :approved}} =
             Requests.create_request(user, Map.put(@attrs, :target_id, 605))
  end

  test "nil quota is unlimited" do
    user = user_fixture()
    assert {:ok, %{status: :pending}} = Requests.create_request(user, @attrs)

    assert {:ok, %{status: :pending}} =
             Requests.create_request(user, Map.put(@attrs, :target_id, 606))
  end

  test "approval emits a notifier event" do
    Cinder.TestNotifier.subscribe()
    user = user_fixture()
    admin = admin_fixture()
    {:ok, req} = Requests.create_request(user, @attrs)
    {:ok, _} = Requests.approve_request(req, admin, :standard)
    assert_receive {:notify, {:request_approved, %{title: "The Matrix"}}}
  end

  describe "season requests" do
    setup do
      stub(Cinder.Catalog.TMDBMock, :get_series, fn 1399 ->
        {:ok,
         %{
           tmdb_id: 1399,
           tvdb_id: 1,
           title: "GoT",
           year: 2011,
           poster_path: nil,
           seasons: [%{season_number: 1}, %{season_number: 2}]
         }}
      end)

      stub(Cinder.Catalog.TMDBMock, :get_season, fn 1399, n ->
        {:ok,
         %{
           season_number: n,
           episodes: [
             %{tmdb_episode_id: n, episode_number: 1, title: "e", air_date: ~D[2011-01-01]}
           ]
         }}
      end)

      stub(Cinder.Catalog.TMDBMock, :get_series_alternative_titles, fn 1399 -> {:ok, []} end)
      stub(Cinder.Catalog.TMDBMock, :get_episode_groups, fn 1399 -> {:ok, []} end)

      :ok
    end

    defp season_attrs do
      %{target_type: "season", target_id: 1399, season_number: 2, title: "GoT", year: 2011}
    end

    test "a non-admin season request is :pending and creates NO series (security gate)" do
      user = user_fixture()
      assert {:ok, req} = Requests.create_request(user, season_attrs())
      assert req.status == :pending
      assert Cinder.Catalog.get_series_by_tmdb_id(1399) == nil
    end

    test "approving a season request creates the series and monitors only that season" do
      user = user_fixture()
      admin = admin_fixture()
      {:ok, req} = Requests.create_request(user, season_attrs())

      assert {:ok, approved} = Requests.approve_request(req, admin, :standard)
      assert approved.status == :approved

      series = Cinder.Catalog.get_series_by_tmdb_id(1399)
      assert series.media_profile == :standard
      tree = Cinder.Catalog.get_series_with_tree(series.id)
      assert Enum.find(tree.seasons, &(&1.season_number == 2)).monitored
      refute Enum.find(tree.seasons, &(&1.season_number == 1)).monitored
    end

    test "an admin's own season request auto-approves and creates the series immediately" do
      admin = admin_fixture()
      assert {:ok, req} = Requests.create_request(admin, season_attrs())
      assert req.status == :approved
      assert Cinder.Catalog.get_series_by_tmdb_id(1399).media_profile == :auto
    end

    test "an admin's explicit Anime season proposal auto-approves as Anime" do
      admin = admin_fixture()
      attrs = Map.put(season_attrs(), :proposed_media_profile, :anime)

      assert {:ok, %{status: :approved}} = Requests.create_request(admin, attrs)
      assert Cinder.Catalog.get_series_by_tmdb_id(1399).media_profile == :anime
    end

    test "auto_approve_all carries a non-admin's explicit Anime season proposal" do
      Cinder.Settings.put("auto_approve_all", "true")
      user = user_fixture()
      attrs = Map.put(season_attrs(), :proposed_media_profile, :anime)

      assert {:ok, %{status: :approved}} = Requests.create_request(user, attrs)
      assert Cinder.Catalog.get_series_by_tmdb_id(1399).media_profile == :anime
    end

    test "an invalid season profile is rejected without creating a series" do
      admin = admin_fixture()
      attrs = Map.put(season_attrs(), :proposed_media_profile, "forged")

      assert {:error, :invalid_media_profile} = Requests.create_request(admin, attrs)
      assert Cinder.Catalog.get_series_by_tmdb_id(1399) == nil
    end

    test "an explicit season proposal is carried and only replaces Auto" do
      user = user_fixture()
      admin = admin_fixture()

      assert {:ok, series} =
               Cinder.Catalog.add_series(1399,
                 monitor_strategy: :none,
                 media_profile: :auto
               )

      attrs = Map.put(season_attrs(), :proposed_media_profile, :anime)
      {:ok, request} = Requests.create_request(user, attrs)
      assert {:ok, _} = Requests.approve_request(request, admin, :anime)
      assert Repo.reload!(series).media_profile == :anime

      assert {:ok, explicit} = Cinder.Catalog.set_media_profile(Repo.reload!(series), :standard)
      attrs = Map.put(season_attrs(), :season_number, 1)
      {:ok, request} = Requests.create_request(user, attrs)
      assert {:ok, _} = Requests.approve_request(request, admin, :anime)
      assert Repo.reload!(explicit).media_profile == :standard
    end
  end

  describe "delete_request/2" do
    test "deletes the request and returns the deleted struct" do
      user = user_fixture()
      admin = admin_fixture()
      {:ok, req} = Requests.create_request(user, @attrs)

      assert {:ok, deleted} = Requests.delete_request(req, admin)
      assert deleted.id == req.id
      assert Repo.get(Cinder.Requests.Request, req.id) == nil
    end

    test "writes an admin_audit row (in-transaction) recording the actor and request" do
      user = user_fixture()
      admin = admin_fixture()
      {:ok, req} = Requests.create_request(user, @attrs)

      {:ok, _deleted} = Requests.delete_request(req, admin)

      audit = Repo.one(Cinder.Audit.AdminAudit)
      assert audit.actor_id == admin.id
      assert audit.action == "delete_request"
      assert audit.entity_type == "Request"
      assert audit.entity_id == req.id
    end

    test "deleting a non-pending request leaves any spawned catalog row in place (orphan)" do
      # An admin's own request auto-approves AND creates the movie row.
      admin = admin_fixture()
      {:ok, req} = Requests.create_request(admin, @attrs)
      assert req.status == :approved
      assert [%Movie{tmdb_id: 603}] = Catalog.list_by_status(:requested)

      {:ok, _deleted} = Requests.delete_request(req, admin)

      # No FK request -> movie: the catalog row survives the request deletion.
      assert [%Movie{tmdb_id: 603}] = Catalog.list_by_status(:requested)
    end

    test "deleting a denied request re-opens requests_pending_unique (title requestable again)" do
      user = user_fixture()
      admin = admin_fixture()
      {:ok, req} = Requests.create_request(user, @attrs)
      {:ok, denied} = Requests.deny_request(req, admin, "no")

      {:ok, _deleted} = Requests.delete_request(denied, admin)

      # With the denied row gone, the same target can be requested fresh.
      assert {:ok, %{status: :pending}} = Requests.create_request(user, @attrs)
    end
  end

  test "approved movie request carries preferred_language and original_language onto the movie row" do
    admin = admin_fixture()

    stub(Cinder.Catalog.TMDBMock, :get_movie, fn id ->
      {:ok,
       %{
         tmdb_id: id,
         imdb_id: nil,
         title: "The Matrix",
         year: 1999,
         poster_path: "/p.jpg",
         original_language: "en"
       }}
    end)

    attrs = Map.merge(@attrs, %{original_language: "en", preferred_language: "french"})

    assert {:ok, %{status: :approved}} = Requests.create_request(admin, attrs)
    movie = Catalog.get_movie_by_tmdb_id(603)
    assert movie.preferred_language == "french"
    assert movie.original_language == "en"
  end

  test "approve_request (pending path) carries preferred_language and original_language" do
    user = user_fixture()
    admin = admin_fixture()

    attrs = Map.merge(@attrs, %{original_language: "ja", preferred_language: "french"})

    {:ok, req} = Requests.create_request(user, attrs)
    assert {:ok, _} = Requests.approve_request(req, admin, :standard)
    movie = Catalog.get_movie_by_tmdb_id(603)
    assert movie.preferred_language == "french"
    assert movie.original_language == "ja"
  end

  describe "list_requests/0" do
    test "returns requests of every status, newest first, with :user preloaded" do
      user = user_fixture()
      admin = admin_fixture()

      # pending (non-admin, no auto-approve)
      {:ok, pending} = Requests.create_request(user, @attrs)
      # denied
      {:ok, to_deny} = Requests.create_request(user, Map.put(@attrs, :target_id, 604))
      {:ok, denied} = Requests.deny_request(to_deny, admin, "nope")
      # approved (admin auto-approves its own)
      {:ok, approved} = Requests.create_request(admin, Map.put(@attrs, :target_id, 605))

      results = Requests.list_requests()

      assert Enum.map(results, & &1.id) == [approved.id, denied.id, pending.id]
      assert Enum.map(results, & &1.status) == [:approved, :denied, :pending]
      # :user is preloaded (not a NotLoaded struct)
      assert Enum.all?(results, &match?(%Cinder.Accounts.User{}, &1.user))
    end

    test "returns [] when there are no requests" do
      assert Requests.list_requests() == []
    end
  end
end
