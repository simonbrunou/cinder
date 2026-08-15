defmodule Cinder.Accounts.OIDC.HTTPAdapterTest do
  use ExUnit.Case, async: true

  alias Assent.HTTPAdapter.HTTPResponse
  alias Cinder.Accounts.OIDC.HTTPAdapter

  test "normalizes a bounded JSON response for Assent" do
    Req.Test.stub(Cinder.OIDCStub, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/token"
      assert Plug.Conn.get_req_header(conn, "user-agent") != []

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Req.Test.json(%{"access_token" => "token"})
    end)

    assert {:ok, %HTTPResponse{} = response} =
             HTTPAdapter.request(
               :post,
               "https://id.example.com/token",
               "code=abc",
               [{"content-type", "application/x-www-form-urlencoded"}],
               plug: {Req.Test, Cinder.OIDCStub}
             )

    assert response.status == 200
    assert {"content-type", "application/json; charset=utf-8"} in response.headers
    assert response.body == %{"access_token" => "token"}
  end

  test "rejects non-HTTP endpoint URLs" do
    assert {:error, :https_required} =
             HTTPAdapter.request(:get, "file:///etc/passwd", nil, [], [])
  end

  test "rejects plaintext HTTP endpoints" do
    assert {:error, :https_required} =
             HTTPAdapter.request(:get, "http://id.example.com/token", nil, [], [])
  end

  test "rejects a cross-origin discovery endpoint that resolves to a private address" do
    resolver = fn "metadata.example" -> {:ok, [{169, 254, 169, 254}]} end

    assert {:error, :forbidden_address} =
             HTTPAdapter.request(:get, "https://metadata.example/token", nil, [],
               source_origin: "https://id.example.com",
               resolver: resolver
             )
  end
end
