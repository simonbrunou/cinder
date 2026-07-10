defmodule CinderWeb.SettingsLabels do
  @moduledoc """
  Translates the user-facing labels that originate in the `Cinder.Settings` domain module —
  config-field labels, group headers, download-client toggles, library-kind names. The domain
  stays gettext-free: it emits stable English strings that double as the gettext msgids, and
  this web-layer helper translates them at render time via `t/1`.

  `known/0` is the registration list: every label the domain can emit, each wrapped in
  `gettext_noop/1` so `mix gettext.extract` captures it (the calls are dynamic, so the extractor
  can't see the msgids otherwise). A label missing from `known/0` renders untranslated, so
  `no_hardcoded_strings_test` asserts the domain's label set is a subset of it — a new setting
  can't silently ship an English-only label.
  """
  use Gettext, backend: CinderWeb.Gettext

  @doc "Translate a `Cinder.Settings` English label to the active locale (passthrough if unknown)."
  def t(label) when is_binary(label), do: Gettext.gettext(CinderWeb.Gettext, label)

  @doc "Every label the domain can emit, registered for extraction. Keep in sync with `Cinder.Settings`."
  def known do
    [
      # group headers — Settings.groups/0
      gettext_noop("TMDB"),
      gettext_noop("Indexer"),
      gettext_noop("Download clients"),
      gettext_noop("Media server"),
      gettext_noop("Library paths"),
      gettext_noop("Release size bands"),
      gettext_noop("Subtitles"),
      gettext_noop("Notifications"),
      # download-client toggles — Settings.toggles/0
      gettext_noop("Enable qBittorrent (torrent)"),
      gettext_noop("Enable SABnzbd (usenet)"),
      # library kinds — Settings.library_kinds/0 — and the "<kind> library" test-badge labels
      gettext_noop("Movies"),
      gettext_noop("TV"),
      gettext_noop("Movies library"),
      gettext_noop("TV library"),
      # static config-field labels — Settings.config_fields/0
      gettext_noop("TMDB API read token (v4 bearer)"),
      gettext_noop("Prowlarr URL"),
      gettext_noop("Prowlarr API key"),
      gettext_noop("qBittorrent URL"),
      gettext_noop("qBittorrent username"),
      gettext_noop("qBittorrent password"),
      gettext_noop("SABnzbd URL"),
      gettext_noop("SABnzbd API key"),
      gettext_noop("Jellyfin URL"),
      gettext_noop("Jellyfin API key"),
      gettext_noop("Plex URL"),
      gettext_noop("Plex token"),
      gettext_noop("Discord webhook URL"),
      gettext_noop("OpenSubtitles API key"),
      gettext_noop("OpenSubtitles username"),
      gettext_noop("OpenSubtitles password"),
      gettext_noop("Subtitle languages (comma-separated, e.g. en,fr)"),
      gettext_noop("LibreTranslate URL"),
      gettext_noop("LibreTranslate API key"),
      # generated per-kind Plex section labels — Settings.config_fields/0
      gettext_noop("Plex Movies library section (numeric id)"),
      gettext_noop("Plex TV library section (numeric id)")
    ]
  end
end
