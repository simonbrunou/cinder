defmodule Cinder.IndexersTest do
  use Cinder.DataCase, async: true

  import Cinder.AccountsFixtures

  alias Cinder.Accounts.User
  alias Cinder.Audit.AdminAudit
  alias Cinder.Indexers
  alias Cinder.Indexers.ConfiguredIndexer
  alias Cinder.SecretCodec
  alias Cloak.Ciphers.AES.GCM
  alias Phoenix.Component
  alias Phoenix.HTML.Form

  @key "nzb-api-key-0123456789"

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        name: "Indexer #{System.unique_integer([:positive])}",
        type: :newznab,
        base_url: "https://indexer.example",
        api_path: "/api"
      },
      overrides
    )
  end

  defp create!(overrides \\ %{}, secrets \\ %{"api_key" => @key}) do
    {:ok, row} = Indexers.create(nil, attrs(overrides), secrets)
    row
  end

  defp stored(id), do: Repo.get!(ConfiguredIndexer, id)

  # Each refusal's {message, validation tag} on `field`.
  defp refusals(changeset, field) do
    for {^field, {message, opts}} <- changeset.errors, do: {message, opts[:validation]}
  end

  defp envelope(id) do
    {:ok, json} = SecretCodec.decode(stored(id).secrets_ciphertext)
    Jason.decode!(json)
  end

  # A ciphertext made under another Vault key, as after a SECRET_KEY_BASE change.
  defp other_key_ciphertext(plaintext) do
    {:ok, ciphertext} =
      GCM.encrypt(plaintext,
        key: :crypto.hash(:sha256, "another secret_key_base"),
        tag: "AES.GCM.V1"
      )

    Base.encode64(ciphertext)
  end

  defp put_ciphertext!(id, ciphertext) do
    {1, _} =
      Repo.update_all(from(c in ConfiguredIndexer, where: c.id == ^id),
        set: [secrets_ciphertext: ciphertext]
      )
  end

  defp undecryptable!(overrides \\ %{}) do
    row = create!(overrides)

    other_key_ciphertext(
      Jason.encode!(%{"scope" => "indexer_secrets", "id" => row.id, "values" => %{}})
    )
    |> then(&put_ciphertext!(row.id, &1))

    stored(row.id)
  end

  defp audits, do: Repo.all(from(a in AdminAudit, order_by: a.id))

  describe "create/3" do
    test "creates a Newznab and a Torznab configured indexer and reads them back" do
      newznab = create!(%{name: "Geek", settings: %{"additional_parameters" => "&cat=2000"}})
      torznab = create!(%{name: "Jackett", type: :torznab, api_path: "/torznab/api"})

      assert {:ok, read} = Indexers.fetch_with_secrets(newznab.id)

      assert %ConfiguredIndexer{
               name: "Geek",
               type: :newznab,
               base_url: "https://indexer.example",
               api_path: "/api",
               settings: %{"additional_parameters" => "&cat=2000"},
               secrets: %{"api_key" => @key},
               definition: nil,
               enabled: true,
               flaresolverr: false,
               lock_version: 1,
               credentials_version: 1,
               config_version: 1
             } = read

      assert {:ok, %ConfiguredIndexer{name: "Jackett", type: :torznab, api_path: "/torznab/api"}} =
               Indexers.fetch_with_secrets(torznab.id)

      assert stored(torznab.id).type == :torznab
    end

    test "stores the type as its plain name in the column" do
      row = create!(%{type: :torznab})

      assert %{rows: [["torznab"]]} =
               Repo.query!("SELECT type FROM configured_indexers WHERE id = ?", [row.id])
    end

    test "an API key is optional: a row without one stores no ciphertext" do
      row = create!(%{}, %{})

      assert stored(row.id).secrets_ciphertext == nil
      assert {:ok, %ConfiguredIndexer{secrets: %{}}} = Indexers.fetch_with_secrets(row.id)
    end

    test "keeps a key's bytes as typed, surrounding spaces included" do
      row = create!(%{}, %{"api_key" => " padded key "})

      assert {:ok, %{secrets: %{"api_key" => " padded key "}}} =
               Indexers.fetch_with_secrets(row.id)
    end

    # Cardigann creates pin a definition copy: `Cinder.IndexersCardigannTest` covers them.
    test "a Cardigann create with no mirror copy is refused on its definition" do
      assert {:error, changeset} =
               Indexers.create(nil, attrs(%{type: :cardigann, definition: "nyaasi.yml"}), %{})

      assert refusals(changeset, :type) == []
      assert refusals(changeset, :definition) == [{"is invalid", :definition_not_in_mirror}]
      assert Repo.aggregate(ConfiguredIndexer, :count) == 0
    end

    test "refuses a missing API path and a definition on a Newznab or Torznab row" do
      for type <- [:newznab, :torznab] do
        assert {:error, changeset} = Indexers.create(nil, attrs(%{type: type, api_path: nil}))
        assert refusals(changeset, :api_path) == [{"can't be blank", :required}]

        assert {:error, changeset} =
                 Indexers.create(nil, attrs(%{type: type, definition: "nyaasi"}))

        assert refusals(changeset, :definition) == [{"is invalid", :definition_type}]
      end
    end

    test "refuses a second row with the same name; endpoints may repeat" do
      create!(%{name: "Same"})
      assert %ConfiguredIndexer{} = create!(%{name: "Other"})

      assert {:error, changeset} = Indexers.create(nil, attrs(%{name: "Same"}))
      assert refusals(changeset, :name) == [{"has already been taken", :unique_name}]
    end

    test "an unknown secret field, or a value that is not text, is refused on secrets" do
      for secrets <- [%{"password" => "x"}, %{"api_key" => 42}] do
        assert {:error, changeset} = Indexers.create(nil, attrs(), secrets)
        assert refusals(changeset, :secrets) == [{"is invalid", :secret_fields}]
      end

      assert Repo.aggregate(ConfiguredIndexer, :count) == 0
    end

    test "an explicit disabled create stores enabled false" do
      assert stored(create!(%{enabled: false}).id).enabled == false
    end
  end

  describe "the primary key" do
    test "the table's DDL holds AUTOINCREMENT" do
      %{rows: [[sql]]} =
        Repo.query!("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?", [
          "configured_indexers"
        ])

      assert sql =~ ~r/"id" INTEGER PRIMARY KEY AUTOINCREMENT/
    end

    test "after deleting the row with the highest id, a new row gets a higher id" do
      first = create!()
      highest = create!()
      assert highest.id > first.id

      assert :ok = Indexers.delete(nil, highest.id)
      assert create!().id > highest.id
    end
  end

  describe "prowlarr_indexer_id" do
    test "rows without one coexist, and the unique index refuses a repeated one" do
      first = create!()
      second = create!()
      assert [nil, nil] == Enum.map([first, second], &stored(&1.id).prowlarr_indexer_id)

      set_prowlarr_id = fn id ->
        Repo.update_all(from(c in ConfiguredIndexer, where: c.id == ^id),
          set: [prowlarr_indexer_id: 7]
        )
      end

      assert {1, _} = set_prowlarr_id.(first.id)

      assert_raise Exqlite.Error,
                   ~r/UNIQUE constraint failed: configured_indexers\.prowlarr/,
                   fn ->
                     set_prowlarr_id.(second.id)
                   end
    end
  end

  defp refused_on_create(field, value) do
    {:error, changeset} = Indexers.create(nil, attrs(%{field => value}))
    refusals(changeset, field)
  end

  describe "validation" do
    test "base URL: refuses userinfo, a query, a fragment, another scheme and no host" do
      for {url, tag} <- [
            {"https://user:pw@indexer.example", :base_url_userinfo},
            {"https://indexer.example/?apikey=x", :base_url_query},
            {"https://indexer.example?", :base_url_query},
            {"https://indexer.example/#f", :base_url_fragment},
            {"ftp://indexer.example", :base_url_scheme},
            {"indexer.example/api", :base_url_scheme},
            {"https://", :base_url_host},
            {"http:///path", :base_url_host},
            {"http://indexer.example:0", :base_url_port},
            {"http://indexer.example:65536", :base_url_port},
            {"https://indexer .example", :base_url_format},
            {<<"https://indexer.example/", 0xFF>>, :base_url_format}
          ] do
        assert {url, refused_on_create(:base_url, url)} == {url, [{"is invalid", tag}]}
      end

      for url <- [
            "https://indexer.example",
            "http://prowlarr:9696/3/",
            "http://indexer.example:1",
            "http://indexer.example:65535"
          ] do
        assert {:ok, %ConfiguredIndexer{base_url: ^url}} =
                 Indexers.create(nil, attrs(%{base_url: url}))
      end
    end

    test "API path: refuses a host, a scheme, no leading slash, a query and a fragment" do
      for {path, tag} <- [
            {"//evil.example/api", :api_path_authority},
            {"http://x/api", :api_path_plain},
            {"api", :api_path_plain},
            {"/api?x=1", :api_path_plain},
            {"/api#f", :api_path_plain},
            {"/a pi", :api_path_format}
          ] do
        assert {path, refused_on_create(:api_path, path)} == {path, [{"is invalid", tag}]}
      end

      assert {:ok, %ConfiguredIndexer{api_path: "/api"}} =
               Indexers.create(nil, attrs(%{api_path: "/api"}))
    end

    test "additional parameters: refuses apikey and passkey in any case or encoding" do
      for params <- [
            "&apikey=x",
            "&ApiKey=x",
            "&passkey=x",
            "&cat=2000&APIKEY=x",
            "&%61pikey=x",
            "& apikey =x",
            "?apikey=x",
            "cat=2000;apikey=x"
          ] do
        settings = %{"additional_parameters" => params}

        assert {params, refused_on_create(:settings, settings)} ==
                 {params, [{"is invalid", :credential_parameter}]}
      end

      assert {:ok, %ConfiguredIndexer{}} =
               Indexers.create(nil, attrs(%{settings: %{"additional_parameters" => "&cat=2000"}}))
    end

    # The request path (#1742) reads the value as the write check does: each value listed below,
    # which the check refuses, sends no pair, and the names it passes are read alike.
    test "additional_parameters/2: no pair from a refused value or a type without the setting" do
      for value <- [
            "&apikey=x",
            "&maxage=5&%61pikey=x",
            "& apikey =x",
            "?apikey=x",
            "maxage=5;apikey=x",
            "&maxage=5&%FF=x",
            "&maxage=5#x",
            5
          ] do
        assert {value, refused_on_create(:settings, %{"additional_parameters" => value}) != []} ==
                 {value, true}

        newznab = %ConfiguredIndexer{
          type: :newznab,
          settings: %{"additional_parameters" => value}
        }

        assert {value, ConfiguredIndexer.additional_parameters(newznab, [])} == {value, []}
      end

      for type <- [:torznab, :cardigann] do
        row = %ConfiguredIndexer{type: type, settings: %{"additional_parameters" => "&maxage=5"}}
        assert {type, ConfiguredIndexer.additional_parameters(row, [])} == {type, []}
      end

      row = %ConfiguredIndexer{
        type: :newznab,
        settings: %{"additional_parameters" => "?CAT=1&maxage=5&x=a%20b&flag"}
      }

      assert ConfiguredIndexer.additional_parameters(row, ["cat"]) ==
               [{"maxage", "5"}, {"x", "a b"}, {"flag", ""}]
    end

    test "additional parameters: refuses a name that is not text without control bytes, and a #" do
      for params <- ["&%FF=x", "&%00apikey=x", "&cat=2000#apikey=x"] do
        settings = %{"additional_parameters" => params}

        assert {params, refused_on_create(:settings, settings)} ==
                 {params, [{"is invalid", :parameter_format}]}
      end

      # URI.decode_www_form/1 keeps a malformed escape as typed, which is no credential name.
      assert {:ok, _} =
               Indexers.create(nil, attrs(%{settings: %{"additional_parameters" => "&%zz=x"}}))
    end

    test "settings: a value that is not UTF-8 text, or holds a control byte, is refused" do
      for value <- [<<"&cat=", 0xFF>>, "&cat=1\r\nX: 1", "&cat=\x001"] do
        assert {value, refused_on_create(:settings, %{"additional_parameters" => value})} ==
                 {value, [{"is invalid", :settings_values}]}
      end
    end

    test "a nil enabled, FlareSolverr, settings or priority is refused, not raised" do
      for field <- [:enabled, :flaresolverr, :settings, :priority] do
        assert {field, refused_on_create(field, nil)} == {field, [{"can't be blank", :required}]}
      end
    end

    test "the name is stored trimmed, so a spaced copy of a taken name is refused" do
      assert stored(create!(%{name: "  Geek  "}).id).name == "Geek"

      assert {:error, changeset} = Indexers.create(nil, attrs(%{name: " Geek"}))
      assert refusals(changeset, :name) == [{"has already been taken", :unique_name}]
    end

    test "settings: Newznab takes additional parameters only, Torznab none, values are text" do
      assert refused_on_create(:settings, %{"other" => "x"}) ==
               [{"is invalid", :settings_keys}]

      assert {:error, changeset} =
               Indexers.create(
                 nil,
                 attrs(%{type: :torznab, settings: %{"additional_parameters" => "&cat=1"}})
               )

      assert refusals(changeset, :settings) == [{"is invalid", :settings_keys}]

      assert refused_on_create(:settings, %{"additional_parameters" => 5}) ==
               [{"is invalid", :settings_values}]
    end

    test "priority: none stores 25, 1 and 50 are accepted, 0 and 51 are refused" do
      assert stored(create!().id).priority == 25
      assert stored(create!(%{priority: 1}).id).priority == 1
      assert stored(create!(%{priority: 50}).id).priority == 50

      assert refused_on_create(:priority, 0) ==
               [{"must be greater than or equal to %{number}", :number}]

      assert refused_on_create(:priority, 51) ==
               [{"must be less than or equal to %{number}", :number}]
    end

    test "priority: the CHECK constraint refuses a raw insert of 0, 51 or 1.5" do
      for priority <- [0, 51, 1.5] do
        error =
          assert_raise Exqlite.Error, fn ->
            Repo.query!(
              """
              INSERT INTO configured_indexers (name, type, base_url, priority, inserted_at, updated_at)
              VALUES (?, 'newznab', 'https://x.example', ?, '2026-01-01', '2026-01-01')
              """,
              ["raw #{priority}", priority]
            )
          end

        assert error.message =~ "CHECK constraint failed: configured_indexers_priority_range"
      end
    end
  end

  describe "secrets at rest" do
    test "the ciphertext's plaintext names scope indexer_secrets and the row's id" do
      row = create!()

      assert envelope(row.id) == %{
               "scope" => "indexer_secrets",
               "id" => row.id,
               "values" => %{"api_key" => @key}
             }

      refute stored(row.id).secrets_ciphertext =~ @key
    end

    test "a ciphertext copied from row A to row B reads as unreadable on B" do
      a = create!()
      b = create!(%{}, %{"api_key" => "b-key"})
      put_ciphertext!(b.id, stored(a.id).secrets_ciphertext)

      assert {:ok, %{secrets: %{"api_key" => @key}}} = Indexers.fetch_with_secrets(a.id)
      assert Indexers.fetch_with_secrets(b.id) == {:error, :undecryptable_secrets}
    end

    test "a ciphertext of another scope, or with values that are not text, reads as unreadable" do
      row = create!()

      for envelope <- [
            %{"scope" => "indexer_cookies", "id" => row.id, "values" => %{"api_key" => @key}},
            %{"scope" => "indexer_secrets", "id" => row.id, "values" => %{"api_key" => 1}},
            %{"scope" => "indexer_secrets", "id" => row.id, "values" => "x"},
            %{"scope" => "indexer_secrets", "values" => %{"api_key" => @key}}
          ] do
        put_ciphertext!(row.id, SecretCodec.encode(Jason.encode!(envelope)))

        assert {envelope, Indexers.fetch_with_secrets(row.id)} ==
                 {envelope, {:error, :undecryptable_secrets}}
      end

      put_ciphertext!(row.id, SecretCodec.encode("not json"))
      assert Indexers.fetch_with_secrets(row.id) == {:error, :undecryptable_secrets}
    end

    test "a ciphertext made under another Vault key reads as unreadable" do
      row = undecryptable!()
      assert Indexers.fetch_with_secrets(row.id) == {:error, :undecryptable_secrets}
    end

    test "inspect/1 of a configured indexer and of its changeset shows no key and no ciphertext" do
      row = create!()
      ciphertext = stored(row.id).secrets_ciphertext
      {:ok, read} = Indexers.fetch_with_secrets(row.id)

      # The controls: the struct holds both values.
      assert read.secrets == %{"api_key" => @key}
      assert read.secrets_ciphertext == ciphertext
      refute inspect(read) =~ @key
      refute inspect(read) =~ ciphertext

      changeset =
        Ecto.Changeset.change(%ConfiguredIndexer{},
          secrets_ciphertext: ciphertext,
          secrets: %{"api_key" => @key}
        )

      # The controls: the changeset carries both as changes.
      assert changeset.changes.secrets_ciphertext == ciphertext
      assert changeset.changes.secrets == %{"api_key" => @key}
      refute inspect(changeset) =~ @key
      refute inspect(changeset) =~ ciphertext
    end
  end

  describe "update/5 and the ciphertext" do
    test "an edit of the name, the priority, the enable toggle or the base URL keeps the ciphertext" do
      for edit <- [
            %{name: "Renamed"},
            %{priority: 3},
            %{enabled: false},
            %{base_url: "https://moved.example"}
          ] do
        row = create!()
        before = stored(row.id).secrets_ciphertext

        assert {:ok, _} = Indexers.update(nil, row.id, 1, edit)
        assert {edit, stored(row.id).secrets_ciphertext} == {edit, before}
      end
    end

    test "a blank key keeps the stored one, byte for byte" do
      row = create!()
      before = stored(row.id).secrets_ciphertext

      for secrets <- [%{"api_key" => ""}, %{"api_key" => "   "}, %{"api_key" => nil}] do
        assert {:ok, _} = Indexers.update(nil, row.id, stored(row.id).lock_version, %{}, secrets)
        assert stored(row.id).secrets_ciphertext == before
      end
    end

    # Re-entering a key the indexer had rejected is how an admin says it works again, so the
    # counters a rejection waits on must rise.
    test "re-entering the stored key counts as a key set" do
      row = create!()
      before = stored(row.id)

      assert {:ok, _} = Indexers.update(nil, row.id, 1, %{}, %{"api_key" => @key})

      after_edit = stored(row.id)
      refute after_edit.secrets_ciphertext == before.secrets_ciphertext
      assert envelope(row.id)["values"] == %{"api_key" => @key}
      assert %{credentials_version: 2, config_version: 2, lock_version: 2} = after_edit
      assert [%AdminAudit{detail: %{"secrets" => ["api_key"]}}] = audits()
    end

    test "a clear of a row with no key changes nothing" do
      row = create!(%{}, %{})

      assert {:ok, _} = Indexers.update(nil, row.id, 1, %{}, %{"clear_api_key" => "true"})

      assert %{secrets_ciphertext: nil, credentials_version: 1, config_version: 1} =
               stored(row.id)

      assert audits() == []
    end

    test "a key that is not UTF-8 text is refused on secrets and named nowhere" do
      row = create!()
      key = <<0xFF>> <> "SECRET-BYTES"

      assert {:error, changeset} = Indexers.update(nil, row.id, 1, %{}, %{"api_key" => key})
      assert refusals(changeset, :secrets) == [{"is invalid", :secret_fields}]
      refute inspect(changeset, limit: :infinity, printable_limit: :infinity) =~ "SECRET"
      assert envelope(row.id)["values"] == %{"api_key" => @key}
    end

    test "an edit that fails validation gets no new ciphertext in its changes" do
      row = create!()

      assert {:error, changeset} =
               Indexers.update(nil, row.id, 1, %{base_url: "ftp://x"}, %{"api_key" => "new-key"})

      refute Map.has_key?(changeset.changes, :secrets_ciphertext)
    end

    test "an edit the database refuses on a taken name returns no new ciphertext" do
      taken = create!()
      row = create!()

      assert {:error, changeset} =
               Indexers.update(nil, row.id, 1, %{name: taken.name}, %{"api_key" => "new-key"})

      assert [{"has already been taken", _}] = Keyword.get_values(changeset.errors, :name)
      refute Map.has_key?(changeset.changes, :secrets_ciphertext)
      assert stored(row.id).secrets_ciphertext == row.secrets_ciphertext
    end

    test "a secrets key among the plain attrs stays out of the changeset" do
      row = create!()

      for attrs <- [%{"secrets" => %{"api_key" => "smuggled"}}, %{secrets: %{"api_key" => "s"}}] do
        changeset = ConfiguredIndexer.edit_changeset(row, attrs)
        refute Map.has_key?(changeset.params, "secrets")
      end
    end

    test "a key set decrypts, merges and encrypts again; a clear empties it" do
      row = create!()

      assert {:ok, _} = Indexers.update(nil, row.id, 1, %{}, %{"api_key" => "new-key"})
      assert envelope(row.id)["values"] == %{"api_key" => "new-key"}

      assert {:ok, _} = Indexers.update(nil, row.id, 2, %{}, %{"clear_api_key" => "true"})
      assert stored(row.id).secrets_ciphertext == nil
      assert {:ok, %{secrets: %{}}} = Indexers.fetch_with_secrets(row.id)
    end

    test "a typed key wins over a ticked clear; an unticked clear keeps the key" do
      row = create!()

      assert {:ok, _} =
               Indexers.update(nil, row.id, 1, %{}, %{
                 "api_key" => "typed",
                 "clear_api_key" => "true"
               })

      assert envelope(row.id)["values"] == %{"api_key" => "typed"}

      assert {:ok, _} = Indexers.update(nil, row.id, 2, %{}, %{"clear_api_key" => "false"})
      assert envelope(row.id)["values"] == %{"api_key" => "typed"}
    end

    test "the type and the definition are fixed at create" do
      row = create!()

      assert {:error, changeset} = Indexers.update(nil, row.id, 1, %{type: :torznab})
      assert refusals(changeset, :type) == [{"is invalid", :fixed_at_create}]

      assert {:error, changeset} = Indexers.update(nil, row.id, 1, %{definition: "nyaasi"})
      assert {"is invalid", :fixed_at_create} in refusals(changeset, :definition)

      assert stored(row.id).type == :newznab
    end

    test "an edit runs the same validation as a create" do
      row = create!()

      assert {:error, changeset} = Indexers.update(nil, row.id, 1, %{priority: 51})
      assert [{_, :number}] = refusals(changeset, :priority)

      assert {:error, changeset} = Indexers.update(nil, row.id, 1, %{api_path: "//evil/api"})
      assert refusals(changeset, :api_path) == [{"is invalid", :api_path_authority}]

      assert stored(row.id).priority == 25
    end
  end

  describe "update/5 on secrets that do not decrypt" do
    test "a key set writes a new ciphertext, and a key clear leaves none" do
      row = undecryptable!()
      assert {:ok, _} = Indexers.update(nil, row.id, 1, %{}, %{"api_key" => "fresh"})
      assert envelope(row.id)["values"] == %{"api_key" => "fresh"}

      row = undecryptable!()
      assert {:ok, _} = Indexers.update(nil, row.id, 1, %{}, %{"clear_api_key" => "on"})
      assert stored(row.id).secrets_ciphertext == nil
    end

    test "a name edit succeeds and keeps the ciphertext" do
      row = undecryptable!()

      assert {:ok, _} = Indexers.update(nil, row.id, 1, %{name: "Renamed"}, %{"api_key" => ""})
      assert stored(row.id).name == "Renamed"
      assert stored(row.id).secrets_ciphertext == row.secrets_ciphertext
    end
  end

  describe "counters" do
    # One row per field and counter: {edit attrs, secrets, credentials rises?, config rises?}.
    @cases [
      {"base URL", %{base_url: "https://moved.example"}, %{}, true, true},
      {"key set", %{}, %{"api_key" => "new-key"}, true, true},
      {"key clear", %{}, %{"clear_api_key" => "true"}, true, true},
      {"name", %{name: "Renamed"}, %{}, false, false},
      {"priority", %{priority: 7}, %{}, false, false},
      {"enable", %{enabled: false}, %{}, false, false},
      {"API path", %{api_path: "/newznab/api"}, %{}, false, true},
      {"additional parameters", %{settings: %{"additional_parameters" => "&cat=1"}}, %{}, false,
       true},
      {"FlareSolverr", %{flaresolverr: true}, %{}, false, true}
    ]

    for {label, edit, secrets, credentials?, config?} <- @cases do
      @edit edit
      @secrets secrets
      @credentials credentials?
      @config config?

      test "a #{label} edit: credentials_version rises #{credentials?}, config_version #{config?}" do
        row = create!()

        assert {:ok, _} = Indexers.update(nil, row.id, 1, @edit, @secrets)

        after_edit = stored(row.id)
        assert after_edit.credentials_version == if(@credentials, do: 2, else: 1)
        assert after_edit.config_version == if(@config, do: 2, else: 1)
      end
    end

    test "an edit of several counted fields raises each counter by one" do
      row = create!()

      assert {:ok, _} =
               Indexers.update(
                 nil,
                 row.id,
                 1,
                 %{base_url: "https://moved.example", api_path: "/x", flaresolverr: true},
                 %{"api_key" => "new"}
               )

      assert %{credentials_version: 2, config_version: 2} = stored(row.id)
    end

    test "set_enabled/4 moves neither counter" do
      row = create!()

      assert {:ok, %{enabled: false}} = Indexers.set_enabled(nil, row.id, 1, false)
      assert %{enabled: false, credentials_version: 1, config_version: 1} = stored(row.id)
    end
  end

  describe "saves and races" do
    test "two edits opened with the same lock_version: the second is refused and writes nothing" do
      row = create!()

      assert {:ok, %{lock_version: 2}} = Indexers.update(nil, row.id, 1, %{name: "First"})

      assert {:error, changeset} =
               Indexers.update(nil, row.id, 1, %{name: "Second"}, %{"api_key" => "k"})

      assert [{"is invalid", opts}] = for({:lock_version, error} <- changeset.errors, do: error)
      assert opts[:stale] == true
      assert %{name: "First", lock_version: 2} = stored(row.id)
      assert envelope(row.id)["values"] == %{"api_key" => @key}
      assert audits() == []
    end

    test "a no-op save advances the lock, and a stale no-op is refused" do
      row = create!()

      assert {:ok, %{lock_version: 2}} = Indexers.update(nil, row.id, 1, %{})
      assert stored(row.id).lock_version == 2

      assert {:error, changeset} = Indexers.update(nil, row.id, 1, %{})
      assert [{"is invalid", [stale: true]}] = for({:lock_version, e} <- changeset.errors, do: e)
      assert stored(row.id).lock_version == 2
    end

    test "a stale save that also fails validation reports the stale version" do
      row = create!()
      {:ok, _} = Indexers.update(nil, row.id, 1, %{name: "First"})

      assert {:error, changeset} = Indexers.update(nil, row.id, 1, %{priority: 0})
      assert [{"is invalid", [stale: true]}] = for({:lock_version, e} <- changeset.errors, do: e)
    end

    test "a save, a toggle or a delete of an id that no longer exists returns :not_found" do
      row = create!()
      assert :ok = Indexers.delete(nil, row.id)

      assert Indexers.update(nil, row.id, 1, %{name: "x"}) == {:error, :not_found}
      assert Indexers.set_enabled(nil, row.id, 1, false) == {:error, :not_found}
      assert Indexers.delete(nil, row.id) == {:error, :not_found}
    end
  end

  # #1697: a refused base URL, API path or settings value can carry a credential, so the
  # returned changeset holds none of it. `inspect/1` of a changeset omits its params, so each
  # case reads `params` apart.
  describe "a refused value" do
    @credential "SYNTH-cred-6b2f9a"

    @refused [
      {:base_url, "https://u:#{@credential}@indexer.example", :base_url_userinfo},
      {:base_url, "https://indexer.example/?apikey=#{@credential}", :base_url_query},
      {:base_url, "https://indexer.example/##{@credential}", :base_url_fragment},
      {:base_url, "ftp://u:#{@credential}@indexer.example", :base_url_scheme},
      {:base_url, "http://u:#{@credential}@/path", :base_url_host},
      {:base_url, "https://u:#{@credential}@indexer.example:99999", :base_url_port},
      {:base_url, "https://u:#{@credential}@indexer example", :base_url_format},
      {:api_path, "/api?apikey=#{@credential}", :api_path_plain},
      {:settings, %{"additional_parameters" => "&apikey=#{@credential}"}, :credential_parameter},
      {:settings, %{"additional_parameters" => "&passkey=#{@credential}"}, :credential_parameter},
      {:settings, %{"additional_parameters" => "&ApiKey=#{@credential}"}, :credential_parameter},
      {:settings, %{"additional_parameters" => "&apikey=#{@credential}#x"}, :parameter_format},
      {:settings, %{"additional_parameters" => "&apikey=#{@credential}\r\n"}, :settings_values},
      {:settings, %{"additional_parameters" => "&apikey=#{@credential}", "other" => "x"},
       :settings_keys}
    ]

    # The case's tag is among the field's refusals, and neither the params, the changes nor
    # inspect/1 of the changeset holds the credential. The field's param stays as "", so a form
    # renders it empty rather than the stored value.
    defp assert_dropped(changeset, {field, value, tag}) do
      label = "#{field} #{inspect(tag)}"
      assert {label, tag in Enum.map(refusals(changeset, field), &elem(&1, 1))} == {label, true}
      assert {label, Map.fetch!(changeset.params, Atom.to_string(field))} == {label, ""}
      refute Map.has_key?(changeset.changes, field), label
      # The control: the case typed the credential.
      assert inspect(value) =~ @credential, label

      for {part, text} <- [
            params: inspect(changeset.params, limit: :infinity, printable_limit: :infinity),
            changes: inspect(changeset.changes, limit: :infinity, printable_limit: :infinity),
            changeset: inspect(changeset, limit: :infinity, printable_limit: :infinity)
          ] do
        refute text =~ @credential, "#{label}: #{part}"
      end
    end

    test "a create holds no part of it and writes nothing" do
      for {field, value, _tag} = refused <- @refused do
        assert {:error, changeset} = Indexers.create(nil, attrs(%{field => value}), %{})
        assert_dropped(changeset, refused)
      end

      assert Repo.aggregate(ConfiguredIndexer, :count) == 0
    end

    test "an edit holds no part of it and writes nothing" do
      row =
        create!(%{
          base_url: "https://saved.example",
          settings: %{"additional_parameters" => "&cat=2000"}
        })

      before = stored(row.id)

      for {field, value, _tag} = refused <- @refused do
        assert {:error, changeset} =
                 Indexers.update(nil, row.id, row.lock_version, %{field => value, name: "Typed"})

        assert_dropped(changeset, refused)
        # The control: the changes hold the edit's other typed field.
        assert changeset.changes.name == "Typed"
      end

      assert stored(row.id) == before
    end

    test "the changeset's form reads a refused base URL as \"\", never the saved value" do
      row = create!(%{base_url: "https://saved.example"})
      refused = "https://u:#{@credential}@indexer.example"

      assert {:error, created} = Indexers.create(nil, attrs(%{base_url: refused}))

      assert {:error, edited} =
               Indexers.update(nil, row.id, row.lock_version, %{base_url: refused})

      for changeset <- [created, edited] do
        assert Form.input_value(Component.to_form(changeset), :base_url) == ""
      end
    end

    test "a stale save and a secrets error keep both refusals and hold no part of it" do
      refused = {:base_url, "https://u:#{@credential}@indexer.example", :base_url_userinfo}
      {field, value, _tag} = refused
      row = create!()
      {:ok, _} = Indexers.update(nil, row.id, row.lock_version, %{name: "Moved on"})

      assert {:error, stale} = Indexers.update(nil, row.id, row.lock_version, %{field => value})
      assert [{"is invalid", [stale: true]}] = for({:lock_version, e} <- stale.errors, do: e)
      assert_dropped(stale, refused)

      fresh = stored(row.id)

      for result <- [
            Indexers.create(nil, attrs(%{field => value}), %{"nosuch" => "x"}),
            Indexers.update(nil, fresh.id, fresh.lock_version, %{field => value}, %{
              "nosuch" => "x"
            })
          ] do
        assert {:error, changeset} = result
        assert refusals(changeset, :secrets) == [{"is invalid", :secret_fields}]
        assert_dropped(changeset, refused)
      end

      assert stored(row.id) == fresh
      assert Repo.aggregate(ConfiguredIndexer, :count) == 1
    end

    test "a save refused on another field keeps the typed base URL and additional parameters" do
      typed = %{
        base_url: "https://typed.example",
        settings: %{"additional_parameters" => "&cat=5000"},
        priority: 0
      }

      row = create!()
      assert {:error, created} = Indexers.create(nil, attrs(typed))
      assert {:error, edited} = Indexers.update(nil, row.id, row.lock_version, typed)

      for changeset <- [created, edited] do
        assert refusals(changeset, :priority) != []
        assert changeset.params["base_url"] == "https://typed.example"
        assert changeset.params["settings"] == %{"additional_parameters" => "&cat=5000"}
        assert changeset.changes.base_url == "https://typed.example"
        assert changeset.changes.settings == %{"additional_parameters" => "&cat=5000"}
      end
    end
  end

  describe "reads" do
    test "searchable/0: enabled rows only, by priority then id, without undecryptable ones" do
      b = create!(%{priority: 10})
      a = create!(%{priority: 5})
      c = create!(%{priority: 10})
      _disabled = create!(%{priority: 1, enabled: false})
      _unreadable = undecryptable!(%{priority: 1})

      assert [a.id, b.id, c.id] == Enum.map(Indexers.searchable(), & &1.id)
      assert Enum.all?(Indexers.searchable(), &(&1.secrets == %{"api_key" => @key}))
    end

    test "fetch_with_secrets/1: a disabled row, a closed tag for undecryptable and missing" do
      disabled = create!(%{enabled: false})
      unreadable = undecryptable!()

      assert {:ok, %ConfiguredIndexer{enabled: false, secrets: %{"api_key" => @key}}} =
               Indexers.fetch_with_secrets(disabled.id)

      assert Indexers.fetch_with_secrets(unreadable.id) == {:error, :undecryptable_secrets}
      assert Indexers.fetch_with_secrets(-1) == {:error, :not_found}
    end

    test "list/0: every row without secret values, each marked when they do not decrypt" do
      readable = create!(%{priority: 2})
      no_key = create!(%{priority: 3}, %{})
      unreadable = undecryptable!(%{priority: 1, enabled: false})

      assert [
               {unreadable.id, false, nil},
               {readable.id, true, nil},
               {no_key.id, true, nil}
             ] ==
               Enum.map(Indexers.list(), &{&1.id, &1.secrets_readable, &1.secrets})
    end
  end

  describe "audit" do
    test "a delete writes one row naming no value" do
      admin = admin_fixture()
      row = create!()

      assert :ok = Indexers.delete(admin, row.id)

      assert [
               %AdminAudit{
                 action: "delete_configured_indexer",
                 entity_type: "ConfiguredIndexer",
                 entity_id: id,
                 actor_id: actor_id,
                 detail: detail
               }
             ] = audits()

      assert {id, actor_id, detail} == {row.id, admin.id, %{}}
    end

    test "a base URL edit and a key edit each write one row naming the changed fields" do
      admin = admin_fixture()
      row = create!()

      {:ok, _} =
        Indexers.update(admin, row.id, 1, %{base_url: "https://moved.example", name: "N"})

      {:ok, _} = Indexers.update(admin, row.id, 2, %{}, %{"api_key" => "new-key"})
      {:ok, _} = Indexers.update(admin, row.id, 3, %{}, %{"clear_api_key" => "true"})

      assert [
               {"update_configured_indexer_access",
                %{"fields" => ["base_url", "name"], "secrets" => []}},
               {"update_configured_indexer_access", %{"fields" => [], "secrets" => ["api_key"]}},
               {"update_configured_indexer_access", %{"fields" => [], "secrets" => ["api_key"]}}
             ] == Enum.map(audits(), &{&1.action, &1.detail})

      audit_text = inspect(Enum.map(audits(), & &1.detail))
      refute audit_text =~ "moved.example"
      refute audit_text =~ "new-key"
    end

    test "a create, an enable toggle and other edits write none" do
      row = create!()
      {:ok, _} = Indexers.set_enabled(nil, row.id, 1, false)
      {:ok, _} = Indexers.update(nil, row.id, 2, %{name: "Renamed", priority: 9})
      {:ok, _} = Indexers.update(nil, row.id, 3, %{api_path: "/x", flaresolverr: true})

      assert audits() == []
    end

    test "when the audit insert fails, the edit and the delete roll back" do
      # An actor id that does not cast fails the audit changeset, so log_or_rollback/4 rolls back.
      broken_actor = %User{id: "not-an-id"}
      row = create!()

      assert {:error, %Ecto.Changeset{data: %AdminAudit{}}} =
               Indexers.update(broken_actor, row.id, 1, %{base_url: "https://moved.example"})

      assert %{base_url: "https://indexer.example", lock_version: 1} = stored(row.id)

      assert {:error, %Ecto.Changeset{data: %AdminAudit{}}} =
               Indexers.delete(broken_actor, row.id)

      assert Repo.get(ConfiguredIndexer, row.id)
      assert audits() == []
    end
  end
end
