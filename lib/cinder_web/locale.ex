defmodule CinderWeb.Locale do
  @moduledoc """
  Resolves and applies the active locale for English/French i18n.

  Precedence: an explicit choice stored in the session (set by the language
  switcher) → the browser's `Accept-Language` header → the default locale.

  Used two ways, because a LiveView process does not inherit the Plug's
  `Gettext.put_locale/2`:

    * as a **Plug** in the `:browser` pipeline (HTTP requests, dead renders), and
    * as an **on_mount** hook in every `live_session` (the LiveView process).

  `@locales` is the single source of truth for the supported set.
  """

  import Plug.Conn

  @locales ~w(en fr)
  @default "en"

  @doc "The supported locales, in display order."
  def locales, do: @locales

  @doc "Returns the locale string if supported, else nil. Used to validate any external input."
  def supported(locale) when locale in @locales, do: locale
  def supported(_), do: nil

  ## Plug (HTTP)

  def init(opts), do: opts

  def call(conn, _opts) do
    stored = supported(get_session(conn, :locale))
    locale = stored || header_locale(conn) || @default
    Gettext.put_locale(CinderWeb.Gettext, locale)

    conn
    |> maybe_persist(stored, locale)
    |> assign(:locale, locale)
  end

  # Persist only on a real change (first visit / switch) — avoids re-emitting a Set-Cookie
  # on every request. The first-visit write still lets the LiveView on_mount recover the
  # negotiated locale (it can't read request headers).
  defp maybe_persist(conn, same, same), do: conn
  defp maybe_persist(conn, _stored, locale), do: put_session(conn, :locale, locale)

  ## on_mount (LiveView)

  # The Plug already stored a validated locale in the session on the initial HTTP
  # request, so the socket just reads it back.
  def on_mount(:default, _params, session, socket) do
    locale = supported(session["locale"]) || @default
    Gettext.put_locale(CinderWeb.Gettext, locale)
    {:cont, Phoenix.Component.assign(socket, :locale, locale)}
  end

  ## Accept-Language negotiation

  defp header_locale(conn) do
    conn
    |> get_req_header("accept-language")
    |> List.first()
    |> parse_accept_language()
  end

  # Pick the first listed language whose base (fr-CA → fr) we support. q-values are
  # ignored — ordering is enough at household scale.
  # ponytail: q-value-naive; revisit only if a third locale needs priority tuning.
  defp parse_accept_language(nil), do: nil

  defp parse_accept_language(header) do
    header
    |> String.split(",")
    |> Enum.find_value(fn part ->
      part
      |> String.split(";")
      |> List.first()
      |> String.trim()
      |> String.split("-")
      |> List.first()
      |> String.downcase()
      |> supported()
    end)
  end
end
