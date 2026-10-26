defmodule Cinder.Catalog.MediaServerSeason do
  @moduledoc """
  One season the configured media server holds, as last read by
  `Cinder.Library.MediaServer.Reconciler`. Keyed by the show's TMDB id, not a Cinder series, so
  a show Cinder never added still reads as available on its request page. `item_id` is the
  show's media-server id, for `Cinder.Settings.media_server_web_link/1`. It starts with the
  server type that wrote it (`"plex:"`, `"jellyfin:"`), which `Cinder.Catalog.MediaServerSeasons`
  reads to ignore the other type's rows.
  """
  use Ecto.Schema

  schema "media_server_seasons" do
    field :tmdb_id, :integer
    field :season_number, :integer
    field :episode_count, :integer
    field :item_id, :string
  end
end
