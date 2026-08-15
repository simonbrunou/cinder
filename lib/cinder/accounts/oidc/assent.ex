defmodule Cinder.Accounts.OIDC.Assent do
  @moduledoc false
  @behaviour Cinder.Accounts.OIDC

  alias Assent.Strategy.OIDC

  @impl true
  def authorize_url(config), do: OIDC.authorize_url(config)

  @impl true
  def callback(config, params) do
    with {:ok, %{token: token, user: user} = response} <- OIDC.callback(config, params) do
      {:ok, %{response | user: user_claims(config, token, user)}}
    end
  end

  # Some providers put standard email/profile claims only on UserInfo. The signed ID token is
  # still sufficient for a previously linked subject, so a missing/unavailable UserInfo endpoint
  # falls back to those verified claims; a first login then fails closed unless it has a verified
  # email from one of the two standard sources.
  defp user_claims(_config, _token, %{"email" => email, "email_verified" => true} = user)
       when is_binary(email) and email != "",
       do: user

  defp user_claims(config, token, user) do
    case OIDC.fetch_userinfo(config, token) do
      {:ok, claims} -> Map.merge(user, claims)
      {:error, _reason} -> user
    end
  end
end
