defmodule Cinder.Indexers.DefinitionHoldsTest do
  # Each Cardigann configured indexer's running and held copies through `apply_set/2`,
  # `store_results/1` and `accept/3` (#1668; #1616 rules 5, 6, 8 and 13, #1620 points 3, 10 and
  # 12). Every definition is written for Cinder (`Cinder.DefinitionFixtures`), and the load
  # verdicts come from its `check/1`.
  #
  # Not async: the deletion race deletes a row from the apply's own check tasks, which reach the
  # test's sandbox connection only in shared mode.
  use Cinder.DataCase, async: false

  import Cinder.DefinitionFixtures

  alias Cinder.Audit.AdminAudit
  alias Cinder.Indexers
  alias Cinder.Indexers.ConfiguredIndexer
  alias Cinder.Indexers.Definitions
  alias Cinder.Indexers.Definitions.{Copy, Loader, Pin}

  @base definition()

  # The four indexer states of the hold table, each a configured indexer on `@base`: no
  # credentials (every secret at its default), a secret typed equal to its public default, a
  # secret that differs from its default, and secrets that do not decrypt.
  defp four_indexers do
    secret = cardigann!(@base, %{"password" => "hunter2"})
    locked = cardigann!(@base, %{"password" => "hunter2"})
    :ok = undecryptable!(locked)

    %{
      public: cardigann!(@base),
      default_secret: cardigann!(@base, %{"apikey" => "public-key"}),
      secret: secret,
      undecryptable: locked
    }
  end

  defp settings_without(name), do: Enum.reject(settings(), &(&1["name"] == name))

  defp retyped(name, type),
    do: Enum.map(settings(), &if(&1["name"] == name, do: %{&1 | "type" => type}, else: &1))

  @newer definition("tracker", %{"name" => "For a newer Cinder"})

  # Each candidate of the hold table: the answer files that carry it, the candidate copy, and
  # what it makes each indexer state do. `:apply` and `:keep` name the running copy; any other
  # value is the hold's reason, with the candidate held unless it needs a newer Cinder.
  defp candidates do
    [
      loads: {definition("tracker", %{"name" => "Renamed"}), [], :apply, :apply},
      fails: {failing("candidate"), [], :fails, :fails},
      not_supported:
        {definition("tracker-ns"), [], {:not_supported, :html_search},
         {:not_supported, :html_search}},
      needs_newer_cinder:
        {@base, [{"v13", "tracker.yml", @newer}], {:needs_newer_cinder, 13},
         {:needs_newer_cinder, 13}},
      new_host:
        {definition("tracker", %{"description" => "Mirror at https://new.invalid/"}), [], :apply,
         :hosts},
      unknown_host:
        {definition("tracker", %{
           "description" => "At https://{{ if .Config.freeleech }}fl{{ end }}.invalid/"
         }), [], :apply, :hosts},
      certificates:
        {definition("tracker", %{"certificates" => ["AB:CD"]}), [], :apply, :certificates},
      removed_credential:
        {definition("tracker", %{"settings" => settings_without("password")}), [], :apply,
         :removed_credential},
      retyped_credential:
        {definition("tracker", %{"settings" => retyped("password", "text")}), [], :apply,
         :retyped_credential}
    ]
  end

  defp expected_pin(:apply, candidate), do: %{running: blob_sha(candidate), held: nil, hold: nil}

  defp expected_pin({:needs_newer_cinder, _version} = newer, _candidate),
    do: %{running: blob_sha(@base), held: nil, hold: newer}

  defp expected_pin(reason, candidate),
    do: %{running: blob_sha(@base), held: blob_sha(candidate), hold: reason}

  describe "the hold table" do
    for {name, _cell} <- [
          loads: nil,
          fails: nil,
          not_supported: nil,
          needs_newer_cinder: nil,
          new_host: nil,
          unknown_host: nil,
          certificates: nil,
          removed_credential: nil,
          retyped_credential: nil
        ] do
      test "candidate #{name} by every indexer state" do
        {candidate, more, public, secret} = Keyword.fetch!(candidates(), unquote(name))
        mirror!(@base)
        indexers = four_indexers()
        mirror!(candidate, more)

        # Every update of an indexer whose secrets do not decrypt is held under its own reason;
        # a copy only a newer Cinder reads is no update this one can run.
        undecryptable =
          if match?({:needs_newer_cinder, _}, public), do: public, else: :undecryptable

        expected = [
          public: expected_pin(public, candidate),
          default_secret: expected_pin(public, candidate),
          secret: expected_pin(secret, candidate),
          undecryptable: expected_pin(undecryptable, candidate)
        ]

        assert for({state, _} <- expected, do: {state, pin(indexers[state])}) == expected
      end
    end
  end

  describe "later answers" do
    test "a later copy that passes applies and clears the hold" do
      mirror!(@base)
      indexer = cardigann!(@base, %{"password" => "hunter2"})
      hosted = definition("tracker", %{"description" => "https://new.invalid/"})
      mirror!(hosted)
      assert pin(indexer).hold == :hosts

      fixed = definition("tracker", %{"name" => "Fixed"})
      mirror!(fixed)
      assert pin(indexer) == %{running: blob_sha(fixed), held: nil, hold: nil}
    end

    # A stored secret outlives the setting an applied update removed: the running copy sends it
    # nowhere, and a later copy that declares it again would.
    test "a copy that brings back a public setting still at its default applies" do
      mirror!(@base)
      public = cardigann!(@base)
      without = definition("tracker", %{"settings" => settings_without("apikey")})
      mirror!(without)
      assert pin(public) == %{running: blob_sha(without), held: nil, hold: nil}

      back = definition("tracker", %{"name" => "Back"})
      mirror!(back)
      assert pin(public) == %{running: blob_sha(back), held: nil, hold: nil}
    end

    test "a copy that brings back a secret an accepted removal left is held as retyped" do
      mirror!(@base)
      indexer = cardigann!(@base, %{"password" => "hunter2"})
      without = definition("tracker", %{"settings" => settings_without("password")})
      mirror!(without)
      assert pin(indexer).hold == :removed_credential
      :ok = Definitions.accept(indexer.id, blob_sha(without), nil)

      # The running copy no longer declares the password, so a new host alone applies.
      hosted =
        definition("tracker", %{
          "settings" => settings_without("password"),
          "description" => "https://new.invalid/"
        })

      mirror!(hosted)
      assert pin(indexer) == %{running: blob_sha(hosted), held: nil, hold: nil}

      back = definition("tracker", %{"name" => "Back"})
      mirror!(back)

      assert pin(indexer) ==
               %{running: blob_sha(hosted), held: blob_sha(back), hold: :retyped_credential}
    end

    test "an indexer with another credential holds a copy that brings back a left secret" do
      mirror!(@base)
      indexer = cardigann!(@base, %{"username" => "alice", "password" => "hunter2"})
      without = definition("tracker", %{"settings" => settings_without("password")})
      mirror!(without)
      :ok = Definitions.accept(indexer.id, blob_sha(without), nil)

      back = definition("tracker", %{"name" => "Back"})
      mirror!(back)

      assert pin(indexer) ==
               %{running: blob_sha(without), held: blob_sha(back), hold: :retyped_credential}
    end

    test "a running copy that no longer parses holds a loading copy on hosts for a secret" do
      mirror!(@base)
      secret = cardigann!(@base, %{"password" => "hunter2"})
      running = Repo.get!(Pin, secret.id).running_copy_id
      Repo.update_all(from(c in Copy, where: c.id == ^running), set: [bytes: failing("now")])

      renamed = definition("tracker", %{"name" => "Renamed"})
      mirror!(renamed)

      assert pin(secret) == %{running: blob_sha(@base), held: blob_sha(renamed), hold: :hosts}
    end

    test "a later copy that is held replaces the held copy" do
      mirror!(@base)
      indexer = cardigann!(@base, %{"password" => "hunter2"})
      mirror!(definition("tracker", %{"description" => "https://new.invalid/"}))

      certified = definition("tracker", %{"certificates" => ["AB:CD"]})
      mirror!(certified)

      assert pin(indexer) ==
               %{running: blob_sha(@base), held: blob_sha(certified), hold: :certificates}
    end

    test "a mirror copy equal to the running copy clears the hold" do
      mirror!(@base)
      indexer = cardigann!(@base, %{"password" => "hunter2"})
      mirror!(failing("later"))
      assert pin(indexer).hold == :fails

      mirror!(@base)
      assert pin(indexer) == %{running: blob_sha(@base), held: nil, hold: nil}
    end

    test "a name the mirror no longer holds keeps the running copy and clears the hold" do
      mirror!(@base)
      indexer = cardigann!(@base, %{"password" => "hunter2"})
      mirror!(failing("later"))

      assert {:ok, _state} = apply_files([])
      assert pin(indexer) == %{running: blob_sha(@base), held: nil, hold: nil}
      assert Definitions.indexer_codes() == %{indexer.id => :removed_upstream}
    end

    test "a copy that applies while a newer folder holds another copy reads needs a newer Cinder" do
      mirror!(@base)
      indexer = cardigann!(@base)
      renamed = definition("tracker", %{"name" => "Renamed"})
      mirror!(renamed, [{"v13", "tracker.yml", @newer}])

      assert pin(indexer) == %{
               running: blob_sha(renamed),
               held: nil,
               hold: {:needs_newer_cinder, 13}
             }
    end

    test "a name only a folder above the engine holds keeps the running copy, needing a newer Cinder" do
      mirror!(@base)
      indexer = cardigann!(@base, %{"password" => "hunter2"})

      assert {:ok, _state} = apply_files([{"v13", "tracker.yml", @newer}])

      assert pin(indexer) ==
               %{running: blob_sha(@base), held: nil, hold: {:needs_newer_cinder, 13}}

      assert Definitions.indexer_codes() == %{indexer.id => {:held, {:needs_newer_cinder, 13}}}
    end

    @tag :capture_log
    test "a copy with no load result under the current fingerprint changes nothing" do
      mirror!(@base)
      indexer = cardigann!(@base, %{"password" => "hunter2"})
      mirror!(failing("held"))
      before = pin(indexer)

      # A check that times out stores no result for the new copy.
      unchecked = definition("tracker", %{"name" => "Unchecked"})

      assert {:ok, _state} =
               apply_files([{"v11", "tracker.yml", unchecked}],
                 check: fn _bytes -> Process.sleep(:infinity) end,
                 timeout_ms: 50
               )

      assert pin(indexer) == before
    end

    test "an apply leaves config_version, credentials_version and the row as they were" do
      mirror!(@base)
      indexer = cardigann!(@base)
      before = Repo.get!(ConfiguredIndexer, indexer.id)

      mirror!(
        definition("tracker", %{
          "name" => "Renamed",
          "settings" =>
            settings() ++
              [
                %{
                  "name" => "newflag",
                  "type" => "checkbox",
                  "label" => "New",
                  "default" => "true"
                }
              ]
        })
      )

      assert pin(indexer).running != blob_sha(@base)
      assert Repo.get!(ConfiguredIndexer, indexer.id) == before
    end
  end

  describe "store_results/1, the re-check" do
    test "a running copy whose new result fails reads no longer loads" do
      mirror!(@base)
      indexer = cardigann!(@base)

      assert :ok = Definitions.store_results([{blob_sha(@base), {:error, :not_utf8}}])
      assert Definitions.indexer_codes() == %{indexer.id => {:no_longer_loads, :not_utf8}}
    end

    test "a held copy that now loads applies" do
      mirror!(@base)
      indexer = cardigann!(@base, %{"password" => "hunter2"})
      later = definition("tracker-ns")
      mirror!(later)
      assert pin(indexer).hold == {:not_supported, :html_search}

      {:ok, loaded} = Loader.load(later)

      assert :ok =
               Definitions.store_results([{blob_sha(later), {:ok, %{loaded | unsupported: []}}}])

      assert pin(indexer) == %{running: blob_sha(later), held: nil, hold: nil}
    end
  end

  describe "rows with no pin" do
    test "an apply and the state codes leave out a Cardigann row with no pin" do
      mirror!(@base)

      unpinned =
        Repo.insert!(%ConfiguredIndexer{
          name: "Unpinned",
          type: :cardigann,
          definition: "tracker.yml",
          base_url: link()
        })

      pinned = cardigann!(@base)
      renamed = definition("tracker", %{"name" => "Renamed"})
      mirror!(renamed)

      assert pin(pinned).running == blob_sha(renamed)
      refute Repo.get(Pin, unpinned.id)
      refute Map.has_key?(Definitions.indexer_codes(), unpinned.id)
    end
  end

  describe "deletion" do
    test "deleting an indexer removes its pin; the next apply deletes the copies only it used" do
      mirror!(@base)
      secret = cardigann!(@base, %{"password" => "hunter2"})
      public = cardigann!(@base)

      # `public` runs v2; `secret` keeps @base and holds v2 back.
      v2 = definition("tracker", %{"certificates" => ["AB:CD"]})
      mirror!(v2)
      assert pin(public).running == blob_sha(v2)
      assert pin(secret) == %{running: blob_sha(@base), held: blob_sha(v2), hold: :certificates}

      # The mirror moves to a copy that fails: both indexers hold it, `public` still runs v2.
      v3 = failing("third")
      mirror!(v3)
      assert pin(public) == %{running: blob_sha(v2), held: blob_sha(v3), hold: :fails}

      assert :ok = Indexers.delete(nil, public.id)
      refute Repo.get(Pin, public.id)
      assert Repo.get_by(Copy, blob_sha: blob_sha(v2))

      mirror!(v3)

      # v2 only `public` used; @base `secret` runs; v3 is the mirror's and `secret`'s held copy.
      stored = Repo.all(from(c in Copy, where: c.name == "tracker.yml", select: c.blob_sha))
      assert Enum.sort(stored) == Enum.sort([blob_sha(@base), blob_sha(v3)])
    end

    test "an indexer deleted between the load checks and the transaction is skipped" do
      mirror!(@base)
      gone = cardigann!(@base)
      kept = cardigann!(@base)
      candidate = definition("tracker", %{"name" => "Renamed"})

      check = fn bytes ->
        if bytes == candidate, do: :ok = Indexers.delete(nil, gone.id)
        check(bytes)
      end

      assert {:ok, {:loaded, _}} = apply_files([{"v11", "tracker.yml", candidate}], check: check)
      refute Repo.get(ConfiguredIndexer, gone.id)
      refute Repo.get(Pin, gone.id)
      assert pin(kept).running == blob_sha(candidate)
    end
  end

  defp audits(action),
    do: Repo.all(from(a in AdminAudit, where: a.action == ^action, order_by: a.id))

  describe "the audit of a public base URL move" do
    test "an apply that moves a public indexer's effective base URL writes one row, nil actor" do
      legacy = definition("tracker", %{"links" => [link()]})
      mirror!(legacy)
      public = cardigann!(legacy)

      moved =
        definition("tracker", %{"links" => ["https://www2.invalid/"], "legacylinks" => [link()]})

      mirror!(moved)
      assert pin(public).running == blob_sha(moved)

      assert [audit] = audits("move_configured_indexer_base_url")

      assert %{
               actor_id: nil,
               entity_type: "ConfiguredIndexer",
               entity_id: id,
               detail: %{
                 "fields" => ["base_url"],
                 "from_copy" => from_copy,
                 "to_copy" => to_copy
               }
             } = audit

      assert {id, from_copy, to_copy} == {public.id, blob_sha(legacy), blob_sha(moved)}
    end

    test "the same move on an indexer with credentials is held and writes none" do
      mirror!(@base)
      secret = cardigann!(@base, %{"password" => "hunter2"})

      mirror!(
        definition("tracker", %{"links" => ["https://www2.invalid/"], "legacylinks" => [link()]})
      )

      assert pin(secret).hold == :hosts
      assert audits("move_configured_indexer_base_url") == []
    end

    test "a move that applies to an indexer with credentials writes none" do
      both = definition("tracker", %{"links" => [link(), "https://www2.invalid/"]})
      mirror!(both)
      secret = cardigann!(both, %{"password" => "hunter2"})

      # Both hosts were already the running copy's, so the move applies.
      moved =
        definition("tracker", %{"links" => ["https://www2.invalid/"], "legacylinks" => [link()]})

      mirror!(moved)
      assert pin(secret) == %{running: blob_sha(moved), held: nil, hold: nil}
      assert audits("move_configured_indexer_base_url") == []
    end

    test "an apply that keeps the effective base URL writes none" do
      mirror!(@base)
      _public = cardigann!(@base)
      mirror!(definition("tracker", %{"name" => "Renamed"}))

      assert audits("move_configured_indexer_base_url") == []
    end

    test "an audit row that fails to write rolls the apply back" do
      mirror!(@base)
      _public = cardigann!(@base)
      before = definition_tables()
      fail_audits!()

      assert_raise Exqlite.Error, ~r/audit refused/, fn ->
        apply_files([
          {"v11", "tracker.yml",
           definition("tracker", %{
             "links" => ["https://www2.invalid/"],
             "legacylinks" => [link()]
           })}
        ])
      end

      # The set row, entries, copies and load results are written before the audit, the pin
      # after it: every row is as it was.
      assert definition_tables() == before
    end
  end

  @tables ~w(indexer_definition_set indexer_definition_entries indexer_definition_copies
             indexer_definition_load_results indexer_definition_pins configured_indexers)

  defp definition_tables,
    do: Map.new(@tables, &{&1, Repo.query!("SELECT * FROM #{&1} ORDER BY 1, 2").rows})

  # Makes every admin_audit insert raise, from a temporary trigger the sandbox drops with the
  # test's connection state.
  defp fail_audits! do
    Repo.query!("""
    CREATE TEMP TRIGGER fail_audit BEFORE INSERT ON admin_audit
    BEGIN SELECT RAISE(ABORT, 'audit refused'); END
    """)

    :ok
  end

  describe "accept/3" do
    setup do
      mirror!(@base)
      indexer = cardigann!(@base, %{"password" => "hunter2"})
      hosted = definition("tracker", %{"description" => "https://new.invalid/"})
      mirror!(hosted)
      %{indexer: indexer, hosted: hosted}
    end

    test "applies a credential hold, raises config_version and writes one audit row", ctx do
      before = Repo.get!(ConfiguredIndexer, ctx.indexer.id)
      actor = Cinder.AccountsFixtures.user_fixture()

      assert :ok = Definitions.accept(ctx.indexer.id, blob_sha(ctx.hosted), actor)
      assert pin(ctx.indexer) == %{running: blob_sha(ctx.hosted), held: nil, hold: nil}

      after_accept = Repo.get!(ConfiguredIndexer, ctx.indexer.id)
      assert after_accept.config_version == before.config_version + 1
      assert after_accept.credentials_version == before.credentials_version

      assert [audit] = audits("accept_configured_indexer_definition")
      assert audit.actor_id == actor.id

      assert audit.detail == %{
               "fields" => ["definition"],
               "reason" => "hosts",
               "from_copy" => blob_sha(@base),
               "to_copy" => blob_sha(ctx.hosted)
             }

      refute inspect(audit.detail) =~ "hunter2"
    end

    test "refuses a stale hash", ctx do
      assert {:error, :stale} = Definitions.accept(ctx.indexer.id, blob_sha(@base), nil)
      assert pin(ctx.indexer).held == blob_sha(ctx.hosted)
      assert audits("accept_configured_indexer_definition") == []
    end

    test "refuses a gone id", ctx do
      :ok = Indexers.delete(nil, ctx.indexer.id)
      assert {:error, :not_found} = Definitions.accept(ctx.indexer.id, blob_sha(ctx.hosted), nil)
    end

    test "refuses a not-supported hold", ctx do
      later = definition("tracker-ns")
      mirror!(later)
      assert pin(ctx.indexer).hold == {:not_supported, :html_search}

      assert {:error, :not_acceptable} = Definitions.accept(ctx.indexer.id, blob_sha(later), nil)
      assert pin(ctx.indexer).running == blob_sha(@base)
    end

    test "refuses an undecryptable indexer", ctx do
      :ok = undecryptable!(ctx.indexer)

      assert {:error, :undecryptable} =
               Definitions.accept(ctx.indexer.id, blob_sha(ctx.hosted), nil)

      assert pin(ctx.indexer).held == blob_sha(ctx.hosted)
    end

    test "an audit row that fails to write rolls the Accept back", ctx do
      fail_audits!()

      assert_raise Exqlite.Error, ~r/audit refused/, fn ->
        Definitions.accept(ctx.indexer.id, blob_sha(ctx.hosted), nil)
      end

      assert pin(ctx.indexer).held == blob_sha(ctx.hosted)
      assert Repo.get!(ConfiguredIndexer, ctx.indexer.id).config_version == 1
    end

    test "held_hosts/1 lists the hosts the held copy adds", ctx do
      assert Definitions.held_hosts(ctx.indexer.id) == {:ok, ["new.invalid"]}
    end
  end

  describe "held_hosts/1 for a copy that declares a left secret again" do
    # The running copy moved to a new host while it declared no password, so that host is
    # already the running copy's: Accept's confirm still names every host the secret would reach.
    test "lists every host of the held copy" do
      mirror!(@base)
      indexer = cardigann!(@base, %{"password" => "hunter2"})
      without = definition("tracker", %{"settings" => settings_without("password")})
      mirror!(without)
      :ok = Definitions.accept(indexer.id, blob_sha(without), nil)

      hosted = %{"description" => "https://new.invalid/"}
      mirror!(definition("tracker", Map.put(hosted, "settings", settings_without("password"))))
      back = definition("tracker", hosted)
      mirror!(back)
      assert pin(indexer).hold == :retyped_credential

      assert Definitions.held_hosts(indexer.id) ==
               {:ok, ["new.invalid", "tracker.invalid", "wiki.invalid"]}
    end
  end
end
