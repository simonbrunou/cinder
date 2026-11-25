defmodule Cinder.Download.RefusedReleaseIndexerTest do
  @moduledoc """
  When Cinder or the client refuses for good a TV release Cinder's search picked, Cinder tries to
  block it for its series with the indexer id the download intent stored for the refused search
  result (#1515), beside its source (#1645). That row then skips the title in a result from the
  same indexer, or from its source with no indexer id, and not in another indexer's result. A row
  with no indexer id (a refused result with none, an intent stored without one, any other block
  reason) skips the title in every indexer's results. Copies of one link from two indexers stay
  two candidates.

  Each search result here carries its own download link, and the client answers by link, so a
  test can refuse one link of a title and accept another. A lower-ranked 720p release with
  another title is the positive control of each test whose blocked title must not be grabbed: the
  poll that skips the title grabs the control instead.
  """
  use Cinder.DataCase, async: false

  import Ecto.Query
  import Mox
  import Cinder.CatalogFixtures
  import Cinder.PollerHelpers, only: [stub_clean_content: 0]

  alias Cinder.Acquisition
  alias Cinder.Acquisition.{HouseholdPolicy, Release}
  alias Cinder.Catalog
  alias Cinder.Catalog.{BlockedRelease, Grab}
  alias Cinder.Download
  alias Cinder.Download.{Intent, TvPoller}
  alias Cinder.Repo

  @moduletag :capture_log

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    on_exit(fn -> :persistent_term.erase({TvPoller, :last_run}) end)
    stub_clean_content()
  end

  @episode "Show.S01E01.1080p.WEB-DL-GRP"
  @control "Show.S01E01.720p.WEB-DL-CTRL"

  for {kind, profile, numbers, title} <- [
        {:episode, :standard, [1], "Show.S01E01.1080p.WEB-DL-GRP"},
        {:season_pack, :standard, [1, 2], "Show.S01.1080p.WEB-DL-GRP"},
        {:anime_episode, :anime, [1], "[GRP] Show S01E01 [1080p]"}
      ] do
    @profile profile
    @numbers numbers
    @title title

    test "#{kind}: a title refused from indexer 1 is grabbed from indexer 2 on the next poll" do
      %{series: series} = wanted_episodes(@numbers, @profile)
      stub_results([result(@title, "bad", 1, 20), result(@title, "good", 2, 10)])
      stub_client(%{"bad" => [{:error, :bad_torrent}]})

      poll_times(2)

      assert added() == ["bad", "good"]
      assert grabbed() == ["hash-good"]
      assert blocked(series.id) == [{@title, "bad_torrent", 1}]
    end
  end

  # The search merges copies of one link, so one link from two indexers must stay two candidates.
  for {profile, title} <- [
        {:standard, "Show.S01E01.1080p.WEB-DL-GRP"},
        {:anime, "[GRP] Show S01E01 [1080p]"}
      ] do
    @profile profile
    @title title

    test "#{profile}: one link from a blocked and an unblocked indexer is grabbed" do
      %{series: series} = wanted_episodes([1], @profile)
      :ok = Catalog.block_series_release(series.id, @title, :bad_torrent, {"prowlarr", 1})
      stub_results([result(@title, "shared", 1, 20), result(@title, "shared", 2, 10)])
      stub_client(%{})

      poll_times(1)

      assert added() == ["shared"]
      assert grabbed() == ["hash-shared"]
    end

    # #1645: Prowlarr's indexer 7 and a native indexer 7 are two sites, so the search keeps one
    # copy of a link for each, and a copy with no id folds only into a copy from its own source.
    # No fetch source maps "native" before #1651, so the intent for the native copy retries with
    # no add/2 call (#1650): the test reads the intent the pick reserved.
    for {name, native_id} <- [{"the same id", 7}, {"no id", nil}] do
      @native_id native_id

      test "#{profile}: one link from a blocked Prowlarr indexer and a native one with #{name} is picked" do
        %{series: series} = wanted_episodes([1], @profile)
        :ok = Catalog.block_series_release(series.id, @title, :bad_torrent, {"prowlarr", 7})

        stub_results([
          Map.put(result(@title, "shared", 7, 20), :indexer_source, "prowlarr"),
          Map.put(result(@title, "shared", @native_id, 10), :indexer_source, "native")
        ])

        stub_client(%{})

        poll_times(1)

        assert [%Intent{release: stored, last_error: ":unknown_indexer_source"}] =
                 Repo.all(Intent)

        assert {stored["indexer_source"], stored["indexer_id"]} == {"native", @native_id}
        assert added() == []
        assert grabbed() == []
      end
    end
  end

  # The title guard reads a link's query origins: the blocked indexer's id-scoped copy vouches for
  # the free-text copy another indexer sent of the same link.
  for {profile, year, title, tvdb_id} <- [
        {:standard, nil, "Other.Name.S01E01.1080p.WEB-DL-GRP", nil},
        {:anime, 2008, "86 Eighty-Six S01E01 [1080p]", 99}
      ] do
    @profile profile
    @year year
    @title title
    @tvdb_id tvdb_id

    test "#{profile}: one link's copies from two indexers share their query origins" do
      series =
        series_fixture(%{
          tvdb_id: 99,
          year: @year,
          monitor_strategy: :all,
          media_profile: @profile
        })

      episode_fixture(season_fixture(series), %{episode_number: 1})
      :ok = Catalog.block_series_release(series.id, @title, :bad_torrent, {"prowlarr", 1})
      copy = &Map.merge(result(@title, "shared", &1, 10), %{query_origins: &2, tvdb_id: @tvdb_id})
      stub_results([copy.(1, [:id_scoped]), copy.(2, [:free_text])])
      stub_client(%{})

      poll_times(1)

      assert added() == ["shared"]
      assert grabbed() == ["hash-shared"]
    end
  end

  test "the season panel lists one link from two indexers once for each" do
    %{series: series} = wanted_episodes([1])
    :ok = Catalog.block_series_release(series.id, @episode, :bad_torrent, {"prowlarr", 1})

    stub_results([
      Map.put(result(@episode, "shared", 1, 20), :query_origins, [:id_scoped]),
      Map.merge(result(@episode, "shared", 2, 10), %{query_origins: [:free_text], size: 1})
    ])

    assert judged_rows(series) == [{1, {:rejected, :blocklisted}}, {2, :ok}]

    # Each indexer's row is the link's merged copy under its own indexer id.
    context = Catalog.season_acquisition_context(series, 1)
    {:ok, judged} = Acquisition.judge_season(context, [1], HouseholdPolicy.for_target(series))
    [first, second] = judged.rows |> Enum.map(& &1.release) |> Enum.sort_by(& &1.indexer_id)
    assert {first.query_origins, first.size} == {[:id_scoped, :free_text], 2_000_000_000}
    assert %{second | indexer_id: 1} == first
  end

  test "a link's copy with no indexer id folds into its copy that names one" do
    %{series: series} = wanted_episodes([1])
    stub_results([result(@episode, "shared", nil, 20), result(@episode, "shared", 7, 10)])

    assert judged_rows(series) == [{7, :ok}]
  end

  # #1644: each row `judge_season/3` returns for one link carries the id, source, name, link origin
  # and credentials version of the indexer that sent it, not those of the link's first copy.
  test "judge_season/3 gives each indexer's row of one link its own provenance" do
    %{series: series} = wanted_episodes([1])

    stub_results([
      Map.merge(result(@episode, "shared", 1, 20), provenance("prowlarr", "One", 3)),
      Map.merge(result(@episode, "shared", 2, 10), provenance("native", "Two", 8))
    ])

    assert judged_provenance(series) == [
             {1, "prowlarr", "One", "https://one.example", 3},
             {2, "native", "Two", "https://two.example", 8}
           ]
  end

  test "judge_season/3 takes each indexer's provenance from its first copy of a link" do
    %{series: series} = wanted_episodes([1])

    stub_results([
      Map.merge(result(@episode, "shared", 1, 20), provenance("prowlarr", "One", 3)),
      Map.merge(result(@episode, "shared", 2, 10), provenance("native", "Two", 8)),
      Map.merge(result(@episode, "shared", 2, 10), provenance("native", "Two later", 9))
    ])

    assert judged_provenance(series) == [
             {1, "prowlarr", "One", "https://one.example", 3},
             {2, "native", "Two", "https://two.example", 8}
           ]
  end

  test "judge_season/3 leaves no origin on an indexer whose copy of a link has none" do
    %{series: series} = wanted_episodes([1])

    stub_results([
      Map.merge(result(@episode, "shared", 1, 20), provenance("prowlarr", "One", 3)),
      Map.merge(result(@episode, "shared", 2, 10), %{
        provenance("native", "Two", 8)
        | download_url_origin: nil
      })
    ])

    assert judged_provenance(series) == [
             {1, "prowlarr", "One", "https://one.example", 3},
             {2, "native", "Two", nil, 8}
           ]
  end

  test "a link's copy with no indexer id leaves the named copy its own provenance" do
    %{series: series} = wanted_episodes([1])

    stub_results([
      Map.merge(result(@episode, "shared", nil, 20), provenance("prowlarr", "Nameless", 1)),
      Map.merge(result(@episode, "shared", 7, 10), provenance("prowlarr", "Seven", 7))
    ])

    assert judged_provenance(series) == [{7, "prowlarr", "Seven", "https://seven.example", 7}]
  end

  test "one indexer's same title at another link stays blocked by the one row" do
    %{series: series} = wanted_episodes([1])

    stub_results([
      result(@episode, "bad", 1, 20),
      result(@episode, "other", 1, 10),
      result(@control, "control", 1, 5)
    ])

    stub_client(%{"bad" => [{:error, :bad_torrent}]})

    poll_times(2)

    assert added() == ["bad", "control"]
    assert grabbed() == ["hash-control"]
    assert blocked(series.id) == [{@episode, "bad_torrent", 1}]
  end

  test "a refused result with no indexer id blocks its title from an indexer with an id" do
    %{series: series} = wanted_episodes([1])

    stub_results([
      result(@episode, "bad", nil, 20),
      result(@episode, "other", 2, 10),
      result(@control, "control", 2, 5)
    ])

    stub_client(%{"bad" => [{:error, :bad_torrent}]})

    poll_times(2)

    assert added() == ["bad", "control"]
    assert grabbed() == ["hash-control"]
    assert blocked(series.id) == [{@episode, "bad_torrent", nil}]
  end

  test "a row with an indexer id blocks its title in a result with no indexer id" do
    %{series: series} = wanted_episodes([1])

    stub_results([
      result(@episode, "bad", 1, 20),
      result(@episode, "other", nil, 10),
      result(@control, "control", nil, 5)
    ])

    stub_client(%{"bad" => [{:error, :bad_torrent}]})

    poll_times(2)

    assert added() == ["bad", "control"]
    assert grabbed() == ["hash-control"]
    assert blocked(series.id) == [{@episode, "bad_torrent", 1}]
  end

  test "a title-only row of another reason blocks the title from every indexer" do
    %{series: series} = wanted_episodes([1])
    :ok = Catalog.block_series_release(series.id, @episode, :stalled)

    stub_results([
      result(@episode, "one", 1, 20),
      result(@episode, "two", 2, 10),
      result(@control, "control", 2, 5)
    ])

    stub_client(%{})

    poll_times(1)

    assert added() == ["control"]
    assert grabbed() == ["hash-control"]
    assert blocked(series.id) == [{@episode, "stalled", nil}]
  end

  test "a title refused from two indexers is blocked for each" do
    %{series: series} = wanted_episodes([1])

    stub_results([
      result(@episode, "bad-1", 1, 20),
      result(@episode, "bad-2", 2, 10),
      result(@control, "control", 2, 5)
    ])

    stub_client(%{"bad-1" => [{:error, :bad_torrent}], "bad-2" => [{:error, :add_rejected}]})

    poll_times(3)

    assert added() == ["bad-1", "bad-2", "control"]
    assert grabbed() == ["hash-control"]
    assert blocked(series.id) == [{@episode, "bad_torrent", 1}, {@episode, "add_rejected", 2}]
  end

  test "a stored intent's retry refused for good blocks the title for the intent's indexer" do
    %{series: series} = wanted_episodes([1])
    stub_results([result(@episode, "bad", 1, 20), result(@episode, "good", 2, 10)])
    stub_client(%{"bad" => [{:error, :timeout}, {:error, :bad_torrent}]})
    start_supervised!({TvPoller, interval: 60_000, search_retry_after: 0})

    assert :ok = TvPoller.poll()
    assert [%Intent{release: %{"indexer_id" => 1}} = intent] = Repo.all(Intent)
    intent |> Intent.changeset(%{next_attempt_at: DateTime.utc_now(:second)}) |> Repo.update!()
    assert :ok = TvPoller.poll()

    assert added() == ["bad", "bad", "good"]
    assert grabbed() == ["hash-good"]
    assert blocked(series.id) == [{@episode, "bad_torrent", 1}]
  end

  test "a stored intent with no indexer id that is refused for good blocks the title everywhere" do
    %{series: series, episode_ids: [id]} = wanted_episodes([1])

    {:ok, %Intent{release: stored}} =
      Download.reserve_intent(%{
        kind: :episode,
        target_id: id,
        episode_ids: [id],
        protocol: :torrent,
        release: %Release{title: @episode, download_url: "stored", protocol: :torrent}
      })

    refute Map.has_key?(stored, "indexer_id")

    stub_results([result(@episode, "other", 2, 10), result(@control, "control", 2, 5)])
    stub_client(%{"stored" => [{:error, :bad_torrent}]})

    poll_times(1)

    assert added() == ["stored", "control"]
    assert grabbed() == ["hash-control"]
    assert blocked(series.id) == [{@episode, "bad_torrent", nil}]
  end

  test "the season panel's judge rejects a refused title for its indexer and no indexer only" do
    %{series: series} = wanted_episodes([1])
    :ok = Catalog.block_series_release(series.id, @episode, :bad_torrent, {"prowlarr", 1})

    stub_results([
      result(@episode, "one", 1, 20),
      result(@episode, "two", 2, 10),
      result(@episode, "none", nil, 5)
    ])

    assert judged_rows(series) == [
             {1, {:rejected, :blocklisted}},
             {2, :ok},
             {nil, {:rejected, :blocklisted}}
           ]
  end

  # --- helpers ------------------------------------------------------------------------------------

  defp poll_times(n) do
    start_supervised!({TvPoller, interval: 60_000, search_retry_after: 0})
    for _ <- 1..n, do: assert(:ok = TvPoller.poll())
  end

  defp wanted_episodes(numbers, media_profile \\ :standard) do
    series =
      series_fixture(%{tvdb_id: 99, monitor_strategy: :all, media_profile: media_profile})

    season = season_fixture(series)
    ids = Enum.map(numbers, &episode_fixture(season, %{episode_number: &1}).id)
    %{series: series, episode_ids: ids}
  end

  defp stub_results(results) do
    stub(Cinder.Acquisition.IndexerMock, :search_tv, fn 99, _title, 1 -> {:ok, results} end)
    stub(Cinder.Acquisition.IndexerMock, :search_tv_query, fn _query, _opts -> {:ok, results} end)
  end

  defp result(title, link, indexer_id, seeders) do
    %{
      title: title,
      size: 2_000_000_000,
      download_url: link,
      seeders: seeders,
      indexer_id: indexer_id
    }
  end

  # The season panel's rows for season 1, as {indexer id, verdict}, sorted.
  defp judged_rows(series) do
    context = Catalog.season_acquisition_context(series, 1)

    assert {:ok, judged} =
             Acquisition.judge_season(
               context,
               Acquisition.searchable_numbers(context),
               HouseholdPolicy.for_target(series)
             )

    judged.rows |> Enum.map(&{&1.release.indexer_id, &1.verdict}) |> Enum.sort()
  end

  # The indexer fields of one copy, its link origin named after the indexer.
  defp provenance(source, name, credentials_version) do
    %{
      indexer_source: source,
      indexer_name: name,
      download_url_origin:
        "https://#{name |> String.split() |> hd() |> String.downcase()}.example",
      credentials_version: credentials_version
    }
  end

  # The season panel's rows for season 1, as {indexer id, source, name, origin, credentials
  # version}, sorted.
  defp judged_provenance(series) do
    context = Catalog.season_acquisition_context(series, 1)

    assert {:ok, judged} =
             Acquisition.judge_season(
               context,
               Acquisition.searchable_numbers(context),
               HouseholdPolicy.for_target(series)
             )

    judged.rows
    |> Enum.map(
      &{&1.release.indexer_id, &1.release.indexer_source, &1.release.indexer_name,
       &1.release.download_url_origin, &1.release.credentials_version}
    )
    |> Enum.sort()
  end

  # The client answers each link with its list of answers in turn, repeating the last one; a link
  # with no answers is added. Every `add` reports its link to the test.
  defp stub_client(answers) do
    test_pid = self()
    calls = start_supervised!({Agent, fn -> answers end})
    stub(Cinder.Download.ClientMock, :find_by_operation_key, fn _key -> :not_found end)
    stub(Cinder.Download.ClientMock, :status, fn _id -> {:ok, %{state: :downloading}} end)

    stub(Cinder.Download.ClientMock, :add, fn release, _opts ->
      link = release.download_url
      send(test_pid, {:add, link})

      Agent.get_and_update(calls, &next_answer(&1, link))
    end)
  end

  defp next_answer(answers, link) do
    case Map.get(answers, link, []) do
      [] -> {{:ok, "hash-#{link}"}, answers}
      [last] -> {last, answers}
      [next | rest] -> {next, Map.put(answers, link, rest)}
    end
  end

  defp added, do: collect_added([])

  # The download ids of the grabs the catalog recorded, so a test proves the submission attached.
  defp grabbed, do: Repo.all(from g in Grab, order_by: g.id, select: g.download_id)

  defp collect_added(links) do
    receive do
      {:add, link} -> collect_added([link | links])
    after
      0 -> Enum.reverse(links)
    end
  end

  defp blocked(series_id),
    do:
      Repo.all(
        from b in BlockedRelease,
          where: b.series_id == ^series_id,
          order_by: b.id,
          select: {b.release_title, b.reason, b.indexer_id}
      )
end
