defmodule CinderWeb.SettingsComponents do
  @moduledoc """
  Shared rendering for the grouped external-service config fields, used by both the
  `/settings` page and the first-run `/setup` wizard. The parent LiveView owns the
  `"test"` event and supplies `form` (from `Settings.form_state/0`) and `health`
  (a `%{service_key => :ok | {:error, term()}}` map).
  """
  use Phoenix.Component
  use Gettext, backend: CinderWeb.Gettext

  import CinderWeb.CoreComponents, only: [status_badge: 1, button: 1]

  alias Cinder.Settings

  attr :form, :map, required: true
  attr :health, :map, required: true
  # move_on_import is a /settings-only advanced toggle; the first-run wizard passes false
  # so it isn't offered before the operator has validated a real import (spec: settings-only).
  attr :show_move_on_import, :boolean, default: true

  def service_fields(assigns) do
    ~H"""
    <fieldset :for={{group, label} <- Settings.groups()} class="rounded-box bg-base-200 p-4">
      <legend class="px-2 text-lg font-semibold">{label}</legend>

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
          <span class="label-text">{t.label}</span>
        </label>
      </div>

      <div :if={group == :library} class="space-y-2">
        <div :for={%{kind: kind, label: kind_label} <- Settings.library_kinds()} class="form-control">
          <label class="label" for={Settings.library_path_key(kind)}>
            <span class="label-text">{gettext("%{kind} library path (where %{kind} are hardlinked)",
              kind: kind_label
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
      </div>

      <div :if={group == :releases} class="space-y-3">
        <div :for={%{kind: kind, label: kind_label} <- Settings.library_kinds()} class="space-y-2">
          <p class="text-sm font-medium">{kind_label}</p>
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
              class="input w-full"
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
              class="input w-full"
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
            ": a season pack of N episodes is allowed up to N× the max. Leave blank for no limit."
          )}
          {gettext(
            "Sources: remux, bluray, webrip, webdl, hdtv, dvd, cam. Leave blank to accept any; untagged releases are always kept. These are distinct; listing only bluray excludes remux, so add both to accept either."
          )}
        </p>
      </div>

      <.setting_field :for={field <- Settings.config_fields(group)} field={field} form={@form} />

      <div class="mt-3 flex flex-wrap items-center gap-3">
        <div :for={{svc, svc_label} <- services_for(group)} class="flex items-center gap-2">
          <.button type="button" variant="neutral" size="sm" phx-click="test" phx-value-service={svc}>
            {gettext("Test %{service}", service: svc_label)}
          </.button>
          <.test_badge :if={@health[svc]} result={@health[svc]} />
        </div>
      </div>
    </fieldset>
    """
  end

  def services_for(:tmdb), do: [{"tmdb", "TMDB"}]
  def services_for(:indexer), do: [{"indexer", "Prowlarr"}]
  def services_for(:download), do: [{"torrent", "qBittorrent"}, {"usenet", "SABnzbd"}]
  def services_for(:media_server), do: [{"media_server", gettext("Media server")}]

  def services_for(:library) do
    for %{kind: kind, label: label} <- Settings.library_kinds(),
        do: {"#{kind}_library", "#{label} library"}
  end

  def services_for(_group), do: []

  # phx-value is client-controlled; only known services resolve to a check target.
  def decode_service("tmdb"), do: :tmdb
  def decode_service("indexer"), do: :indexer
  def decode_service("media_server"), do: :media_server
  def decode_service("torrent"), do: {:download, :torrent}
  def decode_service("usenet"), do: {:download, :usenet}

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
        <span class="label-text">{@field.label}</span>
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
          <input type="checkbox" name={"clear_" <> @field.key} class="checkbox checkbox-sm" />
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
