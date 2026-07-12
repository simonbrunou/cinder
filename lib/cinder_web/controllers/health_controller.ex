defmodule CinderWeb.HealthController do
  use CinderWeb, :controller

  def show(conn, _params), do: text(conn, "ok")
end
