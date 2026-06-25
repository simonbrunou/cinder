defmodule CinderWeb.LocaleController do
  @moduledoc """
  Persists a language choice from the switcher into the session, then sends the
  user back where they came from.

  A plain GET so the switcher is a link (no JS, works on logged-out pages). Setting
  a session locale is not a state change worth CSRF-protecting; the worst a forged
  request can do is change the visitor's own display language.
  """
  use CinderWeb, :controller

  def update(conn, %{"locale" => locale}) do
    conn
    |> maybe_put_locale(CinderWeb.Locale.supported(locale))
    |> redirect(to: back_path(conn))
  end

  defp maybe_put_locale(conn, nil), do: conn
  defp maybe_put_locale(conn, locale), do: put_session(conn, :locale, locale)

  # Only the path component of the referer is used, so a cross-origin referer can't
  # become an open redirect. A protocol-relative ("//host") path or a backslash would
  # make redirect/2 raise rather than redirect, so those fall back to root too;
  # unparseable/absent → root.
  defp back_path(conn) do
    with [referer | _] <- get_req_header(conn, "referer"),
         %URI{path: "/" <> _ = path} = uri <- URI.parse(referer),
         to = path <> if(uri.query, do: "?" <> uri.query, else: ""),
         false <- String.starts_with?(to, "//") or String.contains?(to, "\\") do
      to
    else
      _ -> ~p"/"
    end
  end
end
