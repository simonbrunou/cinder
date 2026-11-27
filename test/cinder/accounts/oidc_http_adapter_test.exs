defmodule Cinder.Accounts.OIDC.HTTPAdapterTest do
  use ExUnit.Case, async: true

  alias Assent.HTTPAdapter.HTTPResponse
  alias Cinder.Accounts.OIDC.HTTPAdapter
  alias Cinder.Test.BoundedRequestWait

  test "normalizes a bounded JSON response for Assent" do
    Req.Test.stub(Cinder.OIDCStub, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/token"
      assert Plug.Conn.get_req_header(conn, "user-agent") != []

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Req.Test.json(%{"access_token" => "token"})
    end)

    # The adapter's own deadline is 20 s, and no option shortens it. A loaded host stalled this
    # stubbed call past it twice (#1730), so the call runs in a task the test waits 15 s for.
    # Past 15 s, with the request task still alive, the wait's failure says where the task and
    # its request task stood. The caller task holds no access to the stub to grant, so the
    # request task reaches the stub through `$callers`.
    watch = BoundedRequestWait.watch()

    task =
      Task.async(fn ->
        HTTPAdapter.request(
          :post,
          "https://id.example.com/token",
          "code=abc",
          [{"content-type", "application/x-www-form-urlencoded"}],
          plug: {Req.Test, Cinder.OIDCStub}
        )
      end)

    assert {:ok, %HTTPResponse{} = response} = BoundedRequestWait.await(watch, task, 15_000)

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
