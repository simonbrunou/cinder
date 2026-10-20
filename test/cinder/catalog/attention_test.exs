defmodule Cinder.Catalog.AttentionTest do
  use ExUnit.Case, async: true

  alias Cinder.Catalog.{Attention, Grab, GrabFile, Movie}

  # The agreed classification, one row per movie state:
  # {state name, movie fields, phase, reason, badge, offered actions}.
  @movie_states [
    {:requested, %{status: :requested}, :active, nil, :requested, [:cancel]},
    {:searching, %{status: :searching}, :active, nil, :searching, [:cancel]},
    {:anime_held_requested,
     %{status: :requested, anime_hold_reason: "subtitle_language_required"}, :waiting,
     :anime_hold, :anime_hold, [:cancel]},
    {:anime_held_searching,
     %{status: :searching, anime_hold_reason: "original_language_required"}, :waiting,
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
