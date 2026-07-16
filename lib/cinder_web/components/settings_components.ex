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

  alias Cinder.Settings
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

    keys
    |> Enum.map(fn key ->
      cond do
        key == Settings.import_roots_key() -> :library
        MapSet.member?(anime_keys, key) -> :anime
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
      class="rounded-box bg-base-200"
    >
      <summary class="min-h-11 cursor-pointer px-4 py-3 text-lg font-semibold focus-visible:outline-2 focus-visible:outline-primary">
        {SettingsLabels.t(label)}
      </summary>

      <div class="px-4 pb-4">
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

        <div :if={group == :download} class="mb-3">
          <label :for={t <- Settings.toggles()} class="label cursor-pointer justify-start gap-2">
            <input type="hidden" name={t.key} value="false" />
            <input
              type="checkbox"
              name={t.key}
              value="true"
              checked={@form.values[t.key]}
              class="checkbox"
            />
            <span class="label-text">{SettingsLabels.t(t.label)}</span>
          </label>
        </div>

        <div :if={group == :library} class="space-y-2">
          <div class="form-control">
            <label class="label" for={Settings.import_roots_key()}>
              <span class="label-text">{gettext("Download import roots")}</span>
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
                invalid?(@form, Settings.import_roots_key()) &&
                  "#{Settings.import_roots_key()}-error"
              }
            >{@form.values[Settings.import_roots_key()]}</textarea>
            <.field_error
              :if={invalid?(@form, Settings.import_roots_key())}
              field={Settings.import_roots_key()}
            />
            <p class="mt-1 text-xs opacity-70">
              {gettext(
                "Allowed download folders, separated by commas or new lines. The filesystem root is not allowed."
              )}
            </p>
          </div>

          <div
            :for={%{kind: kind, label: kind_label} <- Settings.library_kinds()}
            class="form-control"
          >
            <label class="label" for={Settings.library_path_key(kind)}>
              <span class="label-text">{gettext("%{kind} library path (where %{kind} are hardlinked)",
                kind: SettingsLabels.t(kind_label)
              )}</span>
            </label>
            <input
              type="text"
              id={Settings.library_path_key(kind)}
              name={Settings.library_path_key(kind)}
              value={@form.values[Settings.library_path_key(kind)]}
              placeholder={@form.placeholders[Settings.library_path_key(kind)] || "/media/#{kind}"}
              autocomplete="off"
              class="input w-full"
            />
          </div>
          <p class="mt-1 text-xs opacity-70">
            {gettext(
              "A separate root per library, so Jellyfin/Plex can point distinct libraries at each. Required even if they share a folder; enter the same path."
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
                class="checkbox"
              />
              <span class="label-text">{gettext("Remove download after a Usenet import")}</span>
            </label>
            <p class="mt-1 text-xs opacity-70">
              {gettext(
                "After a Usenet import, delete the original from the download client. Ensure your library is a separate folder from your downloads. Torrents are never auto-removed (seeding survives)."
              )}
            </p>
          </div>

          <div class="form-control pt-2">
            <label class="label" for={Settings.ffprobe_bin_key()}>
              <span class="label-text">{gettext("ffprobe binary")}</span>
            </label>
            <input
              type="text"
              id={Settings.ffprobe_bin_key()}
              name={Settings.ffprobe_bin_key()}
              value={@form.values[Settings.ffprobe_bin_key()]}
              placeholder={@form.placeholders[Settings.ffprobe_bin_key()] || "ffprobe"}
              autocomplete="off"
              class="input w-full"
            />
            <p class="mt-1 text-xs opacity-70">
              {gettext(
                "Command name or path used to verify a download's audio/subtitle languages after import. Leave blank to use \"ffprobe\" from PATH."
              )}
            </p>
          </div>
        </div>

        <div :if={group == :releases} class="space-y-3">
          <div :for={%{kind: kind, label: kind_label} <- Settings.library_kinds()} class="space-y-2">
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
          </div>
          <p class="mt-1 text-xs opacity-70">
            {gettext("Sizes are decimal GB (1 GB = 1,000,000,000 bytes). For TV they apply")} <strong>{gettext("per episode")}</strong>{gettext(
              ": a season pack of N episodes is allowed up to N× the max. Defaults: Movies 0.3–15 GB, TV 0.05–4 GB per episode. Leave blank for the default; enter 0 for no limit."
            )}
            {gettext(
              "Sources: remux, bluray, webrip, webdl, hdtv, dvd, cam. Leave blank to accept any; untagged releases are always kept. These are distinct; listing only bluray excludes remux, so add both to accept either."
            )}
          </p>
        </div>

        <.setting_field :for={field <- Settings.config_fields(group)} field={field} form={@form} />

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
      <summary class="min-h-11 cursor-pointer px-4 py-3 text-lg font-semibold focus-visible:outline-2 focus-visible:outline-primary">
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

  def services_for(:tmdb), do: [{"tmdb", "TMDB"}]
  def services_for(:indexer), do: [{"indexer", "Prowlarr"}]
  def services_for(:download), do: [{"torrent", "qBittorrent"}, {"usenet", "SABnzbd"}]
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

  # phx-value is client-controlled; only known services resolve to a check target.
  def decode_service("tmdb"), do: :tmdb
  def decode_service("indexer"), do: :indexer
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
        autocomplete="off"
        class="input w-full"
      />

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

  defp field_errors(form, key) do
    if invalid?(form, key), do: [invalid_field_message(key)], else: []
  end

  defp invalid_field_message(key) when key == "import_roots",
    do: gettext("The filesystem root (/) is not allowed.")

  defp invalid_field_message(key) when key == "anime_group_fallback_delay",
    do: gettext("Enter a non-negative whole number of hours.")

  defp invalid_field_message(key) when key == "anime_embedded_subtitle_mode",
    do: gettext("Choose a valid mode and at least one subtitle language when required.")

  defp invalid_field_message(_key),
    do: gettext("Enter a number of GB (0 = no limit), or leave blank for the default.")

  defp invalid_field_label(key) when key == "import_roots",
    do: gettext("Download import roots")

  defp invalid_field_label("anime_embedded_subtitle_mode"),
    do: gettext("Anime: Embedded subtitles")

  defp invalid_field_label("anime_group_fallback_delay"),
    do: gettext("Anime: Preferred-group fallback delay")

  defp invalid_field_label(key) do
    Enum.find_value(Settings.library_kinds(), key, fn %{kind: kind, label: label} ->
      cond do
        key == Settings.min_size_key(kind) ->
          gettext("%{kind}: Min size (GB)", kind: SettingsLabels.t(label))

        key == Settings.max_size_key(kind) ->
          gettext("%{kind}: Max size (GB)", kind: SettingsLabels.t(label))

        true ->
          nil
      end
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
