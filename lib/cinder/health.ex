defmodule Cinder.Health do
  @moduledoc """
  Reachability checks for the probe targets the pipeline depends on: external services (metadata
  providers, indexer, download clients, media servers, migration sources, notifiers), library
  roots and local tools. Each check resolves the configured impl behind its behaviour at check
  time and calls its `health/0`; a library root is checked by writing to it.

  `targets/1` is the one list of targets. The `/settings` Test buttons, the `/setup` gate and the
  `/dashboard` service-health rows all read it, so a new adapter with a `health/0` is one entry
  here. Each external `health/0` keeps 3-second connect and receive timeouts; `check_all/0`'s
  backstop only guards against a probe that ignores its own.

  `check_all/0` runs every probe concurrently (`Task.async_stream/3`), so the sweep's wall clock
  is bounded by the slowest configured row instead of the sum of every row's own timeout.
  """
  alias Cinder.Books.Metadata
  alias Cinder.Download
  alias Cinder.Health.Target
  alias Cinder.Library.SidecarQuarantine
  alias Cinder.LibraryKind
  alias Cinder.Settings.Registry

  # Backstop above the worst individual probe today (~12s: qBittorrent/SABnzbd's login + probe
  # round trip, or Plex's 2 video kinds × 6s) — the normal bound is each impl's own timeout, this
  # only guards against a probe that ignores its own timeout and hangs outright. Overridable via
  # `:health_probe_timeout_ms` so tests can shrink it instead of waiting out the real default.
  @probe_timeout_ms 15_000

  # TMDB drives discovery, requests, and the monitored-series refresh; the indexer drives every
  # search. Setup cannot finish without either.
  @service_targets [
    %Target{id: "tmdb", group: :tmdb, label: "TMDB", probe: {:env, :tmdb}, setup: :required},
    %Target{
      id: "indexer",
      group: :indexer,
      label: "Prowlarr",
      probe: {:env, :indexer},
      setup: :required
    }
  ]

  # Optional adoption sources: a Test button each, no dashboard row.
  @migration_targets (for source <- Registry.migration_sources() do
                        %Target{
                          id: source.key,
                          group: :migration,
                          label: source.name,
                          probe: {:migration_source, String.to_atom(source.key)},
                          dashboard: :never
                        }
                      end)

  # One client per protocol; setup needs at least one, and a disabled protocol has no row.
  @download_targets (for choice <- Registry.download_client_choices() do
                       %Target{
                         id: Atom.to_string(choice.protocol),
                         group: :download,
                         label: choice.label,
                         probe: {:download, choice.protocol},
                         setup: :any,
                         dashboard: :configured
                       }
                     end)

  @server_targets [
    %Target{
      id: "media_server",
      group: :media_server,
      label: "Media server",
      probe: {:env, :media_server},
      setup: :required
    },
    %Target{
      id: "audiobook_server",
      group: :audiobook_server,
      label: "Audiobookshelf",
      probe: {:env, :audiobook_server}
    }
  ]

  # Setup needs a writable root for every kind. A missing video root shows red on the dashboard,
  # the visible signal that imports are holding; a book root has no row until it is set.
  @library_targets (for kind <- LibraryKind.all() do
                      %Target{
                        id: "#{kind}_library",
                        group: :library,
                        label: "#{LibraryKind.label(kind)} library",
                        probe: {:library, kind},
                        setup: :required,
                        dashboard: if(LibraryKind.video?(kind), do: :always, else: :configured)
                      }
                    end)

  @feature_targets [
    # `config :cinder, media_info: nil` turns ffprobe verification off on purpose: no row, not
    # red noise on an install that disabled it.
    %Target{
      id: "media_info",
      group: :library,
      label: "Media info (ffprobe)",
      probe: {:env, :media_info},
      dashboard: :configured
    },
    # Off by default: with no api_key the row stays hidden.
    %Target{
      id: "subtitles",
      group: :subtitles,
      label: "OpenSubtitles",
      probe: :subtitles,
      dashboard: :configured
    },
    %Target{
      id: "openlibrary",
      group: :books,
      label: "Open Library",
      probe: {:books_metadata, :openlibrary}
    },
    %Target{
      id: "hardcover",
      group: :books,
      label: "Hardcover",
      probe: {:books_metadata, :hardcover}
    },
    %Target{
      id: "discord",
      group: :notifications,
      label: "Discord",
      probe: {:module, Cinder.Notifier.Discord},
      dashboard: :never
    }
  ]

  # In `Registry.groups/0` order, which is the order of the Test buttons and the dashboard rows.
  @targets @service_targets ++
             @migration_targets ++
             @download_targets ++
             @server_targets ++ @library_targets ++ @feature_targets

  # Dashboard rows that report a finding rather than probe a target.
  @stored_credentials %{id: "stored_credentials", label: "Stored credentials"}
  @sidecar_files %{id: "sidecar_files", label: "Sidecar files"}

  @doc """
  The probe targets in `/settings` group order, optionally filtered by field
  (`group:`, `setup:`, `dashboard:`, `probe:` or `id:`). Pure: it reads no config and calls no
  adapter, so a page can render every Test button without touching a service.
  """
  @spec targets(keyword()) :: [Target.t()]
  def targets(filter \\ [])
  def targets([]), do: @targets

  def targets(filter) do
    Enum.filter(@targets, fn target ->
      Enum.all?(filter, fn {field, value} -> Map.fetch!(target, field) == value end)
    end)
  end

  @doc """
  Checks one target, by id, against the currently applied config. Never raises: a failure while
  resolving the adapter or inside its `health/0` is an `{:error, reason}`. A target with nothing
  wired is `{:error, :not_configured}`; an id no target has is `{:error, :unknown_target}` (the id
  comes from the client, so callers ignore it).
  """
  @spec check(term()) :: :ok | {:warning, term()} | {:error, term()}
  def check(id) do
    case Enum.find(@targets, &(&1.id == id)) do
      nil -> {:error, :unknown_target}
      target -> run_target(target)
    end
  end

  @doc """
  Checks every dashboard target concurrently and returns a list of
  `%{id: String.t(), label: String.t(), adapter: String.t() | nil, status: status}` in
  `targets/0` order, followed by the stored-credentials and retained-sidecar findings. `label` is
  an English msgid. `adapter` names the wired module where the operator picks one (download
  clients, the media server), even when its probe fails or times out. A `:configured` target that
  is not configured, and a finding with nothing to report, have no row. A probe that exceeds the
  timeout budget reports `{:error, :timeout}` for its row without affecting any other row.
  """
  def check_all do
    probes = dashboard_probes()
    timeout = Application.get_env(:cinder, :health_probe_timeout_ms, @probe_timeout_ms)

    probes
    |> Task.async_stream(fn {_row, fun} -> fun.() end,
      ordered: true,
      max_concurrency: length(probes),
      on_timeout: :kill_task,
      timeout: timeout
    )
    |> Enum.zip(probes)
    |> Enum.reduce([], fn
      {{:ok, :skip}, _probe}, rows ->
        rows

      {{:ok, status}, {row, _fun}}, rows ->
        [Map.put(row, :status, status) | rows]

      {{:exit, :timeout}, {row, _fun}}, rows ->
        [Map.put(row, :status, {:error, :timeout}) | rows]

      {{:exit, reason}, {row, _fun}}, rows ->
        [Map.put(row, :status, {:error, reason}) | rows]
    end)
    |> Enum.reverse()
  end

  @doc """
  Every English string `targets/0` and `check_all/0` can hand the view.
  `CinderWeb.SettingsLabels.known/0` registers them for translation.
  """
  def msgids,
    do:
      Enum.uniq(
        Enum.map(@targets, & &1.label) ++ [@stored_credentials.label, @sidecar_files.label]
      )

  # Ordered `{row, fun}` pairs: the row's id, label and adapter are known upfront (cheap, no
  # network); `fun` is a 0-arity closure that runs the probe and returns `status | :skip`.
  # `check_all/0` fans these out through `Task.async_stream/3`.
  defp dashboard_probes do
    for(
      %Target{dashboard: policy} = target <- @targets,
      policy != :never,
      do:
        {row(target.id, target.label, chosen_adapter(target)), fn -> dashboard_status(target) end}
    ) ++
      [
        {row(@stored_credentials.id, @stored_credentials.label, nil), &stored_credentials/0},
        {row(@sidecar_files.id, @sidecar_files.label, nil), &sidecar_files/0}
      ]
  end

  defp row(id, label, adapter), do: %{id: id, label: label, adapter: adapter}

  defp dashboard_status(%Target{dashboard: policy} = target) do
    case run_target(target) do
      {:error, :not_configured} when policy == :configured -> :skip
      status -> status
    end
  end

  # The operator picks these adapters in /settings, so the row names the one that is wired, even
  # when its probe times out. Every other target has one adapter, which its label already names.
  # Resolving them only reads config.
  defp chosen_adapter(%Target{probe: {:download, _} = probe}), do: adapter_name(probe)
  defp chosen_adapter(%Target{probe: {:env, :media_server} = probe}), do: adapter_name(probe)
  defp chosen_adapter(_target), do: nil

  defp adapter_name(probe) do
    case safely(fn -> resolve(probe) end) do
      {:ok, mod} -> short(mod)
      _not_configured -> nil
    end
  end

  # Resolution runs inside `safely/1` too: it calls into config and, for the books providers,
  # into each adapter's `provider/0`.
  defp run_target(%Target{probe: probe}) do
    case safely(fn -> resolve(probe) end) do
      {:ok, mod} -> run(mod)
      {:path, path} -> library_writable(path)
      {:error, _reason} = error -> error
    end
  end

  defp resolve({:env, key}), do: present(Application.get_env(:cinder, key))
  defp resolve({:module, mod}), do: {:ok, mod}
  defp resolve({:download, protocol}), do: found(Download.client_for(protocol))

  defp resolve({:migration_source, source}),
    do: found(Map.fetch(Application.fetch_env!(:cinder, :migration_sources), source))

  defp resolve({:books_metadata, provider}),
    do: present(Enum.find(Metadata.providers(), &(&1.provider() == provider)))

  defp resolve({:library, kind}) do
    case Cinder.Settings.configured_library_path(kind) do
      nil -> {:error, :not_configured}
      path -> {:path, path}
    end
  end

  defp resolve(:subtitles) do
    provider = Application.get_env(:cinder, :subtitles_provider)

    case provider && Application.get_env(:cinder, provider, [])[:api_key] do
      blank when blank in [nil, false, ""] -> {:error, :not_configured}
      _api_key -> {:ok, provider}
    end
  end

  defp present(nil), do: {:error, :not_configured}
  defp present(mod), do: {:ok, mod}

  defp found({:ok, mod}), do: {:ok, mod}
  defp found(:error), do: {:error, :not_configured}

  # A stored secret that can't be decrypted (SECRET_KEY_BASE changed) is skipped at load, so every
  # service row above can read green while the pipeline is actually credential-less. Surface it as
  # its own red row naming the count; skip the row entirely when every secret decodes. Reads the
  # DB, so it goes through `safely/1` — a checkout failure (or anything else) degrades to "no
  # finding" rather than taking the whole panel down.
  #
  # This runs inside the same `Task.async_stream/3` sweep as every other probe, not inline in the
  # caller. `Cinder.Repo`'s Ecto SQL Sandbox ownership (via `DBConnection.Ownership`) resolves the
  # checked-out connection through the `$callers` process-dictionary chain that `Task` sets on the
  # spawned process — the same mechanism Mox's private mode already relies on for `run/1`'s
  # network probes — so no sandbox allowance is needed here.
  defp stored_credentials do
    case safely(fn -> Cinder.Settings.undecryptable_secret_keys() end) do
      keys when is_list(keys) and keys != [] ->
        {:error, {:undecryptable_secrets, length(keys)}}

      _ ->
        :skip
    end
  end

  # Issue #585: `Cinder.Library.Sidecars` retains a sidecar it can't prove it owns by renaming it
  # to an unguessable `.cinder-sidecar-quarantine-*` name and logging it, but nothing sweeps that
  # prefix and the log line is the only trace. `PathPolicy.walk/2` hard-caps at 100_000 entries
  # and this probe runs on every `/dashboard` mount via `start_async`, so it can't recover those
  # paths by walking the library — it only reads what `SidecarQuarantine.record/3` recorded at
  # the moment retention happened. Reads the DB, so — like `stored_credentials/0` — it goes
  # through `safely/1` and degrades to `:skip` on anything unexpected rather than taking the panel
  # down.
  defp sidecar_files do
    case safely(fn -> SidecarQuarantine.list_present() end) do
      [] ->
        :skip

      rows when is_list(rows) ->
        {:warning, {:retained_sidecars, Enum.map(rows, & &1.path)}}

      _error ->
        :skip
    end
  end

  # Probes run inside a LiveView async task or event handler, so a misbehaving impl must degrade
  # to a red row rather than take the page down. `catch` covers exits/throws (e.g. a
  # pool-checkout timeout deep in the HTTP stack) that `rescue` would miss.
  defp safely(fun) do
    fun.()
  rescue
    e -> {:error, e}
  catch
    kind, value -> {:error, {kind, value}}
  end

  defp run(mod) do
    safely(fn ->
      case mod.health() do
        :ok -> :ok
        {:warning, _} = warning -> warning
        {:error, _} = err -> err
      end
    end)
  end

  # The library import target isn't a behaviour with health/0; "reachable" means the
  # configured path is writable. `mkdir_p` alone doesn't prove that: it's a no-op on an
  # existing directory, so a read-only mount or a Docker UID/GID mismatch reports healthy
  # while every import then fails. Actually create and remove a uniquely named, disposable
  # entry through the same Filesystem behaviour the import uses (mockable in tests).
  defp library_writable(path) do
    safely(fn ->
      fs = Application.fetch_env!(:cinder, :filesystem)
      probe = Path.join(path, ".cinder-health-probe-#{System.unique_integer([:positive])}")

      with :ok <- fs.mkdir_p(path),
           :ok <- fs.write_exclusive(probe, "") do
        fs.rm(probe)
        :ok
      end
    end)
  end

  defp short(mod), do: mod |> Module.split() |> List.last()
end
