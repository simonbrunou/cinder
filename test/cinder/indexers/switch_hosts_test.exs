defmodule Cinder.Indexers.SwitchHostsTest do
  # The host list of Switch to <name> (#1907, #1876, #1889 to #1891):
  # `Indexers.switch_host_pairs/4` reads the new side from the values the Switch's save writes
  # and the old side from what the indexer sends a credential to today. The oracle of each case
  # is the real save (`Cinder.Indexers.update/5`) and the adapter's own request for the row
  # before and after it (`Cardigann.copy/1` over `Indexers.fetch_with_secrets/1`, the path a
  # grab reads, so a disabled row counts), never a hand-written list.
  use Cinder.DataCase, async: true

  import Cinder.DefinitionFixtures

  alias Cinder.Acquisition.Indexer.Cardigann
  alias Cinder.Indexers
  alias Cinder.Indexers.{ConfiguredIndexer, Definitions, Secrets}

  @url "https://{{ .Config.k }}.x.invalid/"

  # A key `k` of class `class` with `default`. A select offers `options`.
  defp k_setting(:secret, default, _options),
    do: %{"name" => "k", "type" => "text", "label" => "K", "default" => default}

  defp k_setting(:plain, default, options) do
    %{
      "name" => "k",
      "type" => "select",
      "label" => "K",
      "default" => default,
      "options" => Map.new(options, &{&1, String.capitalize(&1)})
    }
  end

  # The running copy's select takes every value a case stores, "bad" included; the new one's
  # leaves "bad" out, so a stored "bad" is a value the new declaration refuses.
  @running_options ~w(old new own typed bad)
  @new_options ~w(old new own typed)

  defp copy(id, class, declares?, default, options, extra \\ %{}) do
    settings =
      if declares?, do: settings() ++ [k_setting(class, default, options)], else: settings()

    definition(id, Map.merge(%{"settings" => settings, "description" => @url}, extra))
  end

  # The adapter's request for the row as stored now, as a grab reads the row; nil when the
  # adapter runs none for it (secrets that do not decrypt, a copy that does not run).
  defp request_of(id) do
    with {:ok, row} <- Indexers.fetch_with_secrets(id),
         {:ok, %{request: request}} <- Cardigann.copy(row) do
      request.(%{}, DateTime.utc_now())
    else
      _no_request -> nil
    end
  end

  # The hosts the row sends a credential to today: its request's credential hosts, none when
  # that request sends no secret or there is no request.
  defp sent_today(id) do
    case request_of(id) do
      %{secrets: [_ | _], credential_hosts: hosts} -> hosts
      _sends_none -> MapSet.new()
    end
  end

  defp put_stored!(row, :plain, key, value) do
    settings = Map.put(Repo.get!(ConfiguredIndexer, row.id).settings || %{}, key, value)
    update_row!(row, settings: settings)
  end

  defp put_stored!(row, :secret, key, value) do
    {:ok, secrets} = Secrets.open(Repo.get!(ConfiguredIndexer, row.id))
    seal!(row, Map.put(secrets, key, value))
  end

  defp drop_stored!(row, :plain, key) do
    update_row!(row, settings: Map.delete(Repo.get!(ConfiguredIndexer, row.id).settings, key))
  end

  defp drop_stored!(row, :secret, key) do
    {:ok, secrets} = Secrets.open(Repo.get!(ConfiguredIndexer, row.id))
    seal!(row, Map.delete(secrets, key))
  end

  defp seal!(row, secrets),
    do: update_row!(row, secrets_ciphertext: Secrets.seal(row.id, secrets))

  defp update_row!(row, set) do
    {1, _} = Repo.update_all(from(c in ConfiguredIndexer, where: c.id == ^row.id), set: set)
    :ok
  end

  # The replacer, `newer.yml`, enters the mirror and `tracker.yml` leaves it.
  defp replace!(newer) do
    assert {:ok, {:loaded, _}} = apply_files([{"v11", "newer.yml", newer}])
    assert Definitions.name_status("tracker.yml") == {:replaced_by, "newer.yml"}
    :ok
  end

  # Reads the host list, then runs the save on the same input, and checks the list against what
  # the adapter sends after the save that it did not send before: the same set of hosts, each
  # shown as its template when a secret fills it.
  defp check_switch!(row, newer, input, secret_input) do
    row = Repo.get!(ConfiguredIndexer, row.id)
    {:in_mirror, %{definition: definition}} = Definitions.import_copy("newer.yml")

    attrs = %{
      definition: "newer.yml",
      definition_blob_sha: blob_sha(newer),
      base_url: List.first(definition.links),
      settings: input
    }

    before = sent_today(row.id)
    pairs = Indexers.switch_host_pairs(row.id, row.lock_version, attrs, secret_input)
    shown = Indexers.switch_hosts(row.id, row.lock_version, attrs, secret_input)
    digest = with {:ok, hosts} <- shown, do: Indexers.hosts_digest(hosts)
    attrs = Map.put(attrs, :switch_hosts_digest, digest)

    case Indexers.update(nil, row.id, row.lock_version, attrs, secret_input) do
      {:ok, _saved} ->
        assert {:ok, listed} = pairs
        assert %{credential_hosts: after_save} = request_of(row.id)

        expected =
          MapSet.reject(after_save, &(is_binary(&1) and MapSet.member?(before, &1)))

        assert MapSet.new(listed, &elem(&1, 0)) == expected

        {:ok, secrets} = Secrets.open(Repo.get!(ConfiguredIndexer, row.id))
        filled = for {_key, value} <- secrets, value != "", do: value

        for {host, form} <- listed do
          refute form != host and not match?({:unknown, "https://{{ .Config." <> _}, form) and
                   not match?({:unknown, "{{ .Config." <> _}, form),
                 "#{inspect(host)} shows as #{inspect(form)}"

          refute Enum.any?(filled, &(inspect(form) =~ "#{&1}.x.invalid")),
                 "#{inspect(form)} shows a secret's value"
        end

        assert shown == {:ok, listed |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.sort()}
        {:ok, listed, before}

      {:error, %Ecto.Changeset{errors: [{field, {_message, opts}} | _]}} ->
        assert pairs == {:error, {field, opts[:validation]}}
        {:refused, opts[:validation]}
    end
  end

  describe "#1876's cases" do
    # An applied update writes only the pin, so the row lacks a key the running copy declares.
    test "a key the running copy declares and the row never stored takes the new default" do
      v1 = definition("tracker", %{"description" => "https://old.x.invalid/"})
      mirror!(v1)
      row = cardigann!(v1, %{"password" => "hunter2"})
      mirror = %{"name" => "mirror", "type" => "text", "label" => "Mirror", "default" => "old"}
      url = "https://{{ .Config.mirror }}.x.invalid/"
      v2 = definition("tracker", %{"settings" => settings() ++ [mirror], "description" => url})
      mirror!(v2)
      assert pin(row).running == blob_sha(v2)

      newer =
        definition("newer", %{
          "replaces" => ["tracker"],
          "settings" => settings() ++ [%{mirror | "default" => "new"}],
          "description" => url
        })

      replace!(newer)

      assert {:ok, listed, _before} = check_switch!(row, newer, %{}, %{})
      assert {"new.x.invalid", {:unknown, "https://{{ .Config.mirror }}.x.invalid"}} in listed
    end

    test "a value stored plain that the running copy types as text, the new default differs" do
      v1 = definition("tracker", %{"description" => "https://false.x.invalid/"})
      mirror!(v1)
      row = cardigann!(v1, %{"password" => "hunter2"}, %{settings: %{"freeleech" => false}})

      retype = fn default ->
        Enum.map(settings(), fn
          %{"name" => "freeleech"} = s -> %{s | "type" => "text", "default" => default}
          s -> s
        end)
      end

      url = "https://{{ .Config.freeleech }}.x.invalid/"
      mirror!(definition("tracker", %{"settings" => retype.("false"), "description" => url}))

      newer =
        definition("newer", %{
          "replaces" => ["tracker"],
          "settings" => retype.("evil"),
          "description" => url
        })

      replace!(newer)

      assert {:ok, listed, _before} = check_switch!(row, newer, %{}, %{})
      assert {"evil.x.invalid", {:unknown, "https://{{ .Config.freeleech }}.x.invalid"}} in listed
    end
  end

  # The running class × the new class of `k` × its value source × the copy that declares it ×
  # secrets readable or not. Each host the save sends to is listed unless the indexer sends to
  # it today.
  describe "the matrix" do
    for running_class <- [:secret, :plain],
        new_class <- [:secret, :plain],
        source <- [:stored, :default, :typed, :refused],
        not (source == :refused and new_class == :secret),
        declares <- [:running, :new, :both],
        readable <- [true, false] do
      @tag running_class: running_class,
           new_class: new_class,
           source: source,
           declares: declares,
           readable: readable
      test "k #{running_class} then #{new_class}, #{source}, declared by #{declares}, " <>
             "secrets readable: #{readable}",
           context do
        %{
          running_class: running_class,
          new_class: new_class,
          source: source,
          declares: declares,
          readable: readable
        } = context

        running =
          copy("tracker", running_class, declares in [:running, :both], "old", @running_options)

        mirror!(running)
        row = cardigann!(running, %{"password" => "hunter2"})

        case source do
          :default -> drop_stored!(row, running_class, "k")
          :refused -> put_stored!(row, running_class, "k", "bad")
          _stored_or_typed -> put_stored!(row, running_class, "k", "own")
        end

        if not readable, do: undecryptable!(row)

        newer =
          copy("newer", new_class, declares in [:new, :both], "new", @new_options, %{
            "replaces" => ["tracker"]
          })

        replace!(newer)

        typed? = source == :typed and declares != :running
        new_secret? = new_class == :secret and declares != :running
        input = if typed? and new_class == :plain, do: %{"k" => "typed"}, else: %{}

        secret_input =
          Map.merge(
            if(readable, do: %{}, else: %{"username" => "u", "password" => "p", "apikey" => "a"}),
            cond do
              typed? and new_secret? -> %{"k" => "typed"}
              not readable and new_secret? and source == :default -> %{"clear_k" => "true"}
              true -> %{}
            end
          )

        case check_switch!(row, newer, input, secret_input) do
          {:ok, _listed, _before} ->
            :ok

          {:refused, validation} ->
            # Only stored secrets that do not decrypt and were not typed again refuse.
            assert {readable, new_secret?, source, validation} ==
                     {false, true, :stored, :secrets_unreadable}
        end
      end
    end

    # `{:unknown, raw}` holds the raw text with nothing filled, so the same text on both sides
    # can be two hosts: `k` moves from "own" to "typed" here.
    test "an unknown host shows even when the running copy names the same raw text" do
      url = "https://{{ .Config.k }}.{{ .Query.Keywords }}.x.invalid/"
      running = copy("tracker", :plain, true, "old", @running_options, %{"description" => url})
      mirror!(running)
      row = cardigann!(running, %{"password" => "hunter2"})
      put_stored!(row, :plain, "k", "own")

      newer =
        copy("newer", :plain, true, "new", @new_options, %{
          "replaces" => ["tracker"],
          "description" => url
        })

      replace!(newer)

      unknown = {:unknown, "https://{{ .Config.k }}.{{ .Query.Keywords }}.x.invalid"}
      assert unknown in sent_today(row.id)
      assert {:ok, listed, _before} = check_switch!(row, newer, %{"k" => "typed"}, %{})
      assert {unknown, unknown} in listed
    end
  end

  # A typed secret that holds a full URL adds that URL's host, which the list shows as the
  # secret's template, never as the host the secret names.
  test "a secret that holds a URL shows as its template" do
    running = copy("tracker", :secret, true, "old", [])
    mirror!(running)
    row = cardigann!(running, %{"password" => "hunter2"})

    newer =
      copy("newer", :secret, true, "new", [], %{
        "replaces" => ["tracker"],
        "description" => "Mirror list: {{ .Config.k }}"
      })

    replace!(newer)
    typed = %{"k" => "https://synth-typed-9f1c.invalid/"}

    assert {:ok, listed, _before} = check_switch!(row, newer, %{}, typed)
    assert {"synth-typed-9f1c.invalid", {:unknown, "{{ .Config.k }}"}} in listed
    refute inspect(Enum.map(listed, &elem(&1, 1))) =~ "synth-typed-9f1c"
  end

  # The rows that send no credential today (#1889), a disabled row, which a grab still reads
  # (#1891), and a row that sends one, each switched with a typed password onto a copy that
  # names the running copy's host and one of its own.
  describe "the row's state today" do
    setup do
      running = definition("tracker", %{"description" => "https://shared.x.invalid/"})
      mirror!(running)

      newer =
        definition("newer", %{
          "replaces" => ["tracker"],
          "description" => "https://shared.x.invalid/ https://new.x.invalid/"
        })

      %{running: running, newer: newer}
    end

    defp listed_hosts(row, newer) do
      replace!(newer)
      assert {:ok, listed, _before} = check_switch!(row, newer, %{}, %{"password" => "p"})
      listed |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    end

    @every ["new.x.invalid", "shared.x.invalid", "tracker.invalid", "wiki.invalid"]

    test "a row with no credential yet lists every host the save sends one to", ctx do
      row = cardigann!(ctx.running, %{})
      assert %{secrets: []} = request_of(row.id)
      assert listed_hosts(row, ctx.newer) == @every
    end

    test "a row whose only non-default secret sits under a key the running copy no longer declares",
         ctx do
      row = cardigann!(ctx.running, %{})
      put_stored!(row, :secret, "gone", "v")
      assert %{secrets: []} = request_of(row.id)
      assert listed_hosts(row, ctx.newer) == @every
    end

    test "a row whose secrets do not decrypt lists every host", ctx do
      row = cardigann!(ctx.running, %{"password" => "hunter2"})
      :ok = undecryptable!(row)
      replace!(ctx.newer)

      typed = %{"username" => "u", "password" => "p", "apikey" => "a"}
      assert {:ok, listed, _before} = check_switch!(row, ctx.newer, %{}, typed)
      assert listed |> Enum.map(&elem(&1, 0)) |> Enum.sort() == @every
    end

    test "a disabled row keeps the hosts a grab sends to today off the list", ctx do
      row = cardigann!(ctx.running, %{"password" => "hunter2"}, %{enabled: false})
      refute Enum.any?(Indexers.searchable(), &(&1.id == row.id))
      assert "shared.x.invalid" in sent_today(row.id)
      assert listed_hosts(row, ctx.newer) == ["new.x.invalid"]
    end

    test "an enabled row with a password keeps the hosts it sends to today off the list", ctx do
      row = cardigann!(ctx.running, %{"password" => "hunter2"})
      assert listed_hosts(row, ctx.newer) == ["new.x.invalid"]
    end
  end

  describe "a refusal" do
    test "reads no list for an input the save refuses, as the save refuses it" do
      running = definition("tracker")
      mirror!(running)
      row = cardigann!(running, %{"password" => "hunter2"})
      newer = definition("newer", %{"replaces" => ["tracker"]})
      replace!(newer)

      attrs = %{
        definition: "newer.yml",
        definition_blob_sha: blob_sha(newer),
        base_url: "https://elsewhere.invalid/"
      }

      assert Indexers.switch_host_pairs(row.id, row.lock_version, attrs, %{}) ==
               {:error, {:base_url, :base_url_links}}

      assert Indexers.switch_hosts(row.id, row.lock_version + 1, attrs, %{}) ==
               {:error, {:lock_version, :stale}}

      assert Indexers.switch_hosts(row.id, row.lock_version, %{attrs | definition: "x.yml"}, %{}) ==
               {:error, {:definition, :fixed_at_create}}

      assert Indexers.switch_hosts(row.id + 1000, row.lock_version, attrs, %{}) ==
               {:error, :not_found}
    end
  end
end
