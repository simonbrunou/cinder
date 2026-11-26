defmodule Cinder.Accounts.SignInBaseUrlFragmentTest do
  # Jellyfin sign-in and the server check of Plex sign-in reach the same requests under a server
  # URL with a fragment as under the URL cut at its `#` (#1340), as the media-server clients do in
  # `Cinder.ServiceBaseUrlFragmentTest` (#1323). Req joins a request's path onto `base_url` as
  # text, so before the fix the path landed in the fragment and each stub saw the URL's own path.
  # async: false, and a DataCase: Jellyfin sign-in's device_id/0 persists through
  # Cinder.Settings, which mutates global Application env on every write.
  use Cinder.DataCase, async: false

  import ExUnit.CaptureLog

  alias Cinder.Accounts.JellyfinAuth
  alias Cinder.Accounts.OIDC
  alias Cinder.Accounts.PlexAuth
  alias Cinder.ConfigCase
  alias Cinder.Library.MediaServer.{Jellyfin, Plex}

  # device_id/0 saves its id on a test's first Jellyfin call, and each save rebuilds every
  # settings env key from the stored rows (docs/agents/testing.md).
  setup do
    ConfigCase.restore_env_on_exit(Cinder.Settings.env_keys())
  end

  # Each row: a name, the module whose `:url` the call reads, the sign-in client whose
  # `req_options` hold the stub, the stub, the call, the test URL, and the path the call reads
  # under it.
  defp rows do
    [
      {"JellyfinAuth.HTTP authenticate/2", Jellyfin, JellyfinAuth.HTTP, Cinder.JellyfinAuthStub,
       fn -> JellyfinAuth.HTTP.authenticate("viewer", "s3cret") end, "http://localhost:8096",
       "/Users/AuthenticateByName"},
      {"PlexAuth.HTTP server_machine_id/1", Plex, PlexAuth.HTTP, Cinder.PlexTvStub,
       fn -> PlexAuth.HTTP.server_machine_id([]) end, "http://localhost:32400", "/identity"}
    ]
  end

  # Runs `call` with the server URL set to `url` and returns each request the stub saw.
  defp requests(server, url, stub, call) do
    test_pid = self()
    ConfigCase.put_config(server, url: url)

    Req.Test.stub(stub, fn conn ->
      send(test_pid, {:request, conn.method, conn.host, conn.request_path, conn.query_string})
      Req.Test.json(conn, %{})
    end)

    call.()
    drain()
  end

  defp drain(acc \\ []) do
    receive do
      {:request, _method, _host, _path, _query} = request -> drain([request | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp path({:request, _method, _host, path, _query}), do: path

  test "a server URL with a fragment sends the same request as the URL without it" do
    for {name, server, _client, stub, call, url, path} <- rows() do
      plain = requests(server, url, stub, call)

      assert match?([{:request, _method, "localhost", ^path, _query}], plain),
             "#{name}: #{inspect(plain)}"

      assert requests(server, url <> "#frag", stub, call) == plain, name
    end
  end

  test "each sign-in call cuts the server URL at its `#`, whatever follows it" do
    for {name, server, _client, stub, call, url, path} <- rows(),
        {suffix, expected} <- [
          {"#", path},
          {"/#frag", path},
          {"/sub#frag", "/sub" <> path}
        ] do
      assert Enum.map(requests(server, url <> suffix, stub, call), &path/1) == [expected],
             "#{name} with #{url <> suffix}"
    end
  end

  # Without the `Req.Test` plug, which answers a URL with no scheme or host. The configured text
  # holds no host, so no request can leave the VM.
  test "a server URL that is only a fragment makes each call return an error, with no exit" do
    Process.flag(:trap_exit, true)

    for {name, server, client, _stub, call, _url, _path} <- rows() do
      req_options = :cinder |> Application.get_env(client) |> Keyword.fetch!(:req_options)
      ConfigCase.put_config(server, url: "#frag")
      ConfigCase.put_config(client, req_options: Keyword.delete(req_options, :plug))

      # Req raises in the request task, which logs its crash.
      {result, _log} = with_log(call)
      assert match?({:error, _reason}, result), name
      refute_received {:EXIT, _pid, _reason}, name
    end
  end

  # OIDC sign-in sends no request under a URL with a fragment (#1414): `configured?/0` refuses
  # such an issuer URL, and the HTTP adapter refuses such an endpoint URL before any request. The
  # cut in `OIDC.config/1` is a second guard, which the base URL fence asks for.
  test "OIDC refuses an issuer URL or an endpoint URL with a fragment" do
    saved = Application.get_env(:cinder, OIDC)
    on_exit(fn -> Application.put_env(:cinder, OIDC, saved) end)
    config = [issuer_url: "https://id.example.test", client_id: "cinder", client_secret: "s3cret"]

    Application.put_env(:cinder, OIDC, config)
    assert OIDC.configured?()

    Application.put_env(
      :cinder,
      OIDC,
      Keyword.put(config, :issuer_url, config[:issuer_url] <> "#frag")
    )

    refute OIDC.configured?()

    assert {:error, :fragment_not_allowed} =
             OIDC.HTTPAdapter.request(:get, "https://id.example.test/keys#frag", nil, [])
  end
end
