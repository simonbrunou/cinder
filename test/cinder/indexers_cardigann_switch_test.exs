defmodule Cinder.IndexersCardigannSwitchTest do
  # Switch to %{name} (#1907; #1616 rule 7): `Cinder.Indexers.update/5` with a `definition` the
  # mirror names as the replacer of the indexer's file moves it onto that file's copy, once the
  # host list the form showed (`switch_hosts_digest`) still holds. Definitions come from
  # `Cinder.DefinitionFixtures`.
  use Cinder.DataCase, async: true

  import Cinder.DefinitionFixtures

  alias Cinder.Acquisition.Indexer.Cardigann
  alias Cinder.Acquisition.Indexer.Cardigann.Jar
  alias Cinder.Acquisition.IndexerSource.Native.IndexerCookies
  alias Cinder.Audit.AdminAudit
  alias Cinder.Indexers
  alias Cinder.Indexers.{ConfiguredIndexer, Definitions}

  @base definition()
  @now ~U[2026-11-27 10:00:00.000000Z]

  defp stored(id), do: Repo.get!(ConfiguredIndexer, id)
  defp secrets(id), do: elem(Indexers.fetch_with_secrets(id), 1).secrets

  defp refusals(changeset, field) do
    for {^field, {_message, opts}} <- changeset.errors, do: opts[:validation]
  end

  defp audits(action),
    do: Repo.all(from(a in AdminAudit, where: a.action == ^action, order_by: a.id))

  # The replacer's settings: `apikey` gone, `sort`'s options without the stored "date", and a
  # new secret with a default.
  defp replacer_settings do
    settings()
    |> Enum.reject(&(&1["name"] == "apikey"))
    |> Enum.map(fn
      %{"name" => "sort"} = sort ->
        %{sort | "default" => "size", "options" => %{"size" => "Size", "seeders" => "Seeders"}}

      setting ->
        setting
    end)
    |> Kernel.++([
      %{"name" => "passkey", "type" => "text", "label" => "Passkey", "default" => "d"}
    ])
  end

  # A mirror where `newer.yml` replaces `tracker.yml`, which leaves it.
  defp replace!(extra \\ %{}) do
    newer =
      definition(
        "newer",
        Map.merge(%{"replaces" => ["tracker"], "settings" => replacer_settings()}, extra)
      )

    assert {:ok, {:loaded, _}} = apply_files([{"v11", "newer.yml", newer}])
    assert Definitions.name_status("tracker.yml") == {:replaced_by, "newer.yml"}
    newer
  end

  defp switch_attrs(row, newer, attrs),
    do:
      Map.merge(
        %{definition: "newer.yml", definition_blob_sha: blob_sha(newer), base_url: row.base_url},
        attrs
      )

  # A save that sends the digest of the list the form would show for the same input.
  defp switch(row, newer, attrs \\ %{}, secrets \\ %{}) do
    attrs = switch_attrs(row, newer, attrs)

    digest =
      case Indexers.switch_hosts(row.id, row.lock_version, attrs, secrets) do
        {:ok, hosts} -> Indexers.hosts_digest(hosts)
        {:error, _refused} -> nil
      end

    Indexers.update(
      nil,
      row.id,
      row.lock_version,
      Map.put(attrs, :switch_hosts_digest, digest),
      secrets
    )
  end

  defp indexer!(secrets \\ %{"password" => "hunter2"}, settings \\ %{"freeleech" => true}) do
    mirror!(@base)
    row = cardigann!(@base, secrets, %{settings: settings})
    stored(row.id)
  end

  describe "a Switch" do
    test "carries each value the new copy accepts, raises both counters and moves the pin" do
      row = indexer!()
      newer = replace!()

      assert {:ok, _} = switch(row, newer)

      switched = stored(row.id)
      assert switched.definition == "newer.yml"
      assert switched.settings == %{"freeleech" => true, "sort" => "size"}
      assert secrets(row.id) == %{"username" => "", "password" => "hunter2", "passkey" => "d"}
      assert switched.config_version == row.config_version + 1
      assert switched.credentials_version == row.credentials_version + 1
      assert switched.lock_version == row.lock_version + 1
      assert pin(row) == %{running: blob_sha(newer), held: nil, hold: nil}

      assert [audit] = audits("switch_configured_indexer_definition")

      # The base URL stays, so only the definition and the settings changed. The password and
      # the blank username carry; the new copy drops `apikey` and adds `passkey`.
      assert audit.detail == %{
               "fields" => ["definition", "settings"],
               "secrets" => ["apikey", "passkey"],
               "from_definition" => "tracker.yml",
               "to_definition" => "newer.yml",
               "to_copy" => blob_sha(newer)
             }

      refute inspect(audit.detail) =~ "hunter2"
    end

    test "its audit row names a base URL that changed and a secret typed over the stored one" do
      row = indexer!()
      newer = replace!(%{"links" => ["https://tracker.invalid/", "https://mirror.invalid/"]})

      assert {:ok, _} =
               switch(row, newer, %{base_url: "https://mirror.invalid/"}, %{
                 "password" => "typed",
                 "username" => "",
                 "passkey" => "d"
               })

      assert stored(row.id).base_url == "https://mirror.invalid/"
      assert [audit] = audits("switch_configured_indexer_definition")
      assert audit.detail["fields"] == ["base_url", "definition", "settings"]
      # The username typed blank over a blank one is no change.
      assert audit.detail["secrets"] == ["apikey", "passkey", "password"]
    end

    # With stored secrets that do not decrypt, a copy that declares no secret needs none typed,
    # and the Switch writes no ciphertext.
    test "a Switch of undecryptable secrets to a copy that declares none drops the ciphertext" do
      row = indexer!()
      plain = Enum.reject(settings(), &(&1["type"] in ["text", "password"]))
      newer = replace!(%{"settings" => plain})
      :ok = undecryptable!(row)

      assert {:ok, _} = switch(row, newer)
      assert stored(row.id).definition == "newer.yml"
      assert stored(row.id).secrets_ciphertext == nil
      assert [audit] = audits("switch_configured_indexer_definition")
      assert audit.detail["secrets"] == []
    end

    # The Switch decides the moved pin again, as an apply would: a newer copy of the new file
    # above the engine's folder shows on the pin at once.
    test "a newer copy of the new definition above the engine's folder holds as needs newer" do
      row = indexer!()
      newer = replace!()
      v13 = definition("newer", %{"replaces" => ["tracker"], "settings" => replacer_settings()})

      assert {:ok, {:loaded, _}} =
               apply_files([{"v11", "newer.yml", newer}, {"v13", "newer.yml", v13 <> " "}])

      assert {:ok, _} = switch(stored(row.id), newer)
      assert pin(row) == %{running: blob_sha(newer), held: nil, hold: {:needs_newer_cinder, 13}}
    end

    test "a typed value wins and a Clear box puts the new copy's default back" do
      row = indexer!(%{"password" => "hunter2", "username" => "me"})
      newer = replace!()

      assert {:ok, _} =
               switch(row, newer, %{settings: %{"freeleech" => false}}, %{
                 "passkey" => "typed",
                 "clear_username" => "true"
               })

      assert stored(row.id).settings == %{"freeleech" => false, "sort" => "size"}

      assert secrets(row.id) == %{
               "username" => "",
               "password" => "hunter2",
               "passkey" => "typed"
             }
    end

    test "a select value carries only to a select: an option named true never ticks a checkbox" do
      base =
        definition("tracker", %{
          "settings" =>
            Enum.map(settings(), fn
              %{"name" => "sort"} = sort ->
                %{sort | "options" => %{"true" => "Yes", "date" => "Date"}}

              setting ->
                setting
            end)
        })

      mirror!(base)

      row =
        cardigann!(base, %{}, %{
          definition_blob_sha: blob_sha(base),
          settings: %{"sort" => "true"}
        })

      newer =
        replace!(%{
          "settings" =>
            Enum.map(settings(), fn
              %{"name" => "sort"} ->
                %{"name" => "sort", "type" => "checkbox", "default" => "false"}

              setting ->
                setting
            end)
        })

      assert {:ok, _} = switch(stored(row.id), newer)
      assert stored(row.id).settings["sort"] == false
    end

    test "the stored login cookies of the old definition are a miss afterwards" do
      row = indexer!()
      newer = replace!()
      {:ok, indexer} = Indexers.fetch_with_secrets(row.id)
      assert IndexerCookies.store_login(indexer, Jar.new(), @now) == :written
      assert {:ok, _session} = IndexerCookies.read(indexer, @now)

      assert {:ok, _} = switch(row, newer)

      {:ok, switched} = Indexers.fetch_with_secrets(row.id)
      assert IndexerCookies.read(switched, @now) == :miss
    end

    # A search that read the row before the Switch holds the old file's settings and secrets;
    # the adapter runs none of them under the new copy.
    test "a row read before the Switch runs no request under the new copy" do
      row = indexer!()
      newer = replace!()
      {:ok, before} = Indexers.fetch_with_secrets(row.id)
      assert {:ok, _copy} = Cardigann.copy(before)

      assert {:ok, _} = switch(row, newer)

      assert Cardigann.copy(before) == {:not_supported, :definition_switched}
      {:ok, switched} = Indexers.fetch_with_secrets(row.id)
      assert {:ok, %{definition: %{id: "newer"}}} = Cardigann.copy(switched)
    end

    # One copy row stands for every file with its bytes, under the last name an apply gave it,
    # so the guard above reads the row's file name, never the copy's.
    test "a row whose file shares its bytes with another file still runs" do
      mirror!(@base, [{"v11", "zz-alias.yml", @base}])
      row = cardigann!(@base, %{"password" => "hunter2"})
      {:ok, indexer} = Indexers.fetch_with_secrets(row.id)

      assert {:ok, %{definition: %{id: "tracker"}}} = Cardigann.copy(indexer)
    end
  end

  describe "a refused Switch changes nothing" do
    setup do
      row = indexer!()
      %{row: row}
    end

    defp unchanged!(row) do
      assert stored(row.id).definition == "tracker.yml"
      assert stored(row.id).lock_version == row.lock_version
      assert pin(row).running == blob_sha(@base)
      assert audits("switch_configured_indexer_definition") == []
    end

    test "to a file that does not replace the indexer's", %{row: row} do
      # tracker.yml is still in the mirror, so newer.yml replaces nothing yet.
      newer = definition("newer", %{"replaces" => ["tracker"]})
      mirror!(@base, [{"v11", "newer.yml", newer}])

      assert {:error, changeset} = switch(row, newer)
      assert refusals(changeset, :definition) == [:fixed_at_create]
      unchanged!(row)
    end

    test "with secrets that do not decrypt, unless every secret is typed or cleared",
         %{row: row} do
      newer = replace!()
      :ok = undecryptable!(row)

      for input <- [%{}, %{"password" => "typed"}] do
        assert {:error, changeset} = switch(row, newer, %{}, input)
        assert refusals(changeset, :secrets) == [:secrets_unreadable]
        refute inspect(changeset) =~ "typed"
        unchanged!(row)
      end

      # As an Edit's "re-enter every secret" rule: a Clear box stores the new copy's default.
      every = %{"username" => "me", "password" => "typed", "clear_passkey" => "true"}
      assert {:ok, _} = switch(row, newer, %{}, every)
      assert stored(row.id).definition == "newer.yml"
      assert secrets(row.id) == %{"username" => "me", "password" => "typed", "passkey" => "d"}
    end

    test "with a base URL outside the new copy's links, even unchanged", %{row: row} do
      newer = replace!(%{"links" => ["https://moved.invalid/"]})

      assert {:error, changeset} = switch(row, newer)
      assert refusals(changeset, :base_url) == [:base_url_links]
      unchanged!(row)
    end

    test "with a hash the mirror does not hold", %{row: row} do
      replace!()

      assert {:error, changeset} = switch(row, @base)
      assert refusals(changeset, :definition) == [:definition_not_in_mirror]
      unchanged!(row)
    end

    test "with a stale lock", %{row: row} do
      newer = replace!()
      {:ok, _} = Indexers.update(nil, row.id, row.lock_version, %{name: "Renamed"})

      assert {:error, changeset} = switch(row, newer)
      assert {_message, [stale: true]} = changeset.errors[:lock_version]
      assert stored(row.id).definition == "tracker.yml"
      assert pin(row).running == blob_sha(@base)
    end

    # The save reads the host list again and refuses when it is not the one the form showed:
    # here the form showed none, while the typed secret fills a host of the new copy.
    test "when the host list differs from the one the form showed", %{row: row} do
      newer = replace!(%{"description" => "https://{{ .Config.passkey }}.x.invalid/"})
      attrs = switch_attrs(row, newer, %{})
      secret_input = %{"passkey" => "typed"}

      assert {:ok, [_ | _] = hosts} =
               Indexers.switch_hosts(row.id, row.lock_version, attrs, secret_input)

      for digest <- [Indexers.hosts_digest([]), nil] do
        attrs = Map.put(attrs, :switch_hosts_digest, digest)

        assert {:error, changeset} =
                 Indexers.update(nil, row.id, row.lock_version, attrs, secret_input)

        assert refusals(changeset, :definition) == [:switch_hosts_changed]
        refute inspect(changeset) =~ "typed"
        unchanged!(row)
      end

      attrs = Map.put(attrs, :switch_hosts_digest, Indexers.hosts_digest(hosts))
      assert {:ok, _} = Indexers.update(nil, row.id, row.lock_version, attrs, secret_input)
    end
  end

  describe "the rendered copy's hash on an edit" do
    test "an edit from the running copy's form saves; one from a copy it left is refused" do
      row = indexer!(%{})
      moved = definition("tracker", %{"name" => "Renamed upstream"})
      mirror!(moved)
      assert pin(row).running == blob_sha(moved)

      assert {:error, changeset} =
               Indexers.update(nil, row.id, row.lock_version, %{
                 name: "Mine",
                 definition_blob_sha: blob_sha(@base)
               })

      assert refusals(changeset, :definition) == [:definition_changed]
      assert stored(row.id).name == row.name

      assert {:ok, _} =
               Indexers.update(nil, row.id, row.lock_version, %{
                 name: "Mine",
                 definition_blob_sha: blob_sha(moved)
               })
    end
  end
end
