defmodule CinderWeb.SeriesDiscoveryLive.Reread do
  @moduledoc false
  # The page's TMDB re-read (`reread_series/1`): whether a broadcast asked for one, whether one
  # runs, and the timer of the window the last one opened (nil once it has ended).
  defstruct due?: false, reading?: false, window: nil
end
