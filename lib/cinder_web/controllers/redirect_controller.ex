defmodule CinderWeb.RedirectController do
  use CinderWeb, :controller

  # /series (the old TV-search page) folded into Discover in UX-3; keep the bookmark working.
  def to_root(conn, _params), do: redirect(conn, to: ~p"/")
end
