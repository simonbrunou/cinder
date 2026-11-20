defmodule CinderWeb.Passkey do
  @moduledoc """
  The relying party passkeys are bound to, derived from the endpoint's configured URL: the RP ID
  is its host and the origin the URL itself. In production that URL is `https://<PHX_HOST>`
  (`config/runtime.exs`), so a passkey works only on the host name `PHX_HOST` holds: a browser
  on another host name signs for another origin, which `Cinder.Accounts.Passkeys` refuses.
  """

  @doc "The relying party for `Cinder.Accounts.Passkeys`, from `url` (the endpoint's by default)."
  @spec relying_party(String.t()) :: Cinder.Accounts.Passkeys.rp()
  def relying_party(url \\ CinderWeb.Endpoint.url()) do
    %URI{scheme: scheme, host: host, port: port} = URI.parse(url)
    default_port? = {scheme, port} in [{"https", 443}, {"http", 80}]

    %{
      id: host,
      origin: if(default_port?, do: "#{scheme}://#{host}", else: "#{scheme}://#{host}:#{port}")
    }
  end
end
