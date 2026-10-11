defmodule Cinder.Accounts.JellyfinAuth.HTTPTest do
  # async: false — device_id/0 persists through Cinder.Settings, which mutates global
  # Application env via load_into_env/0 on every write.
  use Cinder.DataCase, async: false

  import Cinder.ConfigCase

  alias Cinder.Accounts.JellyfinAuth
  alias Cinder.Accounts.JellyfinAuth.HTTP

  test "authenticate/2 posts the credentials to the configured server and parses id/name" do
    Req.Test.stub(Cinder.JellyfinAuthStub, fn conn ->
      assert conn.method == "POST"
      assert conn.host == "localhost"
      assert conn.request_path == "/Users/AuthenticateByName"

      [authorization] = Plug.Conn.get_req_header(conn, "x-emby-authorization")
      assert authorization =~ ~s(Client="Cinder")
      assert authorization =~ ~s(DeviceId="#{JellyfinAuth.device_id()}")

      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(raw) == %{"Username" => "viewer", "Pw" => "s3cret"}

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Req.Test.json(%{
        "User" => %{
          "Id" => "abc123",
          "Name" => "viewer",
          "HasPassword" => true,
          "Policy" => %{"IsDisabled" => false, "EnableRemoteAccess" => true}
        },
        "AccessToken" => "jf-token"
      })
    end)

    assert {:ok, %{id: "abc123", name: "viewer", remote_access: true}} =
             HTTP.authenticate("viewer", "s3cret")
  end

  defp stub_user(user) do
    Req.Test.stub(Cinder.JellyfinAuthStub, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Req.Test.json(%{"User" => Map.merge(%{"Id" => "abc123", "Name" => "viewer"}, user)})
    end)
  end

  defp policy(overrides),
    do: %{"IsDisabled" => false, "EnableRemoteAccess" => true} |> Map.merge(overrides)

  # SECURITY: Jellyfin signs a passwordless user in on an empty password, from Cinder's LAN
  # address. The controller's empty-password refusal is the guarantee; `HasPassword` is obsolete
  # (always true on current Jellyfin), so it only refuses when a server explicitly says `false`.
  test "authenticate/2 refuses a user reported without a password, but not one that omits it" do
    stub_user(%{"HasPassword" => false, "Policy" => policy(%{})})
    assert {:error, :passwordless} = HTTP.authenticate("viewer", "s3cret")

    stub_user(%{"Policy" => policy(%{})})
    assert {:ok, %{id: "abc123"}} = HTTP.authenticate("viewer", "s3cret")
  end

  test "authenticate/2 refuses an explicitly disabled user" do
    stub_user(%{"HasPassword" => true, "Policy" => policy(%{"IsDisabled" => true})})
    assert {:error, :disabled} = HTTP.authenticate("viewer", "s3cret")
  end

  test "authenticate/2 reports remote_access false when remote access is off or not stated" do
    stub_user(%{"HasPassword" => true, "Policy" => policy(%{"EnableRemoteAccess" => false})})
    assert {:ok, %{remote_access: false}} = HTTP.authenticate("viewer", "s3cret")

    stub_user(%{"HasPassword" => true, "Policy" => %{"IsDisabled" => false}})
    assert {:ok, %{remote_access: false}} = HTTP.authenticate("viewer", "s3cret")

    stub_user(%{"HasPassword" => true})
    assert {:ok, %{remote_access: false}} = HTTP.authenticate("viewer", "s3cret")
  end

  test "authenticate/2 maps a 401 to {:error, :invalid_credentials}" do
    Req.Test.stub(Cinder.JellyfinAuthStub, fn conn ->
      Plug.Conn.send_resp(conn, 401, "")
    end)

    assert {:error, :invalid_credentials} = HTTP.authenticate("viewer", "wrong")
  end

  test "authenticate/2 maps any other status to a tagged error" do
    Req.Test.stub(Cinder.JellyfinAuthStub, fn conn ->
      Plug.Conn.send_resp(conn, 500, "")
    end)

    assert {:error, {:jellyfin_status, 500}} = HTTP.authenticate("viewer", "s3cret")
  end

  test "authenticate/2 rejects a response with no user id" do
    Req.Test.stub(Cinder.JellyfinAuthStub, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Req.Test.json(%{"AccessToken" => "jf-token"})
    end)

    assert {:error, :unexpected_response} = HTTP.authenticate("viewer", "s3cret")
  end

  test "authenticate/2 returns {:error, :not_configured} when the server url is blank" do
    put_config(Cinder.Library.MediaServer.Jellyfin, url: "")

    assert {:error, :not_configured} = HTTP.authenticate("viewer", "s3cret")
  end

  test "device_id/0 generates once and returns the same value on the second call" do
    first = JellyfinAuth.device_id()
    second = JellyfinAuth.device_id()

    assert first == second
    assert {:ok, _uuid} = Ecto.UUID.cast(first)
  end

  test "configured?/0 follows the Jellyfin server url, ignoring the api key" do
    assert JellyfinAuth.configured?()

    put_config(Cinder.Library.MediaServer.Jellyfin, api_key: nil)
    assert JellyfinAuth.configured?()

    put_config(Cinder.Library.MediaServer.Jellyfin, url: nil)
    refute JellyfinAuth.configured?()
  end
end
