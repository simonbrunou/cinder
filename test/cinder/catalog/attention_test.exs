defmodule Cinder.Catalog.AttentionTest do
  use ExUnit.Case, async: true

  alias Cinder.Catalog.{Attention, Grab, GrabFile, Movie, Series}

  # The agreed classification, one row per movie state:
  # {state name, movie fields, phase, reason, badge, offered actions}.
  @movie_states [
    {:requested, %{status: :requested}, :active, nil, :requested, [:cancel]},
    {:searching, %{status: :searching}, :active, nil, :searching, [:cancel]},
    {:anime_held_requested,
     %{status: :requested, anime_hold_reason: "subtitle_language_required"}, :attention,
     :anime_hold, :anime_hold, [:cancel]},
    {:anime_held_searching,
     %{status: :searching, anime_hold_reason: "original_language_required"}, :attention,
     :anime_hold, :anime_hold, [:cancel]},
    {:downloading, %{status: :downloading}, :active, nil, :downloading, [:cancel]},
    {:downloaded, %{status: :downloaded}, :active, nil, :downloaded, [:cancel]},
    {:upgrading, %{status: :upgrading}, :active, nil, :upgrading, [:cancel_upgrade]},
    {:no_match, %{status: :no_match}, :attention, :no_match, :no_match, [:retry, :manual_search]},
    {:search_failed, %{status: :search_failed}, :attention, :search_failed, :search_failed,
     [:retry, :manual_search]},
    {:import_failed, %{status: :import_failed}, :attention, :import_failed, :import_failed,
     [:retry, :manual_search]},
    {:download_verification_hold, %{status: :import_failed, verification_hold_origin: :download},
     :attention, :verification_hold, :verification_hold, [:retry, :cancel]},
    {:upgrade_verification_hold, %{status: :import_failed, verification_hold_origin: :upgrade},
     :attention, :verification_hold, :verification_hold, [:retry, :cancel_upgrade]},
    {:available, %{status: :available}, :idle, nil, :available, [:manual_search]},
    {:cancelled, %{status: :cancelled}, :idle, nil, :cancelled, []}
  ]

  describe "classify/1 on a movie" do
    for {name, fields, phase, reason, badge, actions} <- @movie_states do
      test "#{name}: #{phase}, offers #{inspect(actions)}" do
        movie = struct(Movie, unquote(Macro.escape(fields)))

        assert %Attention{
                 phase: unquote(phase),
                 reason: unquote(reason),
                 badge: unquote(badge),
                 actions: unquote(actions)
               } = Attention.classify(movie)
      end
    end

    test "every movie status is classified" do
      covered = @movie_states |> Enum.map(fn {_, fields, _, _, _, _} -> fields.status end)
      assert Enum.sort(Enum.uniq(covered)) == Enum.sort(Ecto.Enum.values(Movie, :status))
    end

    test "only an anime hold names a fix" do
      for {name, fields, _, reason, _, _} <- @movie_states, reason != :anime_hold do
        assert Attention.classify(struct(Movie, fields)).fix == nil, "#{name}"
      end
    end
  end

  # #772: only the operator clears an anime hold, so every hold reason needs attention and names
  # the fix that clears it: {hold reason, fix}.
  @anime_hold_fixes [
    {"original_language_required", :detail_page},
    {"subtitle_language_required", :subtitle_settings},
    # A reason this Cinder does not know (written by another version) still counts; switching the
    # profile on the detail page clears any anime hold.
    {"unknown_reason", :detail_page}
  ]

  describe "classify/1 on an anime hold" do
    for {reason, fix} <- @anime_hold_fixes do
      test "#{reason} on a movie needs attention and names #{fix}" do
        movie = %Movie{status: :searching, anime_hold_reason: unquote(reason)}

        assert %Attention{
                 phase: :attention,
                 reason: :anime_hold,
                 badge: :anime_hold,
                 actions: [:cancel],
                 fix: unquote(fix)
               } = Attention.classify(movie)
      end

      test "#{reason} on a series needs attention and names #{fix}" do
        series = %Series{anime_hold_reason: unquote(reason)}

        assert %Attention{
                 phase: :attention,
                 reason: :anime_hold,
                 badge: :anime_hold,
                 actions: [],
                 fix: unquote(fix)
               } = Attention.classify(series)
      end
    end

    # The sweep reads episode monitoring, not the series flag: a series adopted with :none that then
    # had one season monitored is still searched, so its hold counts.
    test "a held series counts whatever its series-level monitored flag" do
      series = %Series{monitored: false, anime_hold_reason: "subtitle_language_required"}
      assert %Attention{phase: :attention, fix: :subtitle_settings} = Attention.classify(series)
    end

    test "a series with no hold is idle" do
      assert %Attention{phase: :idle, reason: nil, badge: nil, actions: [], fix: nil} =
               Attention.classify(%Series{anime_hold_reason: nil})
    end
  end

  @undecided %GrabFile{decision: nil}
  @decided %GrabFile{decision: :fold}

  # {state name, grab fields, phase, reason, badge, offered actions}.
  @grab_states [
    {:downloading, %{mapping_status: :resolved, grab_files: []}, :active, nil, :downloading,
     [:cancel]},
    {:downloaded, %{mapping_status: :resolved, content_path: "/dl/x", grab_files: [@decided]},
     :active, nil, :downloaded, [:cancel]},
    {:needs_mapping, %{mapping_status: :needs_mapping, grab_files: [@undecided]}, :attention,
     :needs_mapping, :needs_mapping, [:retry_mapping, :discard]},
    {:verification_blocked, %{mapping_status: :verification_blocked, content_path: "/dl/x"},
     :attention, :verification_blocked, :verification_blocked,
     [:retry_verification, :import_anyway, :cancel]},
    {:residual_files,
     %{mapping_status: :resolved, content_path: "/dl/x", grab_files: [@undecided]}, :attention,
     :residual_files, :needs_mapping, [:cancel]}
  ]

  describe "classify/1 on a grab" do
    for {name, fields, phase, reason, badge, actions} <- @grab_states do
      test "#{name}: #{phase}, offers #{inspect(actions)}" do
        grab = struct(Grab, unquote(Macro.escape(fields)))

        assert %Attention{
                 phase: unquote(phase),
                 reason: unquote(reason),
                 badge: unquote(badge),
                 actions: unquote(actions)
               } = Attention.classify(grab)
      end
    end

    test "an unloaded grab_files association classifies as no residual hold" do
      assert %Attention{phase: :active, reason: nil} =
               Attention.classify(%Grab{mapping_status: :resolved})
    end
  end

  test "offers?/2 answers from the same classification" do
    assert Attention.offers?(%Movie{status: :no_match}, :retry)
    refute Attention.offers?(%Movie{status: :downloading}, :retry)
    assert Attention.offers?(%Grab{mapping_status: :needs_mapping}, :discard)
    refute Attention.offers?(%Grab{mapping_status: :needs_mapping}, :cancel)
  end
end
