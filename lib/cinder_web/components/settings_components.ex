defmodule CinderWeb.SettingsComponents do
  @moduledoc """
  Shared rendering for the grouped external-service config fields, used by both the
  `/settings` page and the first-run `/setup` wizard. The parent LiveView owns the
  `"test"` event and supplies `form` (from `Settings.form_state/0`) and `health`
  (a `%{service_key => :ok | {:error, term()}}` map).
  """
  use Phoenix.Component
  use Gettext, backend: CinderWeb.Gettext

  import CinderWeb.CoreComponents, only: [status_badge: 1, button: 1, icon: 1, input: 1]

  alias Cinder.{LibraryKind, Settings}
  alias CinderWeb.SettingsLabels

  @doc """
  The flash message for a rejected size-band save (`Settings.save_form/1` returning
  `{:error, invalid_keys}`) — shared by `/settings` and `/setup` so the copy can't drift.
  """
  def invalid_band_message(invalid_keys) do
    gettext("Not saved. Check: %{fields}.",
      fields: Enum.map_join(invalid_keys, ", ", &invalid_field_label/1)
    )
  end

  defp invalid_groups(keys) do
    anime_keys = MapSet.new(Settings.anime_fields(), & &1.key)

    download_keys =
      Settings.download_fields()
      |> Enum.map(& &1.key)
      |> Kernel.++(Enum.map(Settings.download_client_choices(), & &1.key))
      |> MapSet.new()

    keys
    |> Enum.map(fn key ->
      cond do
        key == "household_timezone" -> :accounts
        key == Settings.import_roots_key() -> :library
        library_path_key?(key) -> :library
        MapSet.member?(anime_keys, key) -> :anime
        MapSet.member?(download_keys, key) -> :download
        true -> :releases
      end
    end)
    |> MapSet.new()
  end

  attr :form, :map, required: true
  attr :health, :map, required: true
  # move_on_import is a /settings-only advanced toggle; the first-run wizard passes false
  # so it isn't offered before the operator has validated a real import (spec: settings-only).
  attr :show_move_on_import, :boolean, default: true
  attr :show_anime, :boolean, default: true
  attr :show_setup_guidance, :boolean, default: false

  def service_fields(assigns) do
    [{first_group, _label} | _groups] = Settings.groups()

    assigns =
      assigns
      |> assign(:first_group, first_group)
      |> assign(:invalid_groups, invalid_groups(assigns.form.invalid_keys))

    ~H"""
    <details
      :for={{group, label} <- Settings.groups()}
      id={"settings-group-#{group}"}
      open={group == @first_group or MapSet.member?(@invalid_groups, group)}
      phx-hook="DisclosureState"
      data-force-open={to_string(MapSet.member?(@invalid_groups, group))}
      data-setup-step={@show_setup_guidance && setup_step(group)}
      data-setup-optional={@show_setup_guidance && to_string(is_nil(setup_step(group)))}
      class="collapse collapse-arrow rounded-box bg-base-200"
    >
      <summary class="collapse-title flex min-h-11 cursor-pointer items-center gap-2 text-lg font-semibold focus-visible:outline-2 focus-visible:outline-primary">
        <span
          :if={@show_setup_guidance && setup_step(group)}
          class="badge badge-primary badge-sm font-bold"
        >
          {setup_step(group)}
        </span>
        <span>{SettingsLabels.t(label)}</span>
        <span
          :if={@show_setup_guidance && is_nil(setup_step(group))}
          class="badge badge-ghost badge-sm font-normal"
        >
          {gettext("Optional")}
        </span>
      </summary>

      <div class="collapse-content">
        <.setup_section_help :if={@show_setup_guidance} group={group} />

        <div :if={group == :media_server} class="form-control mb-2">
          <label class="label" for="media_server_type">
            <span class="label-text">{gettext("Media server type")}</span>
          </label>
          <select id="media_server_type" name="media_server_type" class="select w-full">
            <option
              :for={opt <- Settings.media_server_options()}
              value={opt}
              selected={@form.values[Settings.media_server_key()] == opt}
            >
              {opt}
            </option>
          </select>
        </div>

        <div :if={group == :download} class="mb-3 grid gap-3 sm:grid-cols-2">
          <div :for={choice <- Settings.download_client_choices()} class="form-control">
            <label class="label" for={choice.key}>
              <span class="label-text">{SettingsLabels.t(choice.label)}</span>
            </label>
            <select
              id={choice.key}
              name={choice.key}
              aria-invalid={invalid?(@form, choice.key) && "true"}
              aria-describedby={invalid?(@form, choice.key) && "#{choice.key}-error"}
              class={["select w-full", invalid?(@form, choice.key) && "select-error"]}
            >
              <option
                :for={option <- choice.options}
                value={option.value}
                selected={@form.values[choice.key] == option.value}
              >
                {SettingsLabels.t(option.label)}
              </option>
            </select>
            <.field_error :if={invalid?(@form, choice.key)} field={choice.key} />
          </div>
        </div>

        <div :if={group == :library} class="space-y-2">
          <div class="form-control">
            <label class="label" for={Settings.import_roots_key()}>
              <span class="label-text">{gettext("Download folders")}</span>
            </label>
            <textarea
              id={Settings.import_roots_key()}
              name={Settings.import_roots_key()}
              placeholder={gettext("/media/downloads")}
              autocomplete="off"
              class={[
                "textarea w-full",
                invalid?(@form, Settings.import_roots_key()) && "textarea-error"
              ]}
              aria-invalid={invalid?(@form, Settings.import_roots_key()) && "true"}
              aria-describedby={
                if invalid?(@form, Settings.import_roots_key()),
                  do: "#{Settings.import_roots_key()}-help #{Settings.import_roots_key()}-error",
                  else: "#{Settings.import_roots_key()}-help"
              }
            >{@form.values[Settings.import_roots_key()]}</textarea>
            <.field_error
              :if={invalid?(@form, Settings.import_roots_key())}
              field={Settings.import_roots_key()}
            />
            <p id={"#{Settings.import_roots_key()}-help"} class="mt-1 text-xs opacity-70">
              {gettext(
                "Folders where your download clients save completed files. Separate multiple folders with commas or new lines. Do not use /, the top-level folder."
              )}
            </p>
          </div>

          <div
            :for={%{kind: kind, label: kind_label, video?: video?} <- Settings.library_kinds()}
            class="space-y-2"
          >
            <div class="form-control">
              <label class="label" for={Settings.library_path_key(kind)}>
                <span class="label-text">{gettext("%{kind} library folder",
                  kind: SettingsLabels.t(kind_label)
                )}</span>
              </label>
              <input
                type="text"
                id={Settings.library_path_key(kind)}
                name={Settings.library_path_key(kind)}
                value={@form.values[Settings.library_path_key(kind)]}
                placeholder={
                  @form.placeholders[Settings.library_path_key(kind)] ||
                    "/media/#{LibraryKind.root_role(kind)}"
                }
                autocomplete="off"
                aria-invalid={invalid?(@form, Settings.library_path_key(kind)) && "true"}
                aria-describedby={
                  if invalid?(@form, Settings.library_path_key(kind)),
                    do: "library-paths-help #{Settings.library_path_key(kind)}-error",
                    else: "library-paths-help"
                }
                class={[
                  "input w-full",
                  invalid?(@form, Settings.library_path_key(kind)) && "input-error"
                ]}
              />
              <.field_error
                :if={invalid?(@form, Settings.library_path_key(kind))}
                field={Settings.library_path_key(kind)}
              />
            </div>

            <div :if={video?} class="form-control">
              <label class="label" for={Settings.anime_library_path_key(kind)}>
                <span class="label-text">
                  {gettext("Anime %{kind} library folder (optional)",
                    kind: SettingsLabels.t(kind_label)
                  )}
                </span>
              </label>
              <input
                type="text"
                id={Settings.anime_library_path_key(kind)}
                name={Settings.anime_library_path_key(kind)}
                value={@form.values[Settings.anime_library_path_key(kind)]}
                placeholder={
                  gettext("Uses the standard %{kind} folder", kind: SettingsLabels.t(kind_label))
                }
                autocomplete="off"
                aria-invalid={invalid?(@form, Settings.anime_library_path_key(kind)) && "true"}
                aria-describedby={
                  if invalid?(@form, Settings.anime_library_path_key(kind)),
                    do:
                      "#{Settings.anime_library_path_key(kind)}-help #{Settings.anime_library_path_key(kind)}-error",
                    else: "#{Settings.anime_library_path_key(kind)}-help"
                }
                class={[
                  "input w-full",
                  invalid?(@form, Settings.anime_library_path_key(kind)) && "input-error"
                ]}
              />
              <.field_error
                :if={invalid?(@form, Settings.anime_library_path_key(kind))}
                field={Settings.anime_library_path_key(kind)}
              />
              <p
                id={"#{Settings.anime_library_path_key(kind)}-help"}
                class="mt-1 text-xs opacity-70"
              >
                {gettext(
                  "Titles explicitly using the Anime profile import here. Leave blank to use the standard folder."
                )}
              </p>
            </div>
          </div>
          <p id="library-paths-help" class="mt-1 text-xs opacity-70">
            {gettext(
              "Choose a folder for each library so Jellyfin or Plex can keep movies and TV separate. If they share a folder, enter the same path for both. When possible, Cinder reuses the download's disk space instead of making another full copy."
            )}
          </p>

          <div :if={@show_move_on_import}>
            <label class="label cursor-pointer justify-start gap-2 pt-2">
              <input type="hidden" name="move_on_import" value="false" />
              <input
                type="checkbox"
                name="move_on_import"
                value="true"
                checked={@form.values["move_on_import"]}
                aria-describedby="move_on_import-help"
                class="checkbox"
              />
              <span class="label-text">{gettext("Remove download after a Usenet import")}</span>
            </label>
            <p id="move_on_import-help" class="mt-1 text-xs opacity-70">
              {gettext(
                "After a Usenet import, delete the original from the download client. Ensure your library is a separate folder from your downloads. Torrents keep seeding unless you configure completed-torrent limits below."
              )}
            </p>
          </div>

          <div class="form-control pt-2">
            <label class="label" for={Settings.ffprobe_bin_key()}>
              <span class="label-text">{gettext("ffprobe media analysis tool")}</span>
            </label>
            <input
              type="text"
              id={Settings.ffprobe_bin_key()}
              name={Settings.ffprobe_bin_key()}
              value={@form.values[Settings.ffprobe_bin_key()]}
              placeholder={@form.placeholders[Settings.ffprobe_bin_key()] || "ffprobe"}
              autocomplete="off"
              aria-describedby={"#{Settings.ffprobe_bin_key()}-help"}
              class="input w-full"
            />
            <p id={"#{Settings.ffprobe_bin_key()}-help"} class="mt-1 text-xs opacity-70">
              {gettext(
                "Cinder uses ffprobe to check audio and subtitle languages after import. Leave blank to use ffprobe already available to Cinder."
              )}
            </p>
          </div>
        </div>

        <div :if={group == :releases} class="space-y-3">
          <div
            :for={%{kind: kind, label: kind_label, video?: true} <- Settings.library_kinds()}
            class="space-y-2"
          >
            <p class="text-sm font-medium">{SettingsLabels.t(kind_label)}</p>
            <div class="form-control">
              <label class="label" for={Settings.min_size_key(kind)}>
                <span class="label-text">{gettext("Min size (GB)")}</span>
              </label>
              <input
                type="text"
                id={Settings.min_size_key(kind)}
                name={Settings.min_size_key(kind)}
                value={@form.values[Settings.min_size_key(kind)]}
                inputmode="decimal"
                autocomplete="off"
                class={[
                  "input w-full",
                  invalid?(@form, Settings.min_size_key(kind)) && "input-error"
                ]}
                aria-invalid={invalid?(@form, Settings.min_size_key(kind)) && "true"}
                aria-describedby={
                  invalid?(@form, Settings.min_size_key(kind)) &&
                    "#{Settings.min_size_key(kind)}-error"
                }
              />
              <.field_error
                :if={invalid?(@form, Settings.min_size_key(kind))}
                field={Settings.min_size_key(kind)}
              />
            </div>
            <div class="form-control">
              <label class="label" for={Settings.max_size_key(kind)}>
                <span class="label-text">{gettext("Max size (GB)")}</span>
              </label>
              <input
                type="text"
                id={Settings.max_size_key(kind)}
                name={Settings.max_size_key(kind)}
                value={@form.values[Settings.max_size_key(kind)]}
                inputmode="decimal"
                autocomplete="off"
                class={[
                  "input w-full",
                  invalid?(@form, Settings.max_size_key(kind)) && "input-error"
                ]}
                aria-invalid={invalid?(@form, Settings.max_size_key(kind)) && "true"}
                aria-describedby={
                  invalid?(@form, Settings.max_size_key(kind)) &&
                    "#{Settings.max_size_key(kind)}-error"
                }
              />
              <.field_error
                :if={invalid?(@form, Settings.max_size_key(kind))}
                field={Settings.max_size_key(kind)}
              />
            </div>
            <div class="form-control">
              <label class="label" for={Settings.preferred_resolutions_key(kind)}>
                <span class="label-text">{gettext("Preferred resolutions (comma-separated)")}</span>
              </label>
              <input
                type="text"
                id={Settings.preferred_resolutions_key(kind)}
                name={Settings.preferred_resolutions_key(kind)}
                value={@form.values[Settings.preferred_resolutions_key(kind)]}
                placeholder={gettext("1080p, 720p")}
                autocomplete="off"
                class="input w-full"
              />
            </div>
            <div class="form-control">
              <label class="label" for={Settings.preferred_sources_key(kind)}>
                <span class="label-text">{gettext("Preferred sources (comma-separated)")}</span>
              </label>
              <input
                type="text"
                id={Settings.preferred_sources_key(kind)}
                name={Settings.preferred_sources_key(kind)}
                value={@form.values[Settings.preferred_sources_key(kind)]}
                placeholder={gettext("bluray, webdl")}
                autocomplete="off"
                class="input w-full"
              />
            </div>
            <div class="form-control">
              <label class="label" for={Settings.preferred_terms_key(kind)}>
                <span class="label-text">{gettext("Preferred terms (comma-separated)")}</span>
              </label>
              <input
                type="text"
                id={Settings.preferred_terms_key(kind)}
                name={Settings.preferred_terms_key(kind)}
                value={@form.values[Settings.preferred_terms_key(kind)]}
                placeholder={gettext("proper, repack")}
                autocomplete="off"
                class="input w-full"
              />
            </div>
            <div class="form-control">
              <label class="label" for={Settings.blocked_terms_key(kind)}>
                <span class="label-text">{gettext("Blocked terms (comma-separated)")}</span>
              </label>
              <input
                type="text"
                id={Settings.blocked_terms_key(kind)}
                name={Settings.blocked_terms_key(kind)}
                value={@form.values[Settings.blocked_terms_key(kind)]}
                placeholder={gettext("cam, telesync")}
                autocomplete="off"
                class="input w-full"
              />
            </div>
            <div class="form-control">
              <label class="label" for={Settings.upgrade_cutoff_key(kind)}>
                <span class="label-text">{gettext("Automatic upgrade cutoff")}</span>
              </label>
              <select
                id={Settings.upgrade_cutoff_key(kind)}
                name={Settings.upgrade_cutoff_key(kind)}
                class={[
                  "select w-full",
                  invalid?(@form, Settings.upgrade_cutoff_key(kind)) && "select-error"
                ]}
                aria-invalid={invalid?(@form, Settings.upgrade_cutoff_key(kind)) && "true"}
                aria-describedby={
                  invalid?(@form, Settings.upgrade_cutoff_key(kind)) &&
                    "#{Settings.upgrade_cutoff_key(kind)}-error"
                }
              >
                <option value="" selected={@form.values[Settings.upgrade_cutoff_key(kind)] == ""}>
                  {gettext("No cutoff")}
                </option>
                <option
                  :for={resolution <- Settings.release_resolutions()}
                  value={resolution}
                  selected={@form.values[Settings.upgrade_cutoff_key(kind)] == resolution}
                >
                  {resolution}
                </option>
              </select>
              <.field_error
                :if={invalid?(@form, Settings.upgrade_cutoff_key(kind))}
                field={Settings.upgrade_cutoff_key(kind)}
              />
            </div>
          </div>
          <p class="mt-1 text-xs opacity-70">
            {gettext("Sizes are decimal GB (1 GB = 1,000,000,000 bytes). For TV they apply")} <strong>{gettext("per episode")}</strong>{gettext(
              ": a season pack of N episodes is allowed up to N× the max. Defaults: Movies 0.3–15 GB, TV 0.05–4 GB per episode. Leave blank for the default; enter 0 for no limit."
            )}
            {gettext(
              "Sources: remux, bluray, webrip, webdl, hdtv, dvd, cam. Leave blank to accept any; untagged releases are always kept. These are distinct; listing only bluray excludes remux, so add both to accept either."
            )}
            {gettext(
              "Preferred terms are ranked in listed order; blocked terms reject titles containing a phrase (case-insensitive). The cutoff stops automatic movie searches at that resolution, and TV season searches once every held episode reaches it. Manual search stays available."
            )}
          </p>
        </div>

        <div :if={group == :notifications} class="mb-3">
          <label class="label cursor-pointer justify-start gap-2">
            <input type="hidden" name={Settings.smtp_ssl_key()} value="false" />
            <input
              type="checkbox"
              name={Settings.smtp_ssl_key()}
              value="true"
              checked={@form.values[Settings.smtp_ssl_key()]}
              class="checkbox"
            />
            <span class="label-text">
              {gettext("SMTP: use implicit TLS/SSL (usually port 465; leave off for STARTTLS on 587)")}
            </span>
          </label>
        </div>

        <.setting_field
          :for={field <- fields_for(group)}
          field={field}
          form={@form}
        />

        <p :if={group == :accounts} class="mt-1 text-xs opacity-70">
          {gettext(
            "Applied to newly self-registered users. Enter a positive whole number; 0 or an invalid value means unlimited. Leave blank to restore the default of 10."
          )}
        </p>

        <div class="mt-3 flex flex-wrap items-center gap-3">
          <div
            :for={{svc, svc_label} <- services_for(group)}
            class="flex flex-wrap items-center gap-x-2 gap-y-1"
          >
            <.button
              type="button"
              variant="neutral"
              size="sm"
              class="min-h-11"
              phx-click="test"
              phx-value-service={svc}
            >
              {gettext("Test %{service}", service: svc_label)}
            </.button>
            <.test_badge :if={@health[svc]} result={@health[svc]} />
          </div>
        </div>
      </div>
    </details>

    <details
      :if={@show_anime}
      id="anime-settings"
      open={MapSet.member?(@invalid_groups, :anime)}
      phx-hook="DisclosureState"
      data-force-open={to_string(MapSet.member?(@invalid_groups, :anime))}
      class="collapse collapse-arrow rounded-box bg-base-200"
    >
      <summary class="collapse-title min-h-11 cursor-pointer text-lg font-semibold focus-visible:outline-2 focus-visible:outline-primary">
        {gettext("Anime releases")}
      </summary>
      <div class="collapse-content grid gap-4 md:grid-cols-2">
        <.input
          id="anime_embedded_subtitle_mode"
          name="anime_embedded_subtitle_mode"
          value={@form.values["anime_embedded_subtitle_mode"]}
          errors={field_errors(@form, "anime_embedded_subtitle_mode")}
          type="select"
          label={gettext("Embedded subtitles")}
          prompt={gettext("Use server default (Prefer embedded)")}
          options={[
            {gettext("Allow"), "allow"},
            {gettext("Prefer embedded"), "prefer"},
            {gettext("Require embedded"), "require"}
          ]}
        />
        <.input
          id="anime_preferred_groups"
          name="anime_preferred_groups"
          value={@form.values["anime_preferred_groups"]}
          label={gettext("Preferred groups")}
        />
        <.input
          id="anime_blocked_groups"
          name="anime_blocked_groups"
          value={@form.values["anime_blocked_groups"]}
          label={gettext("Blocked groups")}
        />
        <.input
          id="anime_group_fallback_delay"
          name="anime_group_fallback_delay"
          value={@form.values["anime_group_fallback_delay"]}
          errors={field_errors(@form, "anime_group_fallback_delay")}
          type="number"
          min="0"
          label={gettext("Preferred-group fallback delay (hours)")}
        />
      </div>
    </details>
    """
  end

  attr :group, :atom, required: true

  defp setup_section_help(assigns) do
    assigns =
      assigns
      |> assign(:description, setup_section_description(assigns.group))
      |> assign(:resources, setup_section_resources(assigns.group))

    ~H"""
    <div class="setup-section-help mb-4 rounded-box border border-info/30 bg-info/10 p-3 text-sm">
      <p class="text-base-content/80">{@description}</p>
      <div :if={@resources != []} class="mt-2 flex flex-wrap items-center gap-x-3 gap-y-2">
        <span class="font-medium">{gettext("Resources:")}</span>
        <a
          :for={{label, url} <- @resources}
          href={url}
          target="_blank"
          rel="noopener noreferrer"
          aria-label={gettext("%{label} (opens in a new tab)", label: label)}
          class="link link-primary inline-flex min-h-11 items-center gap-1 py-2"
        >
          {label}<.icon name="hero-arrow-top-right-on-square" class="size-3.5" />
        </a>
      </div>
    </div>
    """
  end

  defp setup_step(:tmdb), do: 1
  defp setup_step(:indexer), do: 2
  defp setup_step(:download), do: 3
  defp setup_step(:media_server), do: 4
  defp setup_step(:library), do: 5
  defp setup_step(_group), do: nil

  defp setup_section_description(:tmdb),
    do:
      gettext(
        "The Movie Database provides movie and TV metadata, artwork, and episode details. Create a free API read access token and paste it below."
      )

  defp setup_section_description(:indexer),
    do:
      gettext(
        "Prowlarr connects Cinder to your indexers and finds releases. Add your indexers there first, then copy its URL and the API key from Settings > General."
      )

  defp setup_section_description(:migration),
    do:
      gettext(
        "Already use Radarr or Sonarr? Add them here only if you want Cinder to use their library data when adopting existing media. In each app, find the API key under Settings > General. Otherwise leave this optional section blank."
      )

  defp setup_section_description(:download),
    do:
      gettext(
        "Choose one client per protocol. Cinder supports qBittorrent or Transmission for torrents, and SABnzbd or NZBGet for Usenet, then tracks releases through import."
      )

  defp setup_section_description(:media_server),
    do:
      gettext(
        "Choose Jellyfin or Plex. Cinder triggers a library scan after import. In Jellyfin, create a key under Dashboard > Advanced > API Keys; for Plex, use the token guide below. Use the server URL Cinder can reach; the web URL is what household browsers open."
      )

  defp setup_section_description(:library),
    do:
      gettext(
        "Tell Cinder which download folders it may import from and where your movie and TV libraries live. Cinder puts imported files into those library folders so Jellyfin or Plex can find them, reusing disk space when possible."
      )

  defp setup_section_description(:releases),
    do:
      gettext(
        "These optional limits and preferences filter and rank releases. The defaults work for most homes; leave fields blank unless you want to tune quality or disk usage."
      )

  defp setup_section_description(:subtitles),
    do:
      gettext(
        "Optional. Connect OpenSubtitles to download missing subtitles; LibreTranslate can translate them when configured."
      )

  defp setup_section_description(:notifications),
    do:
      gettext(
        "Optional. Send approval, availability, and failure alerts through Discord, a generic webhook, or email (SMTP). You can configure this later."
      )

  defp setup_section_description(:accounts),
    do:
      gettext(
        "Optional. Configure OpenID Connect sign-in and the default request quota for newly registered users. Register the callback URL shown in the operating guide with your identity provider."
      )

  defp setup_section_resources(:tmdb),
    do: [
      {gettext("TMDB token guide"),
       "https://developer.themoviedb.org/docs/authentication-application"}
    ]

  defp setup_section_resources(:indexer),
    do: [{gettext("Prowlarr settings guide"), "https://wiki.servarr.com/prowlarr/settings"}]

  defp setup_section_resources(:migration),
    do: [
      {gettext("Radarr documentation"), "https://wiki.servarr.com/radarr"},
      {gettext("Sonarr documentation"), "https://wiki.servarr.com/sonarr"}
    ]

  defp setup_section_resources(:download),
    do: [
      {gettext("Get qBittorrent"), "https://www.qbittorrent.org/"},
      {gettext("Get Transmission"), "https://transmissionbt.com/"},
      {gettext("Get SABnzbd"), "https://sabnzbd.org/"},
      {gettext("Get NZBGet"), "https://nzbget.com/"}
    ]

  defp setup_section_resources(:media_server),
    do: [
      {gettext("Get Jellyfin"), "https://jellyfin.org/"},
      {gettext("Get Plex Media Server"), "https://www.plex.tv/media-server-downloads/"},
      {gettext("Plex token guide"),
       "https://support.plex.tv/articles/204059436-finding-an-authentication-token-x-plex-token/"}
    ]

  defp setup_section_resources(:subtitles),
    do: [
      {gettext("OpenSubtitles API key guide"),
       "https://opensubtitles.stoplight.io/docs/opensubtitles-api/e3750fd63a100-getting-started"},
      {gettext("LibreTranslate"), "https://github.com/LibreTranslate/LibreTranslate"}
    ]

  defp setup_section_resources(:notifications),
    do: [
      {gettext("Discord webhook guide"), "https://docs.discord.com/developers/resources/webhook"}
    ]

  defp setup_section_resources(_group), do: []

  def services_for(:tmdb), do: [{"tmdb", "TMDB"}]
  def services_for(:indexer), do: [{"indexer", "Prowlarr"}]

  def services_for(:migration),
    do: [{"radarr", gettext("Radarr")}, {"sonarr", gettext("Sonarr")}]

  def services_for(:download),
    do: [{"torrent", gettext("Torrent client")}, {"usenet", gettext("Usenet client")}]

  def services_for(:media_server), do: [{"media_server", gettext("Media server")}]
  def services_for(:notifications), do: [{"discord", "Discord"}]
  def services_for(:subtitles), do: [{"subtitles", "OpenSubtitles"}]

  def services_for(:library) do
    for(
      %{kind: kind, label: label} <- Settings.library_kinds(),
      do: {"#{kind}_library", SettingsLabels.t("#{label} library")}
    ) ++
      [{"media_info", gettext("Media info (ffprobe)")}]
  end

  def services_for(_group), do: []

  defp fields_for(:download), do: Settings.download_fields()

  defp fields_for(group),
    do: Settings.config_fields(group) ++ Settings.global_fields(group)

  # phx-value is client-controlled; only known services resolve to a check target.
  def decode_service("tmdb"), do: :tmdb
  def decode_service("indexer"), do: :indexer
  def decode_service("radarr"), do: {:migration_source, :radarr}
  def decode_service("sonarr"), do: {:migration_source, :sonarr}
  def decode_service("media_server"), do: :media_server
  def decode_service("torrent"), do: {:download, :torrent}
  def decode_service("usenet"), do: {:download, :usenet}
  def decode_service("discord"), do: :discord
  def decode_service("subtitles"), do: :subtitles
  def decode_service("media_info"), do: :media_info

  # "movies_library"/"tv_library"/… → {:library, kind} for a known kind, else nil.
  def decode_service(service) do
    Enum.find_value(Settings.library_kinds(), fn %{kind: kind} ->
      if service == "#{kind}_library", do: {:library, kind}
    end)
  end

  attr :field, :map, required: true
  attr :form, :map, required: true

  defp setting_field(assigns) do
    ~H"""
    <div class="form-control mb-2">
      <label class="label" for={@field.key}>
        <span class="label-text">{SettingsLabels.t(@field.label)}</span>
      </label>

      <input
        :if={not @field.secret}
        type="text"
        id={@field.key}
        name={@field.key}
        value={@form.values[@field.key]}
        placeholder={@form.placeholders[@field.key] || @field.placeholder}
        inputmode={Map.get(@field, :inputmode)}
        autocomplete="off"
        aria-invalid={invalid?(@form, @field.key) && "true"}
        aria-describedby={
          cond do
            invalid?(@form, @field.key) and Map.has_key?(@field, :help) ->
              "#{@field.key}-help #{@field.key}-error"

            invalid?(@form, @field.key) ->
              "#{@field.key}-error"

            Map.has_key?(@field, :help) ->
              "#{@field.key}-help"

            true ->
              nil
          end
        }
        class={["input w-full", invalid?(@form, @field.key) && "input-error"]}
      />

      <.field_error
        :if={not @field.secret and invalid?(@form, @field.key)}
        field={@field.key}
      />

      <p
        :if={Map.has_key?(@field, :help)}
        id={"#{@field.key}-help"}
        class="mt-1 text-xs opacity-70"
      >
        {path_mapping_help(@field.help)}
      </p>

      <div :if={@field.secret}>
        <input
          type="password"
          id={@field.key}
          name={@field.key}
          value=""
          placeholder={secret_placeholder(@field, @form)}
          autocomplete="off"
          class="input w-full"
        />
        <label class="label mt-1 cursor-pointer justify-start gap-2">
          <input
            type="checkbox"
            name={"clear_" <> @field.key}
            checked={MapSet.member?(@form.clear_secrets, @field.key)}
            class="checkbox checkbox-sm"
          />
          <span class="label-text">{gettext("Clear saved value")}</span>
        </label>
      </div>
    </div>
    """
  end

  attr :result, :any, required: true

  defp test_badge(assigns) do
    ~H"""
    <.status_badge kind={:health} status={@result} />
    """
  end

  attr :field, :string, required: true

  defp field_error(assigns) do
    ~H"""
    <p id={"#{@field}-error"} class="mt-1 flex items-center gap-1 text-sm text-error">
      <.icon name="hero-exclamation-circle" class="size-4 shrink-0" />
      {invalid_field_message(@field)}
    </p>
    """
  end

  defp invalid?(form, key), do: MapSet.member?(form.invalid_keys, key)

  defp path_mapping_help(:remote),
    do: gettext("Path prefix as the download client reports it")

  defp path_mapping_help(:local),
    do: gettext("The same directory as Cinder sees it")

  defp path_mapping_help(:timezone),
    do: gettext("IANA name used to decide when an episode's local air date has arrived")

  defp field_errors(form, key) do
    if invalid?(form, key), do: [invalid_field_message(key)], else: []
  end

  defp invalid_field_message(key) when key == "import_roots",
    do: gettext("The top-level folder (/) is not allowed.")

  defp invalid_field_message(key) when key == "anime_group_fallback_delay",
    do: gettext("Enter a non-negative whole number of hours.")

  defp invalid_field_message(key) when key == "anime_embedded_subtitle_mode",
    do: gettext("Choose a valid mode and at least one subtitle language when required.")

  defp invalid_field_message("household_timezone"),
    do: gettext("Enter a valid IANA timezone, such as Europe/Paris.")

  defp invalid_field_message(key) when key in ["torrent_client", "usenet_client"],
    do: gettext("Choose a listed download client.")

  defp invalid_field_message(key)
       when key in ["torrent_cleanup_ratio", "torrent_cleanup_seed_hours"],
       do: gettext("Enter a positive number, or leave blank to disable.")

  defp invalid_field_message(key) when is_binary(key) do
    if library_path_key?(key),
      do: gettext("The top-level folder (/) is not allowed."),
      else: invalid_release_field_message(key)
  end

  defp invalid_release_field_message(key) do
    if Enum.any?(
         Settings.library_kinds(),
         &(&1.video? and key == Settings.upgrade_cutoff_key(&1.kind))
       ),
       do: gettext("Choose a cutoff included in the preferred resolutions list."),
       else: gettext("Enter a number of GB (0 = no limit), or leave blank for the default.")
  end

  defp invalid_field_label(key) when key == "import_roots",
    do: gettext("Download folders")

  defp invalid_field_label("anime_embedded_subtitle_mode"),
    do: gettext("Anime: Embedded subtitles")

  defp invalid_field_label("anime_group_fallback_delay"),
    do: gettext("Anime: Preferred-group fallback delay")

  defp invalid_field_label("household_timezone"), do: gettext("Household timezone")

  defp invalid_field_label(key) do
    Enum.find_value(Settings.library_kinds(), &invalid_kind_field_label(key, &1)) ||
      SettingsLabels.t(Settings.field_label(key))
  end

  defp invalid_kind_field_label(key, %{kind: kind, label: label, video?: false}) do
    if key == Settings.library_path_key(kind),
      do: gettext("%{kind} library folder", kind: SettingsLabels.t(label))
  end

  defp invalid_kind_field_label(key, %{kind: kind, label: label, video?: true}) do
    cond do
      key == Settings.library_path_key(kind) ->
        gettext("%{kind} library folder", kind: SettingsLabels.t(label))

      key == Settings.anime_library_path_key(kind) ->
        gettext("Anime %{kind} library folder", kind: SettingsLabels.t(label))

      key == Settings.min_size_key(kind) ->
        gettext("%{kind}: Min size (GB)", kind: SettingsLabels.t(label))

      key == Settings.max_size_key(kind) ->
        gettext("%{kind}: Max size (GB)", kind: SettingsLabels.t(label))

      key == Settings.upgrade_cutoff_key(kind) ->
        gettext("%{kind}: Automatic upgrade cutoff", kind: SettingsLabels.t(label))

      true ->
        nil
    end
  end

  defp library_path_key?(key) do
    Enum.any?(Settings.library_kinds(), fn %{kind: kind, video?: video?} ->
      key == Settings.library_path_key(kind) or
        (video? and key == Settings.anime_library_path_key(kind))
    end)
  end

  defp secret_placeholder(field, form) do
    cond do
      MapSet.member?(form.secrets_set, field.key) ->
        gettext("•••• saved (leave blank to keep)")

      MapSet.member?(form.secrets_from_env, field.key) ->
        gettext("set via environment (leave blank to keep)")

      true ->
        ""
    end
  end
end
