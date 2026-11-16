defmodule Cinder.Requests.TargetTypesTest do
  # #811: `Cinder.Requests.Approval` owns which target types an approval can create and which
  # profile kind each target type uses. These tests fence that owner and every public lookup that
  # reads it; `CinderWeb.ApiControllerTest` fences the API's payload check against the same list.
  use ExUnit.Case, async: true

  alias Cinder.Requests
  alias Cinder.Requests.{Approval, Request}

  @unknown "podcast"

  describe "approvable types" do
    test "are the Request target types adapter/1 answers {:ok, _} for, and no other" do
      approvable = Approval.approvable_types()

      for type <- Request.target_types() ++ [@unknown] do
        target = %{target_type: type}

        if type in approvable do
          result = Approval.adapter(target)
          assert match?({:ok, _adapter}, result), "#{type} has no adapter: #{inspect(result)}"
          {:ok, adapter} = result
          assert Requests.approvable_target?(target)
          Code.ensure_loaded!(adapter)

          for {callback, arity} <- [prepare: 2, create: 2, publish: 2] do
            assert function_exported?(adapter, callback, arity),
                   "#{inspect(adapter)} lacks #{callback}/#{arity}"
          end
        else
          assert Approval.adapter(target) == {:error, :unsupported_target}
          refute Requests.approvable_target?(target)
        end
      end

      assert Approval.adapter(%{}) == {:error, :unsupported_target}
      assert Requests.approvable_types() == approvable
      assert approvable == Enum.sort(approvable)
      assert approvable -- Request.target_types() == []
    end

    test "leave out the legacy series and episode types, which the schema still loads" do
      for type <- ["series", "episode"] do
        assert type in Request.target_types()
        refute type in Approval.approvable_types()
      end
    end
  end

  describe "profile kind" do
    # `request_kind/1`'s answers before #811 are the reference (Agent Brief, Desired behavior).
    @table [
      {%{target_type: "movie"}, :movies},
      {%{target_type: "season"}, :tv},
      {%{target_type: "series"}, :tv},
      {%{target_type: "episode"}, :tv},
      {%{target_type: "book", media_kind: :ebook}, :ebook},
      {%{target_type: "book", media_kind: :audiobook}, :audiobook},
      {%{target_type: "book", media_kind: "ebook"}, nil},
      {%{target_type: "book", media_kind: :movies}, nil},
      {%{target_type: "book", media_kind: nil}, nil},
      {%{target_type: "book"}, nil},
      {%{target_type: @unknown}, nil},
      {%{}, nil}
    ]

    test "the table covers every Request target type" do
      covered = for {%{target_type: type}, _kind} <- @table, uniq: true, do: type
      assert Request.target_types() -- covered == []
    end

    test "every public lookup answers the same kind for each target" do
      for {target, kind} <- @table do
        assert Approval.profile_kind(target) == kind, "Approval: #{inspect(target)}"
        assert Requests.profile_kind(target) == kind, "Requests: #{inspect(target)}"

        assert CinderWeb.RequestHelpers.profile_kind(target) == kind,
               "RequestHelpers: #{inspect(target)}"
      end
    end

    test "a Request struct answers like its attrs map" do
      for {target, kind} <- @table, Map.has_key?(target, :target_type) do
        assert Approval.profile_kind(struct(Request, target)) == kind, inspect(target)
      end
    end

    test "the views' profile list holds only the target's kind" do
      profiles =
        for {kind, id} <- Enum.with_index([:movies, :tv, :ebook, :audiobook], 1),
            do: %{id: id, kind: kind}

      for {target, kind} <- @table do
        assert CinderWeb.RequestHelpers.profiles_for(profiles, target) ==
                 Enum.filter(profiles, &(&1.kind == kind)),
               inspect(target)
      end
    end
  end
end
