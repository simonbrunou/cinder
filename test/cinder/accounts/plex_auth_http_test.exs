defmodule Cinder.Accounts.PlexAuth.HTTPTest do
  # async: false — client_identifier/0 persists through Cinder.Settings, which
  # mutates global Application env via load_into_env/0 on every write.
  use Cinder.DataCase, async: false

  import Cinder.ConfigCase

  alias Cinder.Accounts.PlexAuth
  alias Cinder.Accounts.PlexAuth.HTTP

  test "create_pin/0 sends the required headers and parses id/code" do
    Req.Test.stub(Cinder.PlexTvStub, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/api/v2/pins"
      assert Plug.Conn.get_req_header(conn, "x-plex-product") == ["Cinder"]

      assert Plug.Conn.get_req_header(conn, "x-plex-client-identifier") == [
               PlexAuth.client_identifier()
             ]

      assert Plug.Conn.get_req_header(conn, "accept") == ["application/json"]

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.put_status(201)
      |> Req.Test.json(%{"id" => 42, "code" => "ABCD", "authToken" => nil})
    end)

    assert {:ok, %{id: 42, code: "ABCD"}} = HTTP.create_pin()
  end

  test "check_pin/1 sends the client identifier and returns {:error, :pending} on a null authToken" do
    Req.Test.stub(Cinder.PlexTvStub, fn conn ->
      assert conn.request_path == "/api/v2/pins/42"

      assert Plug.Conn.get_req_header(conn, "x-plex-client-identifier") == [
               PlexAuth.client_identifier()
             ]

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Req.Test.json(%{"id" => 42, "authToken" => nil})
    end)

    assert {:error, :pending} = HTTP.check_pin(42)
  end

  test "check_pin/1 returns {:ok, token} once authToken is set" do
    Req.Test.stub(Cinder.PlexTvStub, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Req.Test.json(%{"id" => 42, "authToken" => "plex-token-123"})
    end)

    assert {:ok, "plex-token-123"} = HTTP.check_pin(42)
  end

  test "account/2 sends the token and parses id/email/username" do
    Req.Test.stub(Cinder.PlexTvStub, fn conn ->
      assert conn.request_path == "/api/v2/user"
      assert Plug.Conn.get_req_header(conn, "x-plex-token") == ["user-token"]

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Req.Test.json(%{"id" => 7, "email" => "person@example.com", "username" => "person"})
    end)

    assert {:ok, %{id: 7, email: "person@example.com", username: "person"}} =
             HTTP.account("user-token", [])
  end

  test "account/2 tolerates a managed account with no email" do
    Req.Test.stub(Cinder.PlexTvStub, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Req.Test.json(%{"id" => 8, "email" => nil, "username" => "managed"})
    end)

    assert {:ok, %{id: 8, email: nil, username: "managed"}} = HTTP.account("user-token", [])
  end

  # The shape plex.tv answered on prod on 2026-11-17 (every value replaced): XML whatever the
  # `accept` header asks for, one `SharedServer` per account the server is shared with.
  defp shared_server(attributes) do
    defaults = [
      id: "11111111",
      username: "friend",
      email: "friend@example.com",
      accessToken: "shared-access-token",
      name: "friend",
      acceptedAt: "1700000000",
      invitedAt: "1700000000",
      allowSync: "1",
      allowCameraUpload: "0",
      allowChannels: "0",
      allowTuners: "0",
      allowSubtitleAdmin: "0",
      owned: "0",
      allLibraries: "1",
      filterAll: "",
      filterMovies: "",
      filterMusic: "",
      filterPhotos: "",
      filterTelevision: ""
    ]

    attrs =
      defaults
      |> Keyword.merge(attributes)
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Enum.map_join(" ", fn {key, value} -> ~s(#{key}="#{value}") end)

    """
    <SharedServer #{attrs}>
      <Section id="222222222" key="1" title="Movies" type="movie" shared="1"/>
      <Section id="222222223" key="2" title="TV Shows" type="show" shared="1"/>
    </SharedServer>
    """
  end

  defp share_list(servers) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <MediaContainer friendlyName="myPlex" identifier="com.plexapp.plugins.myplex" \
    machineIdentifier="machine-1" size="#{length(servers)}">
    #{Enum.join(servers)}</MediaContainer>
    """
  end

  defp stub_share_list(body, status \\ 200) do
    Req.Test.stub(Cinder.PlexTvStub, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/xml")
      |> Plug.Conn.send_resp(status, body)
    end)
  end

  test "server_share_ids/3 asks plex.tv with the owner token and returns each userID in order" do
    body =
      share_list([
        shared_server(userID: "333333333"),
        shared_server(userID: "12345678"),
        shared_server(userID: "444444444")
      ])

    Req.Test.stub(Cinder.PlexTvStub, fn conn ->
      assert conn.method == "GET"
      assert conn.host == "plex.tv"
      assert conn.request_path == "/api/servers/machine-1/shared_servers"
      assert Plug.Conn.get_req_header(conn, "x-plex-token") == ["owner-token"]
      assert Plug.Conn.get_req_header(conn, "accept") == ["application/xml"]

      conn
      |> Plug.Conn.put_resp_content_type("application/xml")
      |> Plug.Conn.send_resp(200, body)
    end)

    assert HTTP.server_share_ids("owner-token", "machine-1", []) ==
             {:ok, [333_333_333, 12_345_678, 444_444_444]}
  end

  test "server_share_ids/3 returns an empty list for a server shared with nobody" do
    stub_share_list(share_list([]))
    assert HTTP.server_share_ids("owner-token", "machine-1", []) == {:ok, []}

    stub_share_list(~s(<?xml version="1.0" encoding="UTF-8"?>\n<MediaContainer size="0"/>\n))
    assert HTTP.server_share_ids("owner-token", "machine-1", []) == {:ok, []}
  end

  test "server_share_ids/3 returns the status of a non-2xx answer as an error" do
    for status <- [401, 403, 404, 500] do
      stub_share_list(share_list([shared_server(userID: "333333333")]), status)

      assert HTTP.server_share_ids("owner-token", "machine-1", []) ==
               {:error, {:plex_tv_status, status}},
             "status #{status}"
    end
  end

  test "server_share_ids/3 keeps a share by its userID alone, whatever acceptedAt or owned say" do
    stub_share_list(
      share_list([
        shared_server(userID: "333333333", acceptedAt: "0"),
        shared_server(userID: "444444444", acceptedAt: nil, owned: "1")
      ])
    )

    assert HTTP.server_share_ids("owner-token", "machine-1", []) ==
             {:ok, [333_333_333, 444_444_444]}
  end

  # A renamed attribute or element must not read as a server shared with nobody: it refuses at
  # the share-list step, where the health check sees it.
  test "server_share_ids/3 refuses a list holding a share whose userID is not a positive integer" do
    for user_id <- [nil, "", "0", "-5", "+6", " 7", "8x", "1e3", "9999999999999999999"] do
      stub_share_list(
        share_list([shared_server(userID: "333333333"), shared_server(userID: user_id)])
      )

      assert HTTP.server_share_ids("owner-token", "machine-1", []) ==
               {:error, :unexpected_response},
             "userID #{inspect(user_id)}"
    end

    # A renamed attribute.
    stub_share_list(share_list([shared_server(userID: nil, userId: "333333333")]))

    assert HTTP.server_share_ids("owner-token", "machine-1", []) ==
             {:error, :unexpected_response}

    # A size that counts only the valid share does not hide the other one.
    stub_share_list("""
    <MediaContainer size="1"><SharedServer userID="5"/><SharedServer userId="6"/></MediaContainer>
    """)

    assert HTTP.server_share_ids("owner-token", "machine-1", []) ==
             {:error, :unexpected_response}
  end

  test "server_share_ids/3 refuses a root size that is not the number of shares" do
    for size <- ["0", "2", "x", "", "-1"] do
      stub_share_list("""
      <MediaContainer size="#{size}"><SharedServer userID="333333333"/></MediaContainer>
      """)

      assert HTTP.server_share_ids("owner-token", "machine-1", []) ==
               {:error, :unexpected_response},
             "size #{inspect(size)}"
    end

    # A renamed element leaves the count short of the size.
    stub_share_list(
      share_list([shared_server(userID: "333333333")])
      |> String.replace("SharedServer", "Share")
    )

    assert HTTP.server_share_ids("owner-token", "machine-1", []) ==
             {:error, :unexpected_response}
  end

  # Without a size, a renamed SharedServer element would read as a list shared with nobody.
  test "server_share_ids/3 refuses a root without a size" do
    for body <- [
          ~s(<MediaContainer><SharedServer userID="333333333"/></MediaContainer>),
          ~s(<MediaContainer><Share userID="333333333"/></MediaContainer>),
          ~s(<MediaContainer/>)
        ] do
      stub_share_list(body)

      assert HTTP.server_share_ids("owner-token", "machine-1", []) ==
               {:error, :unexpected_response},
             "body #{inspect(body)}"
    end
  end

  test "server_share_ids/3 reads only a SharedServer directly under the MediaContainer root" do
    stub_share_list("""
    <MediaContainer size="1">
      <Other><SharedServer userID="555555555"/></Other>
      <SharedServer userID="333333333"><SharedServer userID="666666666"/></SharedServer>
    </MediaContainer>
    """)

    assert HTTP.server_share_ids("owner-token", "machine-1", []) == {:ok, [333_333_333]}
  end

  test "server_share_ids/3 returns {:error, :unexpected_response} for a body that is not a share list" do
    for body <- [
          "",
          "not xml",
          ~s(<Shares><SharedServer userID="333333333"/></Shares>),
          ~s(<Shares size="0"/>),
          ~s(<MediaContainer><SharedServer userID="333333333"></MediaContainer>),
          ~s(<MediaContainer size="0"/><MediaContainer size="0"/>)
        ] do
      stub_share_list(body)

      assert HTTP.server_share_ids("owner-token", "machine-1", []) ==
               {:error, :unexpected_response},
             "body #{inspect(body)}"
    end

    Req.Test.stub(Cinder.PlexTvStub, fn conn ->
      Req.Test.json(conn, %{"MediaContainer" => %{"SharedServer" => [%{"userID" => 333_333_333}]}})
    end)

    assert HTTP.server_share_ids("owner-token", "machine-1", []) ==
             {:error, :unexpected_response}
  end

  test "server_share_ids/3 refuses a body that declares an entity" do
    body = """
    <?xml version="1.0"?>
    <!DOCTYPE MediaContainer [<!ENTITY id "333333333">]>
    <MediaContainer size="2"><SharedServer userID="&id;"/><SharedServer userID="444444444"/>\
    </MediaContainer>
    """

    # Positive control: xmerl's defaults expand the entity into the id.
    collect = fn
      {:startElement, _uri, ~c"SharedServer", _qname, [{_, _, ~c"userID", id}]}, _loc, ids ->
        [List.to_string(id) | ids]

      _event, _loc, ids ->
        ids
    end

    assert {:ok, ["444444444", "333333333"], _rest} =
             :xmerl_sax_parser.stream(body, event_fun: collect, event_state: [])

    stub_share_list(body)

    assert HTTP.server_share_ids("owner-token", "machine-1", []) ==
             {:error, :unexpected_response}
  end

  test "server_share_ids/3 puts the machine id in the path as one encoded segment" do
    test_pid = self()

    Req.Test.stub(Cinder.PlexTvStub, fn conn ->
      send(test_pid, {:path, conn.request_path, conn.query_string})

      conn
      |> Plug.Conn.put_resp_content_type("application/xml")
      |> Plug.Conn.send_resp(200, share_list([]))
    end)

    assert HTTP.server_share_ids("owner-token", "../v2/user?x=1#y", []) == {:ok, []}
    assert_received {:path, "/api/servers/..%2Fv2%2Fuser%3Fx%3D1%23y/shared_servers", ""}
  end

  test "server_machine_id/1 hits the configured local server's /identity" do
    Req.Test.stub(Cinder.PlexTvStub, fn conn ->
      assert conn.host == "localhost"
      assert conn.request_path == "/identity"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Req.Test.json(%{"MediaContainer" => %{"machineIdentifier" => "abc-123"}})
    end)

    assert {:ok, "abc-123"} = HTTP.server_machine_id([])
  end

  test "server_machine_id/1 returns {:error, :unexpected_response} for a machineIdentifier that is not a non-empty string" do
    for machine_id <- [nil, "", 42] do
      Req.Test.stub(Cinder.PlexTvStub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Req.Test.json(%{"MediaContainer" => %{"machineIdentifier" => machine_id}})
      end)

      assert HTTP.server_machine_id([]) == {:error, :unexpected_response},
             "machineIdentifier #{inspect(machine_id)} passed"
    end
  end

  describe "timeouts" do
    # An adapter in place of the Req.Test plug sees the options each request goes out with, and
    # answers with a refused connection so nothing reaches a network.
    setup do
      pid = self()

      adapter = fn request ->
        send(
          pid,
          {:request, request.url.path,
           Map.take(request.options, [:receive_timeout, :pool_timeout, :connect_options])}
        )

        {request, %Req.TransportError{reason: :econnrefused}}
      end

      put_config(HTTP, req_options: [adapter: adapter, retry: false])
      :ok
    end

    test "sign-in keeps 15 s on plex.tv and 5 s on /identity" do
      HTTP.account("user-token", [])
      assert_receive {:request, "/api/v2/user", options}

      assert options == %{
               receive_timeout: 15_000,
               pool_timeout: 5_000,
               connect_options: [timeout: 5_000]
             }

      HTTP.server_share_ids("owner-token", "machine-1", [])
      assert_receive {:request, "/api/servers/machine-1/shared_servers", ^options}

      HTTP.server_machine_id([])
      assert_receive {:request, "/identity", options}
      assert options == %{receive_timeout: 5_000, connect_options: [timeout: 5_000]}
    end

    test "timeouts: :probe bounds each of the three calls with 3 s" do
      probe = %{receive_timeout: 3_000, pool_timeout: 3_000, connect_options: [timeout: 3_000]}

      HTTP.account("user-token", timeouts: :probe)
      assert_receive {:request, "/api/v2/user", ^probe}

      HTTP.server_share_ids("owner-token", "machine-1", timeouts: :probe)
      assert_receive {:request, "/api/servers/machine-1/shared_servers", ^probe}

      HTTP.server_machine_id(timeouts: :probe)
      assert_receive {:request, "/identity", ^probe}
    end
  end

  test "server_machine_id/1 returns {:error, :not_configured} when the local server url is blank" do
    put_config(Cinder.Library.MediaServer.Plex, url: "")

    assert {:error, :not_configured} = HTTP.server_machine_id([])
  end

  test "watchlist/1 hits the discover host with the token and maps entries to TMDB ids" do
    Req.Test.stub(Cinder.PlexTvStub, fn conn ->
      assert conn.host == "discover.provider.plex.tv"
      assert conn.request_path == "/library/sections/watchlist/all"
      assert Plug.Conn.get_req_header(conn, "x-plex-token") == ["user-token"]
      assert conn.query_string =~ "includeGuids=1"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Req.Test.json(%{
        "MediaContainer" => %{
          "Metadata" => [
            %{
              "type" => "movie",
              "title" => "Inception",
              "year" => 2010,
              "Guid" => [%{"id" => "imdb://tt1375666"}, %{"id" => "tmdb://27205"}]
            },
            %{
              "type" => "show",
              "title" => "Some Show",
              "year" => 2011,
              "Guid" => [%{"id" => "tmdb://1399"}]
            },
            # No resolvable TMDB id: nothing Cinder could request, so it is dropped.
            %{"type" => "movie", "title" => "Obscure", "Guid" => [%{"id" => "imdb://tt9"}]}
          ]
        }
      })
    end)

    assert {:ok, entries} = HTTP.watchlist("user-token")

    assert entries == [
             %{tmdb_id: 27_205, type: "movie", title: "Inception", year: 2010},
             %{tmdb_id: 1399, type: "show", title: "Some Show", year: 2011}
           ]
  end

  test "watchlist/1 returns an empty list for a watchlist with no Metadata" do
    Req.Test.stub(Cinder.PlexTvStub, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Req.Test.json(%{"MediaContainer" => %{"size" => 0}})
    end)

    assert {:ok, []} = HTTP.watchlist("user-token")
  end

  test "watchlist/1 reports a rejected token as :unauthorized, distinctly from other failures" do
    Req.Test.stub(Cinder.PlexTvStub, fn conn ->
      Plug.Conn.send_resp(conn, 401, "")
    end)

    assert {:error, :unauthorized} = HTTP.watchlist("stale-token")
  end

  test "watchlist/1 reports a server-side failure as a plain status error" do
    Req.Test.stub(Cinder.PlexTvStub, fn conn ->
      Plug.Conn.send_resp(conn, 503, "")
    end)

    assert {:error, {:plex_tv_status, 503}} = HTTP.watchlist("user-token")
  end

  test "client_identifier/0 generates once and returns the same value on the second call" do
    first = PlexAuth.client_identifier()
    second = PlexAuth.client_identifier()

    assert first == second
    assert {:ok, _uuid} = Ecto.UUID.cast(first)
  end
end
