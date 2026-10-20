defmodule Cinder.Settings.DefinitionTest do
  use ExUnit.Case, async: true

  alias Cinder.Settings
  alias Cinder.Settings.Definition

  # Every key the settings store knew before the definitions existed: the nine per-shape lists
  # plus the one-offs. A literal, so a dropped or doubled key fails here before any behaviour test.
  @keys ~w(
    anime_blocked_groups anime_embedded_subtitle_mode anime_group_fallback_delay
    anime_preferred_groups audiobooks_library_path audiobookshelf_api_key
    audiobookshelf_library_id audiobookshelf_url auto_approve_all books_library_path
    default_request_quota discord_webhook_url ffprobe_bin hardcover_api_key hardcover_url
    household_timezone import_roots jellyfin_api_key jellyfin_url jellyfin_web_url
    libretranslate_api_key libretranslate_batch_size libretranslate_timeout libretranslate_url
    media_server_type move_on_import movies_anime_library_path movies_blocked_terms
    movies_library_path movies_max_size movies_min_size movies_plex_section
    movies_preferred_resolutions movies_preferred_sources movies_preferred_terms
    movies_upgrade_cutoff nzbget_local_path_prefix nzbget_password nzbget_remote_path_prefix
    nzbget_url nzbget_username oidc_client_id oidc_client_secret oidc_issuer_url openlibrary_url
    opensubtitles_api_key opensubtitles_password opensubtitles_username plex_token plex_url
    plex_web_url prowlarr_api_key prowlarr_url qbittorrent_enabled qbittorrent_local_path_prefix
    qbittorrent_password qbittorrent_remote_path_prefix qbittorrent_url qbittorrent_username
    radarr_api_key radarr_local_path_prefix radarr_remote_path_prefix radarr_url readarr_api_key
    readarr_local_path_prefix readarr_remote_path_prefix readarr_url sabnzbd_api_key
    sabnzbd_enabled sabnzbd_local_path_prefix sabnzbd_remote_path_prefix sabnzbd_url
    setup_complete smtp_from smtp_host smtp_password smtp_port smtp_ssl smtp_username
    sonarr_api_key sonarr_local_path_prefix sonarr_remote_path_prefix sonarr_url
    subtitle_languages tmdb_token torrent_cleanup_ratio torrent_cleanup_seed_hours torrent_client
    transmission_local_path_prefix transmission_password transmission_remote_path_prefix
    transmission_url transmission_username tv_anime_library_path tv_blocked_terms
    tv_library_path tv_max_size tv_min_size tv_plex_section tv_preferred_resolutions
    tv_preferred_sources tv_preferred_terms tv_upgrade_cutoff upgrade_hunt_enabled usenet_client
    webhook_auth_header webhook_url
  )

  # The keys `save_form/1` can reject, written out independently of `Definition.validated?/1`.
  @validated ~w(
    libretranslate_batch_size libretranslate_timeout torrent_cleanup_ratio
    torrent_cleanup_seed_hours torrent_client usenet_client import_roots movies_library_path
    movies_anime_library_path tv_library_path tv_anime_library_path books_library_path
    audiobooks_library_path movies_min_size movies_max_size movies_upgrade_cutoff tv_min_size
    tv_max_size tv_upgrade_cutoff household_timezone anime_embedded_subtitle_mode
    anime_group_fallback_delay
  )

  test "every settings key has exactly one definition" do
    keys = Enum.map(Settings.definitions(), & &1.key)

    assert keys -- Enum.uniq(keys) == []
    assert Enum.sort(keys) == Enum.sort(@keys)
  end

  test "the definitions that validate are exactly the keys save_form can reject" do
    validated = for d <- Settings.definitions(), Definition.validated?(d), do: d.key

    assert Enum.sort(validated) == Enum.sort(@validated)
  end

  # The store encrypts a key at rest only when its definition is secret, so a slipped `shape:`
  # would write a credential in plaintext. The set the registry encrypted before definitions
  # existed, written out.
  test "the secret definitions are exactly the credentials the store encrypts" do
    secret = for d <- Settings.definitions(), Definition.secret?(d), do: d.key

    assert Enum.sort(secret) ==
             Enum.sort(~w(
               audiobookshelf_api_key discord_webhook_url hardcover_api_key jellyfin_api_key
               libretranslate_api_key nzbget_password oidc_client_secret opensubtitles_api_key
               opensubtitles_password opensubtitles_username plex_token prowlarr_api_key
               qbittorrent_password sabnzbd_api_key smtp_password tmdb_token
               transmission_password webhook_auth_header radarr_api_key sonarr_api_key
               readarr_api_key
             ))
  end

  # Replaces the per-group LiveView tests: a rejected key opens the disclosure its definition names
  # and explains itself with its own label and message, so a new validated setting cannot open the
  # wrong group (#391) or fall back to another key's message.
  test "every validated definition names a rendered group, a label and a message" do
    groups = [:anime | Keyword.keys(Settings.groups())]

    for %Definition{key: key} = definition <- Settings.definitions(),
        Definition.validated?(definition) do
      described = Settings.describe(key)

      assert described.group in groups, "#{key} has no rendered group"
      assert is_binary(msgid(described.label)), "#{key} has no label"
      assert is_binary(described.message), "#{key} has no message"
    end
  end

  test "describe/1 gives the group, the self-describing label and the shape's message" do
    assert Settings.describe("movies_min_size") == %{
             key: "movies_min_size",
             group: :releases,
             label: {"%{kind}: Min size (GB)", kind: "Movies"},
             message: "Enter a number of GB (0 = no limit), or leave blank for the default."
           }

    assert %{group: :subtitles, message: "Enter a positive whole number" <> _} =
             Settings.describe("libretranslate_batch_size")

    assert %{group: :library, label: {"%{kind} library folder", kind: "Ebooks"}} =
             Settings.describe("books_library_path")

    assert %{group: :download, label: "Torrent client"} = Settings.describe("torrent_client")

    assert %{group: :tmdb, label: "TMDB API read token (v4 bearer)", message: nil} =
             Settings.describe("tmdb_token")
  end

  test "describe/1 falls back to the key itself for an unregistered key" do
    assert Settings.describe("unknown_key") ==
             %{key: "unknown_key", group: nil, label: "unknown_key", message: nil}
  end

  test "one!/1 finds the single definition a filter names, and raises unless exactly one matches" do
    assert %Definition{key: "smtp_ssl"} =
             Settings.Registry.one!(target: {:writer, :mailer}, slot: :ssl)

    assert %Definition{key: "smtp_host"} =
             Settings.Registry.one!(target: {:module, Cinder.Mailer, :relay})

    assert_raise ArgumentError, ~r/no setting definition/, fn ->
      Settings.Registry.one!(target: {:writer, :no_such_writer})
    end

    assert_raise ArgumentError, ~r/2 setting definitions/, fn ->
      Settings.Registry.one!(target: {:writer, :download_clients}, save: :read_only)
    end
  end

  test "the media server choice maps each option it offers to its implementation" do
    assert {:media_server, options} =
             Settings.Registry.one!(target: {:writer, :media_server}).shape

    assert Settings.Registry.media_servers() == options

    assert Map.new(options, &{&1.value, {&1.server, &1.module, &1.os_env}}) == %{
             "jellyfin" => {:jellyfin, Cinder.Library.MediaServer.Jellyfin, nil},
             "plex" => {:plex, Cinder.Library.MediaServer.Plex, "PLEX_URL"}
           }

    # The first option is the form's choice when no type is stored and no os_env is set.
    assert Settings.media_server_options() == ["jellyfin", "plex"]

    # media_server_web_link/1 calls the option's deep_link/1, and reads its web URL field.
    for %{module: module} <- options do
      behaviours =
        module.__info__(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

      assert Cinder.Library.MediaServer in behaviours
      assert Settings.Registry.one!(target: {:module, module, :web_url})
    end
  end

  test "every label and message a definition emits is registered for translation" do
    msgids = MapSet.new(Settings.Registry.msgids())

    for definition <- Settings.definitions(),
        string <- strings(definition.label) ++ strings(Settings.describe(definition.key).message) do
      assert string in msgids, "#{definition.key}: #{inspect(string)} is not in msgids/0"
    end
  end

  defp msgid({template, _bindings}), do: template
  defp msgid(label), do: label

  defp strings(nil), do: []
  defp strings({template, bindings}), do: [template | Keyword.values(bindings)]
  defp strings(string), do: [string]
end
