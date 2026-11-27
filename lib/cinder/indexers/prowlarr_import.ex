defmodule Cinder.Indexers.ProwlarrImport do
  @moduledoc """
  Imports Prowlarr's Newznab, Torznab and Cardigann indexers as configured indexers (#1673 and
  #1675, part of #1610): `preview/0` reads Prowlarr's API and maps each indexer to a row, and
  `commit/3` creates the rows the admin ticked in one audited transaction. Every row state,
  note, error and report line is an atom or a tagged tuple; the dialog words them (#1674).

  ## Preview

  `preview/0` reads the stored Prowlarr URL and key (`Cinder.Indexers.ProwlarrApi.connection/0`),
  then `GET /api/v1/indexer`, `/api/v1/indexerproxy` and `/api/v1/config/host`, each read as
  `Cinder.Indexers.ProwlarrImport.Answer` says. It answers `{:ok, preview}` or `{:error, tag}`:
  `:not_configured` with no request made, a read's tag from `Cinder.Indexers.ProwlarrApi`, or
  `:unexpected_response`. Each Prowlarr indexer gives one `Cinder.Indexers.ProwlarrImport.Row`,
  whose `state` the first of these rules that holds gives:

    1. An indexer an earlier import linked (`prowlarr_indexer_id`) is `:already_imported`.
    2. A Cardigann indexer follows `Cinder.Indexers.ProwlarrImport.Cardigann`: `:held` while no
       definition set is loaded or its copy has no load result yet, whatever its tags;
       `:direct` as a Cardigann configured indexer pinned to the mirror's copy of its
       definition file, its FlareSolverr toggle on when a FlareSolverr proxy shares a tag, or
       `:refused` when what it would store fails the configured indexer's checks; else
       `:via_prowlarr` as rule 4 creates it, with that module's reasons in place of rule 4's.
    3. A Newznab or Torznab indexer whose own settings fail `Cinder.Indexers.ConfiguredIndexer`'s
       checks, run on what a direct row would store, is `:refused` with each failed check, the
       name's aside. So is a Torznab indexer whose additional parameters fail the checks a
       Newznab indexer's pass (`Cinder.Indexers.ConfiguredIndexer.parameters_refusal/1`). This
       holds whatever route the row would take.
    4. An indexer that cannot go direct is `:via_prowlarr`, offered unticked: any implementation
       but Newznab and Torznab, a proxy sharing one of its tags (HTTP, SOCKS, FlareSolverr, which
       Cinder uses for Cardigann only, or one Cinder does not know), Prowlarr's global proxy
       on, or a Torznab indexer with additional parameters, which a Torznab configured indexer
       does not store and Prowlarr adds to each search of its own. It would be created as a
       generic Newznab (Usenet) or Torznab (torrent) configured indexer with base URL the stored
       Prowlarr URL, its trailing `/` cut, and API path `/<id>/api`, which
       `Cinder.Indexers.through_prowlarr?/3` reads as searched through Prowlarr. It is
       `:refused` instead when Prowlarr calls its protocol `unknown`, or when the settings it
       would be created with fail the checks.
    5. Any other Newznab or Torznab indexer is `:direct`: same type, base URL, API path and, for
       Newznab, additional parameters.

  Name, enabled state and priority are Prowlarr's. Rows come in (priority, Prowlarr id) order,
  the order a commit creates them in.

  The preview keeps no secret value. Prowlarr answers a Newznab or Torznab key as `********`;
  any key value that is not blank, masked or not, reads as `key: :masked`, and the row's plan
  holds an HMAC of that value under a random key made for this preview. A direct Cardigann row's
  plan also holds the pinned copy's blob hash, the names of its secret settings Prowlarr answers
  in clear and masked, its notes, and an HMAC of those secrets' values.

  ## Commit

  `commit(preview, choices, actor, opts)` takes, for each Prowlarr id, the submit's
  `%{ticked: boolean, name: String.t(), via_prowlarr: boolean, secrets: map}`; a call site passes
  `secrets` straight from the event params, as `%{"api_key" => typed}`. Only ticked rows are
  read. `opts` takes `save_flaresolverr_url: true`, the import's FlareSolverr tick (#1682). It
  answers:

    * `{:error, :nothing_ticked}` before any request, for choices that tick no row;
    * `{:error, :import_running}` while another commit runs;
    * `{:error, tag}` for a read as `preview/0` answers it;
    * `{:error, {:changed, new_preview}}` when the stored Prowlarr URL or key, the FlareSolverr
      host, or a ticked row's plan, differs from what the preview read: Prowlarr's answer is
      read again first;
    * `{:error, {:rows, errors}}`, errors by Prowlarr id, each a list of codes, when a ticked
      row cannot be created: `:not_importable` (held, already imported, refused, or not in the
      preview), `:via_prowlarr_not_chosen` (a through-Prowlarr row ticked without
      `via_prowlarr: true`), `:via_prowlarr_not_offered` (a direct row ticked with it),
      `:name_required`, `:name_taken` (another configured indexer holds it), `:name_duplicate`
      (two ticked rows share it), `:secret_invalid` (a key row's typed key),
      `:settings_invalid` (a Cardigann row's typed secrets), `:already_imported` (linked meanwhile,
      checked again inside the transaction), and `:name_conflict`, `:link_conflict` or
      `{field, validation}` for an insert the database or the checks refuse;
    * `{:error, :audit_refused}` when the audit row is refused, which rolls the import back;
    * `{:ok, report}`.

  A direct Cardigann row takes the secret values Prowlarr answers in clear from the commit's own
  read of Prowlarr, and a typed value only for each secret Prowlarr masks; secrets that are not a
  map, a key that is not a masked setting's name, or a value that is not text is
  `:settings_invalid`. A masked secret left blank creates the indexer disabled, the setting at
  the copy's default, or empty text with none, and the report notes
  `{:secrets_not_entered, labels}`. Its notes also carry the row's `{:took_default, label}`.
  The create pins the copy again inside the transaction, and a copy the mirror no longer holds
  refuses the batch with `{:definition, validation}` on that row.

  Names are trimmed, as the configured indexer stores them. A direct row with a masked key and a
  typed key is created with Prowlarr's enabled state and that key; left blank, it is created
  disabled with no key, and the report notes `:created_disabled_no_key`. A row with no key in
  Prowlarr keeps its enabled state. A through-Prowlarr row gets the stored Prowlarr key, read on
  the server at commit, and its FlareSolverr toggle off.

  With the FlareSolverr tick, a preview `flaresolverr_host` and no FlareSolverr URL saved, the
  commit saves that host through `Cinder.Indexers.FlareSolverrUrl.put/1` once the ticked rows
  pass their checks and before they are created, so the URL exists before their Tests run. A
  batch the insert then refuses keeps the URL, as the indexer form does. A URL already saved is
  kept, the tick aside.

  The rows are created through `Cinder.Indexers.import_batch/2`, in one transaction with one
  `Cinder.Audit` row naming the count. After it commits, the import asks the Test runner to start
  each enabled created indexer's Test in the background
  (`Cinder.Acquisition.IndexerSource.Native.TestRunner.start/1`); a runner that is down or already
  holds that indexer's mark starts none. The report is
  `%{created: [%{id, prowlarr_id, name, enabled, notes}], tests_started: [id]}` plus
  `flaresolverr_url_saved`, whether the tick saved the URL; `tests_started` names each indexer
  whose Test the runner started. While no URL is saved, each created indexer with its FlareSolverr
  toggle on notes `:flaresolverr_url_not_set`. The import never changes `indexer_source`.
  """

  alias Cinder.Acquisition.IndexerSource.Native.TestRunner
  alias Cinder.Indexers
  alias Cinder.Indexers.{ConfiguredIndexer, Definitions, FlareSolverrUrl, ProwlarrApi, Secrets}
  alias Cinder.Indexers.ProwlarrApi.Connection
  alias Cinder.Indexers.ProwlarrImport.{Answer, Cardigann, Preview, Row}

  @generic %{"Newznab" => :newznab, "Torznab" => :torznab}
  @through_types %{"usenet" => :newznab, "torrent" => :torznab}

  @proxy_reasons %{
    "Http" => :http_proxy,
    "Socks4" => :socks_proxy,
    "Socks5" => :socks_proxy,
    "FlareSolverr" => :flaresolverr
  }

  @type choice :: %{
          optional(:ticked) => boolean(),
          optional(:name) => String.t(),
          optional(:via_prowlarr) => boolean(),
          optional(:secrets) => map()
        }

  @doc "Reads Prowlarr's API and maps each of its indexers to a preview row."
  @spec preview() :: {:ok, Preview.t()} | {:error, atom() | tuple()}
  def preview do
    with {:ok, connection} <- ProwlarrApi.connection(),
         {:ok, read} <- read(connection) do
      {:ok, build(read, connection, new_mac_key())}
    end
  end

  @doc "Creates the configured indexers `choices` ticks, as the moduledoc says."
  @spec commit(Preview.t(), %{optional(pos_integer()) => choice()}, Indexers.actor(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def commit(%Preview{} = preview, choices, actor \\ nil, opts \\ []) when is_map(choices) do
    save? = Keyword.get(opts, :save_flaresolverr_url, false) == true

    case ticked_ids(choices) do
      [] -> {:error, :nothing_ticked}
      ticked -> with_lock(fn -> run_commit(preview, choices, ticked, actor, save?) end)
    end
  end

  defp ticked_ids(choices) do
    for {id, %{ticked: true}} <- choices, do: id
  end

  # One commit at a time: the lock is tried once, and a held one refuses the commit.
  defp with_lock(fun) do
    lock = {__MODULE__, self()}

    if :global.set_lock(lock, [node()], 0) do
      try do
        fun.()
      after
        :global.del_lock(lock, [node()])
      end
    else
      {:error, :import_running}
    end
  end

  defp run_commit(preview, choices, ticked, actor, save?) do
    with {:ok, connection} <- ProwlarrApi.connection(),
         {:ok, read} <- read(connection),
         fresh = build(read, connection, preview.mac_key),
         :ok <- unchanged(preview, fresh, ticked, read, connection),
         {:ok, entries} <- entries(preview, fresh, choices, ticked, read, connection),
         saved? = save_flaresolverr_url(save?, fresh.flaresolverr_host),
         {:ok, created} <- create(actor, entries) do
      {:ok, report(created, entries, saved?)}
    end
  end

  # The tick saves Prowlarr's host only while Cinder has no URL, before the indexers, so the
  # URL exists before their Tests run; a batch refused after it keeps the URL, as the form does.
  defp save_flaresolverr_url(true, host) when is_binary(host) do
    FlareSolverrUrl.get() == nil and FlareSolverrUrl.put(host) == :ok
  end

  defp save_flaresolverr_url(_save?, _host), do: false

  # The links and names are read before Prowlarr's answers, so a link made while the answers
  # are read reaches the transaction's own check.
  defp read(%Connection{} = connection) do
    links = Indexers.prowlarr_links()
    names = Indexers.list() |> Enum.map(& &1.name) |> MapSet.new()

    with {:ok, indexers} <- fetch(connection, "/api/v1/indexer", &Answer.indexers/1),
         {:ok, proxies} <- fetch(connection, "/api/v1/indexerproxy", &Answer.proxies/1),
         {:ok, global} <- fetch(connection, "/api/v1/config/host", &Answer.global_proxy/1) do
      {:ok,
       %{
         indexers: indexers,
         proxies: proxies,
         global_proxy: global,
         linked: MapSet.new(links, &elem(&1, 1)),
         names: names
       }}
    end
  end

  defp fetch(connection, path, parse) do
    with {:ok, body} <- ProwlarrApi.get(connection, path, []), do: parse.(body)
  end

  defp new_mac_key, do: :crypto.strong_rand_bytes(32)

  defp mac(key, term), do: :crypto.mac(:hmac, :sha256, key, :erlang.term_to_binary(term))

  defp build(read, connection, mac_key) do
    rows =
      read.indexers
      |> Enum.sort_by(&{&1.priority, &1.id})
      |> Enum.map(&row(&1, read, connection, mac_key))

    %Preview{
      rows: rows,
      global_proxy: read.global_proxy,
      flaresolverr_host: flaresolverr_host(read.proxies),
      mac_key: mac_key,
      source_mac: mac(mac_key, {connection.url, connection.api_key})
    }
  end

  # The one URL Prowlarr's FlareSolverr proxies name, when `FlareSolverrUrl.put/1` would save
  # it; proxies on two hosts offer none, since the import cannot tell which one a row uses.
  defp flaresolverr_host(proxies) do
    hosts =
      for %{implementation: "FlareSolverr", host: host} <- proxies,
          is_binary(host),
          uniq: true,
          do: String.trim(host)

    case hosts do
      [host] -> if FlareSolverrUrl.valid?(host), do: host
      _none_or_several -> nil
    end
  end

  defp row(indexer, read, connection, mac_key) do
    base = %Row{
      prowlarr_id: indexer.id,
      name: indexer.name,
      implementation: indexer.implementation,
      protocol: indexer.protocol,
      priority: indexer.priority,
      enabled: indexer.enable,
      state: nil,
      not_carried: not_carried(indexer)
    }

    via = via_reasons(indexer, read)
    own = own_refusals(indexer)

    cond do
      indexer.id in read.linked -> planned(%{base | state: :already_imported})
      Map.has_key?(indexer, :cardigann) -> cardigann(base, indexer, read, connection, mac_key)
      own != [] -> planned(%{base | state: :refused, reasons: own})
      via != [] -> through(base, indexer, via, connection, mac_key)
      true -> direct(base, indexer, mac_key)
    end
  end

  # The mirror decides a Cardigann row (#1675): held while no set is loaded or its copy has no
  # load result yet, direct with its definition when it can go direct, else the through-Prowlarr
  # offer with Cardigann's reasons. Either of the last two is refused when the configured
  # indexer's checks refuse what it would store.
  defp cardigann(base, indexer, read, connection, mac_key) do
    copy = indexer.cardigann.file |> Cardigann.file_name() |> Definitions.import_copy()

    case Cardigann.plan(indexer, copy, proxy_codes(indexer, read)) do
      :held -> held(base)
      {:via_prowlarr, reasons} -> through(base, indexer, reasons, connection, mac_key)
      {:direct, plan} -> cardigann_direct(base, indexer, plan, mac_key)
    end
  end

  defp proxy_codes(indexer, read) do
    proxies =
      for proxy <- read.proxies,
          Enum.any?(proxy.tags, &(&1 in indexer.tags)),
          do: Map.get(@proxy_reasons, proxy.implementation, :other_proxy)

    if read.global_proxy, do: [:global_proxy | proxies], else: proxies
  end

  defp cardigann_direct(base, indexer, plan, mac_key) do
    row = %{
      base
      | state: :direct,
        type: :cardigann,
        default_ticked: true,
        secret_inputs: plan.masked,
        notes: plan.notes
    }

    checked(row, plan.attrs, indexer, mac_key, %{
      clear: plan.clear,
      masked: Enum.map(plan.masked, & &1.field),
      notes: plan.notes,
      secrets_mac: mac(mac_key, secret_values(indexer, plan))
    })
  end

  # The values of every secret field the plan names, as Prowlarr answered them.
  defp secret_values(indexer, plan) do
    fields = plan.clear ++ Enum.map(plan.masked, & &1.field)
    Map.take(indexer.cardigann.values, fields)
  end

  # A Newznab or Torznab indexer's own settings pass the configured indexer's checks whatever
  # route the row takes, as the issue refuses them: run as a direct row would store them, plus a
  # Torznab indexer's additional parameters, which pass the checks a Newznab one's pass.
  defp own_refusals(%{implementation: implementation} = indexer)
       when is_map_key(@generic, implementation) do
    type = Map.fetch!(@generic, implementation)
    parameters = indexer.fields["additionalParameters"]

    torznab =
      if type == :torznab and not blank?(parameters),
        do: ConfiguredIndexer.parameters_refusal(parameters)

    changeset =
      indexer
      |> direct_attrs(type)
      |> Map.put("name", indexer.name)
      |> ConfiguredIndexer.create_changeset()

    (refusals(changeset) ++ if(torznab, do: [{:settings, torznab}], else: []))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp own_refusals(_indexer), do: []

  defp not_carried(indexer) do
    notes =
      if indexer.app_profile_id > 0,
        do: [:app_profile | indexer.not_carried],
        else: indexer.not_carried

    notes |> Enum.uniq() |> Enum.sort()
  end

  defp held(base), do: planned(%{base | state: :held, reasons: [:definitions_not_loaded]})

  defp via_reasons(indexer, read) do
    implementation =
      if Map.has_key?(@generic, indexer.implementation), do: [], else: [:implementation]

    # A Torznab configured indexer stores no additional parameters; Prowlarr adds them itself.
    parameters =
      if indexer.implementation == "Torznab" and
           not blank?(indexer.fields["additionalParameters"]),
         do: [:additional_parameters],
         else: []

    (implementation ++ proxy_codes(indexer, read) ++ parameters) |> Enum.uniq() |> Enum.sort()
  end

  defp through(base, indexer, via, connection, mac_key) do
    # Prowlarr's protocol decides, so one it calls `unknown` is refused whatever the type says.
    type =
      Map.has_key?(@through_types, indexer.protocol) &&
        (Map.get(@generic, indexer.implementation) || Map.fetch!(@through_types, indexer.protocol))

    if type do
      through_planned(base, indexer, via, type, connection, mac_key)
    else
      planned(%{base | state: :refused, reasons: [:protocol_unknown]})
    end
  end

  defp through_planned(base, indexer, via, type, connection, mac_key) do
    attrs = %{
      "type" => type,
      "base_url" => String.trim_trailing(connection.url, "/"),
      "api_path" => "/#{indexer.id}/api",
      "enabled" => indexer.enable,
      "priority" => indexer.priority,
      "flaresolverr" => false,
      "settings" => %{}
    }

    checked(
      %{base | state: :via_prowlarr, reasons: via, type: type, key: :prowlarr},
      attrs,
      indexer,
      mac_key
    )
  end

  defp direct(base, indexer, mac_key) do
    type = Map.fetch!(@generic, indexer.implementation)
    key = if blank?(indexer.fields["apiKey"]), do: :none, else: :masked

    checked(
      %{base | state: :direct, type: type, key: key, default_ticked: true},
      direct_attrs(indexer, type),
      indexer,
      mac_key
    )
  end

  # Only Newznab stores additional parameters; a Torznab row with some goes through Prowlarr.
  defp direct_attrs(indexer, type) do
    fields = indexer.fields
    parameters = fields["additionalParameters"]

    %{
      "type" => type,
      "base_url" => fields["baseUrl"],
      "api_path" => fields["apiPath"],
      "enabled" => indexer.enable,
      "priority" => indexer.priority,
      "flaresolverr" => false,
      "settings" =>
        if(type == :torznab or blank?(parameters),
          do: %{},
          else: %{"additional_parameters" => parameters}
        )
    }
  end

  defp blank?(value), do: is_nil(value) or String.trim(value) == ""

  # Each failed check but the name's, as `{field, validation}`.
  defp refusals(changeset) do
    for {field, {_message, opts}} <- changeset.errors,
        field != :name,
        do: {field, Keyword.get(opts, :validation)}
  end

  # The configured indexer's checks, run with Prowlarr's name, which the admin replaces at
  # commit: a name error is the commit's. A refused row keeps only the failed checks.
  defp checked(row, attrs, indexer, mac_key, extra \\ nil) do
    refusals =
      attrs |> Map.put("name", row.name) |> ConfiguredIndexer.create_changeset() |> refusals()

    if refusals == [] do
      plan =
        Map.merge(
          %{
            state: row.state,
            reasons: row.reasons,
            key: row.key,
            attrs: attrs,
            secrets_mac: mac(mac_key, Map.get(indexer.fields, "apiKey"))
          },
          extra || %{}
        )

      %{row | plan: plan, tickable: true}
    else
      planned(%{
        row
        | state: :refused,
          reasons: refusals |> Enum.uniq() |> Enum.sort(),
          type: nil,
          key: nil,
          default_ticked: false,
          secret_inputs: [],
          notes: []
      })
    end
  end

  defp planned(row), do: %{row | plan: %{state: row.state, reasons: row.reasons}}

  # The stored URL and key, and each ticked row of the preview, must match what Prowlarr answers
  # now. A ticked id the preview does not hold is the choices' error, not a change.
  defp unchanged(preview, fresh, ticked, read, connection) do
    old = Map.new(preview.rows, &{&1.prowlarr_id, &1.plan})
    new = Map.new(fresh.rows, &{&1.prowlarr_id, &1.plan})

    same? =
      preview.source_mac == fresh.source_mac and
        preview.flaresolverr_host == fresh.flaresolverr_host and
        Enum.all?(ticked, fn id -> not Map.has_key?(old, id) or old[id] == new[id] end)

    if same?, do: :ok, else: {:error, {:changed, build(read, connection, new_mac_key())}}
  end

  # A ticked id the preview did not show is not importable, even once Prowlarr lists it.
  defp entries(preview, fresh, choices, ticked, read, connection) do
    shown = MapSet.new(preview.rows, & &1.prowlarr_id)
    rows = for row <- fresh.rows, row.prowlarr_id in shown, into: %{}, do: {row.prowlarr_id, row}
    order = Map.new(Enum.with_index(fresh.rows), fn {row, index} -> {row.prowlarr_id, index} end)
    ticked = Enum.sort_by(ticked, &Map.get(order, &1, :infinity))
    chosen_names = Enum.frequencies(for id <- ticked, do: name(choices[id]))

    results =
      for id <- ticked do
        {id, entry(rows[id], choices[id], read, chosen_names, connection)}
      end

    case for({id, {:error, codes}} <- results, into: %{}, do: {id, codes}) do
      errors when errors == %{} -> {:ok, for({_id, {:ok, entry}} <- results, do: entry)}
      errors -> {:error, {:rows, errors}}
    end
  end

  defp name(%{name: name}) when is_binary(name), do: String.trim(name)
  defp name(_choice), do: ""

  defp entry(%Row{tickable: true} = row, choice, read, chosen_names, connection) do
    name = name(choice)

    codes =
      mode_errors(row, choice) ++
        name_errors(name, read.names, chosen_names) ++ secret_errors(row, choice)

    if codes == [],
      do: {:ok, build_entry(row, choice, name, {read, connection})},
      else: {:error, codes}
  end

  defp entry(_row, _choice, _names, _chosen_names, _connection), do: {:error, [:not_importable]}

  defp mode_errors(%Row{state: :via_prowlarr}, %{via_prowlarr: true}), do: []
  defp mode_errors(%Row{state: :via_prowlarr}, _choice), do: [:via_prowlarr_not_chosen]
  defp mode_errors(%Row{state: :direct}, %{via_prowlarr: true}), do: [:via_prowlarr_not_offered]
  defp mode_errors(_row, _choice), do: []

  defp name_errors("", _names, _chosen), do: [:name_required]

  defp name_errors(name, names, chosen) do
    if(name in names, do: [:name_taken], else: []) ++
      if Map.get(chosen, name, 0) > 1, do: [:name_duplicate], else: []
  end

  # A through-Prowlarr row takes the stored Prowlarr key, so its typed secrets are not read. A
  # Cardigann row reads only the secrets Prowlarr masks.
  defp secret_errors(%Row{state: :direct, type: :cardigann} = row, choice) do
    case typed_secrets(row, choice) do
      {:ok, _values} -> []
      {:error, :invalid} -> [:settings_invalid]
    end
  end

  defp secret_errors(%Row{state: :direct}, choice) do
    case typed_key(choice) do
      {:error, :invalid} -> [:secret_invalid]
      _key -> []
    end
  end

  defp secret_errors(_row, _choice), do: []

  defp typed_key(choice), do: choice |> Map.get(:secrets, %{}) |> merged_key()

  defp merged_key(secrets) when is_map(secrets) do
    case Secrets.merge({:ok, %{}}, secrets, ["api_key"]) do
      :unchanged -> :none
      {:changed, %{"api_key" => key}, _fields} -> {:ok, key}
      {:error, _tag} -> {:error, :invalid}
    end
  end

  defp merged_key(_secrets), do: {:error, :invalid}

  defp typed_secrets(row, choice),
    do: choice |> Map.get(:secrets, %{}) |> merged_secrets(row.plan.masked)

  # Each key a masked setting and each value text; a blank value is no value.
  defp merged_secrets(secrets, fields) when is_map(secrets) do
    if Enum.all?(secrets, fn {field, value} -> field in fields and text?(value) end),
      do:
        {:ok,
         for({field, value} <- secrets, String.trim(value) != "", into: %{}, do: {field, value})},
      else: {:error, :invalid}
  end

  defp merged_secrets(_secrets, _fields), do: {:error, :invalid}

  defp text?(value), do: is_binary(value) and String.valid?(value)

  defp build_entry(%Row{state: :via_prowlarr} = row, _choice, name, {_read, connection}) do
    %{
      prowlarr_id: row.prowlarr_id,
      attrs: Map.put(row.plan.attrs, "name", name),
      secrets: %{"api_key" => connection.api_key},
      notes: []
    }
  end

  # The clear secrets come from the commit's own read of Prowlarr, whose plan matched the
  # preview's; a masked one left blank creates the indexer disabled.
  defp build_entry(%Row{state: :direct, type: :cardigann} = row, choice, name, {read, _conn}) do
    {:ok, typed} = typed_secrets(row, choice)
    values = Enum.find(read.indexers, &(&1.id == row.prowlarr_id)).cardigann.values
    secrets = Map.merge(Map.take(values, row.plan.clear), typed)

    missing =
      for %{field: field, label: label} <- row.secret_inputs,
          field not in Map.keys(typed),
          do: label

    attrs = Map.put(row.plan.attrs, "name", name)

    {attrs, disabled} =
      if missing == [],
        do: {attrs, []},
        else: {Map.put(attrs, "enabled", false), [{:secrets_not_entered, missing}]}

    %{prowlarr_id: row.prowlarr_id, attrs: attrs, secrets: secrets, notes: disabled ++ row.notes}
  end

  defp build_entry(%Row{state: :direct} = row, choice, name, _read_connection) do
    attrs = Map.put(row.plan.attrs, "name", name)

    case {row.key, typed_key(choice)} do
      {_key, {:ok, key}} ->
        %{prowlarr_id: row.prowlarr_id, attrs: attrs, secrets: %{"api_key" => key}, notes: []}

      {:masked, :none} ->
        %{
          prowlarr_id: row.prowlarr_id,
          attrs: Map.put(attrs, "enabled", false),
          secrets: %{},
          notes: [:created_disabled_no_key]
        }

      {:none, :none} ->
        %{prowlarr_id: row.prowlarr_id, attrs: attrs, secrets: %{}, notes: []}
    end
  end

  defp create(actor, entries) do
    batch = Enum.map(entries, &Map.take(&1, [:prowlarr_id, :attrs, :secrets]))

    case Indexers.import_batch(actor, batch) do
      {:ok, created} -> {:ok, created}
      {:error, {:rows, _errors}} = error -> error
      {:error, %Ecto.Changeset{}} -> {:error, :audit_refused}
    end
  end

  defp report(created, entries, saved?) do
    notes = Map.new(entries, &{&1.prowlarr_id, &1.notes})
    url? = FlareSolverrUrl.get() != nil

    %{
      created:
        Enum.map(created, fn row ->
          not_set = if row.flaresolverr and not url?, do: [:flaresolverr_url_not_set], else: []

          %{
            id: row.id,
            prowlarr_id: row.prowlarr_indexer_id,
            name: row.name,
            enabled: row.enabled,
            notes: Map.fetch!(notes, row.prowlarr_indexer_id) ++ not_set
          }
        end),
      flaresolverr_url_saved: saved?,
      tests_started: for(row <- created, row.enabled, start_test(row.id) == :ok, do: row.id)
    }
  end

  # The import has committed, so a runner that is down or busy only leaves that Test unstarted.
  defp start_test(id) do
    TestRunner.start(id)
  catch
    :exit, _reason -> {:error, :runner_down}
  end
end
