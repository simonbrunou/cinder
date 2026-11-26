defmodule Cinder.IndexersCardigannTest do
  # Cardigann rows in `Cinder.Indexers` (#1668; #1620 points 2, 3 and 8): a create pins the
  # copy the form rendered and stores every setting's effective value; an edit checks against
  # the running copy. Definitions come from `Cinder.DefinitionFixtures`.
  use Cinder.DataCase, async: true

  import Cinder.DefinitionFixtures

  alias Cinder.Indexers
  alias Cinder.Indexers.{ConfiguredIndexer, Definitions}
  alias Cinder.Indexers.Definitions.{Loader, Pin}

  @base definition()

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        name: "Cardigann #{System.unique_integer([:positive])}",
        type: :cardigann,
        definition: "tracker.yml",
        definition_blob_sha: blob_sha(@base),
        base_url: link()
      },
      overrides
    )
  end

  defp refusals(changeset, field) do
    for {^field, {message, opts}} <- changeset.errors, do: {message, opts[:validation]}
  end

  defp stored(id), do: Repo.get!(ConfiguredIndexer, id)
  defp secrets(id), do: elem(Indexers.fetch_with_secrets(id), 1).secrets

  setup do
    mirror!(@base)
    :ok
  end

  describe "create/3" do
    test "pins the copy and stores every declared setting's effective value" do
      assert {:ok, row} =
               Indexers.create(nil, attrs(%{settings: %{"freeleech" => true}}), %{
                 "password" => "hunter2"
               })

      assert pin(row) == %{running: blob_sha(@base), held: nil, hold: nil}
      assert stored(row.id).settings == %{"freeleech" => true, "sort" => "date"}

      assert secrets(row.id) == %{
               "username" => "",
               "password" => "hunter2",
               "apikey" => "public-key"
             }
    end

    test "a blank secret stores the copy's default" do
      {:ok, row} = Indexers.create(nil, attrs(), %{"apikey" => "   ", "password" => ""})
      assert secrets(row.id) == %{"username" => "", "password" => "", "apikey" => "public-key"}
    end

    test "a checkbox takes a boolean or its text, and a select one of its options" do
      {:ok, row} =
        Indexers.create(nil, attrs(%{settings: %{"freeleech" => "true", "sort" => "size"}}))

      assert stored(row.id).settings == %{"freeleech" => true, "sort" => "size"}
    end

    test "refusals, each with nothing stored" do
      for {overrides, secrets, field, validation} <- [
            {%{settings: %{"sort" => "seeders"}}, %{}, :settings, :select_option},
            {%{settings: %{"freeleech" => "yes"}}, %{}, :settings, :settings_values},
            {%{settings: %{"nosuch" => true}}, %{}, :settings, :settings_keys},
            {%{settings: %{"password" => "plain"}}, %{}, :settings, :settings_keys},
            {%{settings: %{"info" => "x"}}, %{}, :settings, :settings_keys},
            {%{}, %{"nosuch" => "x"}, :secrets, :secret_fields},
            {%{}, %{"freeleech" => "true"}, :secrets, :secret_fields},
            {%{base_url: "https://elsewhere.invalid/"}, %{}, :base_url, :base_url_links},
            {%{definition_blob_sha: blob_sha("other bytes")}, %{}, :definition,
             :definition_not_in_mirror},
            {%{definition: "missing.yml"}, %{}, :definition, :definition_not_in_mirror},
            {%{definition: nil}, %{}, :definition, :required}
          ] do
        assert {:error, changeset} = Indexers.create(nil, attrs(overrides), secrets)

        assert {field, validation, refusals(changeset, field)} ==
                 {field, validation, [{refusal_message(validation), validation}]}
      end

      assert Repo.aggregate(ConfiguredIndexer, :count) == 0
      assert Repo.aggregate(Pin, :count) == 0
    end

    test "a hash the mirror lost is refused" do
      mirror!(definition("tracker", %{"name" => "Moved on"}))

      assert {:error, changeset} = Indexers.create(nil, attrs())
      assert refusals(changeset, :definition) == [{"is invalid", :definition_not_in_mirror}]
    end

    test "a copy that fails to load is refused; one that reads not supported pins" do
      broken = failing("create")
      mirror!(broken)

      assert {:error, changeset} =
               Indexers.create(nil, attrs(%{definition_blob_sha: blob_sha(broken)}))

      assert refusals(changeset, :definition) == [{"is invalid", :definition_fails}]

      unsupported = definition("tracker-ns")
      mirror!(unsupported)

      assert {:ok, row} =
               Indexers.create(nil, attrs(%{definition_blob_sha: blob_sha(unsupported)}))

      assert Definitions.indexer_codes() == %{row.id => {:not_supported, :html_search}}
    end
  end

  defp refusal_message(:required), do: "can't be blank"
  defp refusal_message(_validation), do: "is invalid"

  defp create!(secrets \\ %{"password" => "hunter2"}) do
    {:ok, row} = Indexers.create(nil, attrs(), secrets)
    stored(row.id)
  end

  defp edit(row, attrs, secrets \\ %{}),
    do: Indexers.update(nil, row.id, row.lock_version, attrs, secrets)

  describe "update/5 on a Cardigann row" do
    test "config_version and credentials_version per field" do
      second = definition("tracker", %{"links" => [link(), "https://second.invalid/"]})
      mirror!(second)

      for {label, attrs, secrets, config, credentials} <- [
            {"base URL", %{base_url: "https://second.invalid/"}, %{}, 1, 1},
            {"checkbox", %{settings: %{"freeleech" => true}}, %{}, 1, 0},
            {"select", %{settings: %{"sort" => "size"}}, %{}, 1, 0},
            {"secret set", %{}, %{"username" => "me"}, 1, 1},
            {"secret clear", %{}, %{"clear_password" => "true"}, 1, 1},
            {"name", %{name: "Renamed #{System.unique_integer([:positive])}"}, %{}, 0, 0},
            {"same select", %{settings: %{"sort" => "date"}}, %{}, 0, 0}
          ] do
        {:ok, row} =
          Indexers.create(nil, attrs(%{definition_blob_sha: blob_sha(second)}), %{
            "password" => "hunter2"
          })

        row = stored(row.id)
        assert {:ok, _updated} = edit(row, attrs, secrets)
        after_edit = stored(row.id)

        assert {label, after_edit.config_version - row.config_version,
                after_edit.credentials_version - row.credentials_version} ==
                 {label, config, credentials}
      end
    end

    test "a clear reverts a secret to the running copy's default, or empties it" do
      row = create!(%{"password" => "hunter2", "apikey" => "private-key"})

      assert {:ok, _} = edit(row, %{}, %{"clear_password" => "true", "clear_apikey" => "on"})
      assert secrets(row.id) == %{"username" => "", "password" => "", "apikey" => "public-key"}
    end

    test "an edit merges settings into the stored ones" do
      row = create!()
      assert {:ok, _} = edit(row, %{settings: %{"sort" => "size"}})
      assert stored(row.id).settings == %{"freeleech" => false, "sort" => "size"}
    end

    test "a base URL outside the running copy's links is refused" do
      row = create!()
      assert {:error, changeset} = edit(row, %{base_url: "https://elsewhere.invalid/"})
      assert refusals(changeset, :base_url) == [{"is invalid", :base_url_links}]
    end

    test "an edit checks against the running copy, never the mirror's" do
      row = create!()

      # The update adds a setting and a host, so it is held for this indexer with credentials.
      mirror!(
        definition("tracker", %{
          "description" => "https://new.invalid/",
          "settings" =>
            settings() ++ [%{"name" => "newflag", "type" => "checkbox", "default" => "true"}]
        })
      )

      assert %{hold: :hosts} = pin(row)
      assert {:error, changeset} = edit(row, %{settings: %{"newflag" => true}})
      assert refusals(changeset, :settings) == [{"is invalid", :settings_keys}]
    end

    test "a stored secret is never demoted after an update retypes its setting" do
      # apikey at its public default: no credentials, so the retype applies.
      row = create!(%{})

      retyped =
        Enum.map(settings(), fn
          %{"name" => "apikey"} = setting ->
            Map.merge(setting, %{
              "type" => "select",
              "options" => %{"public-key" => "Public", "other-key" => "Other"}
            })

          setting ->
            setting
        end)

      mirror!(definition("tracker", %{"settings" => retyped}))
      assert %{hold: nil} = pin(row)
      refute pin(row).running == blob_sha(@base)

      assert {:error, changeset} = edit(row, %{settings: %{"apikey" => "other-key"}})
      assert refusals(changeset, :settings) == [{"is invalid", :settings_keys}]

      assert {:error, changeset} = edit(row, %{}, %{"apikey" => "outside"})
      assert refusals(changeset, :secrets) == [{"is invalid", :select_option}]

      assert {:ok, _} = edit(row, %{}, %{"apikey" => "other-key"})
      assert secrets(row.id)["apikey"] == "other-key"
      refute Map.has_key?(stored(row.id).settings, "apikey")
    end

    test "a plain key whose setting an update retyped to info is refused" do
      row = create!(%{})

      retyped =
        Enum.map(settings(), fn
          %{"name" => "freeleech"} ->
            %{"name" => "freeleech", "type" => "info", "label" => "Gone"}

          setting ->
            setting
        end)

      mirror!(definition("tracker", %{"settings" => retyped}))
      refute pin(row).running == blob_sha(@base)

      assert {:error, changeset} = edit(row, %{settings: %{"freeleech" => true}})
      assert refusals(changeset, :settings) == [{"is invalid", :settings_keys}]
    end

    test "a toggle and a rename work when the running copy no longer loads; a setting edit is refused" do
      row = create!()
      :ok = Definitions.store_results([{blob_sha(@base), {:error, :not_utf8}}])

      # The loader itself still parses the bytes, so make the stored copy unparseable.
      assert {:ok, _} = Loader.load(@base)
      Repo.update_all(Cinder.Indexers.Definitions.Copy, set: [bytes: failing("now")])

      assert {:ok, row} = Indexers.set_enabled(nil, row.id, row.lock_version, false)
      assert {:ok, row} = edit(row, %{name: "Renamed"})
      assert {:error, changeset} = edit(row, %{settings: %{"sort" => "size"}})
      assert refusals(changeset, :definition) == [{"is invalid", :definition_fails}]
    end

    test "a row with no pin still toggles" do
      row =
        Repo.insert!(%ConfiguredIndexer{
          name: "Unpinned",
          type: :cardigann,
          definition: "tracker.yml",
          base_url: link()
        })

      assert {:ok, _} = Indexers.set_enabled(nil, row.id, row.lock_version, false)
    end

    test "an edit that changes the type or the definition is still refused" do
      row = create!()
      assert {:error, changeset} = edit(row, %{definition: "other.yml"})
      assert refusals(changeset, :definition) == [{"is invalid", :fixed_at_create}]
      assert {:error, changeset} = edit(row, %{type: :torznab})
      assert refusals(changeset, :type) == [{"is invalid", :fixed_at_create}]
    end
  end

  describe "cardigann_indexers/0" do
    test "reads every Cardigann row, enabled or not, with its values or :undecryptable" do
      on = create!()
      {:ok, _} = Indexers.set_enabled(nil, on.id, on.lock_version, false)
      locked = create!()
      :ok = undecryptable!(locked)

      assert [
               {%{id: id_on}, %{plain: plain, secrets: %{"password" => "hunter2"}}},
               {%{id: id_locked}, :undecryptable}
             ] = Indexers.cardigann_indexers()

      assert {id_on, id_locked, plain} ==
               {on.id, locked.id, %{"freeleech" => false, "sort" => "date"}}
    end
  end
end
