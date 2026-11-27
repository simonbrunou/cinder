defmodule Cinder.Indexers.ProwlarrImportFlareSolverrTest do
  # The Prowlarr import's FlareSolverr tick (#1682): the preview reads Prowlarr's FlareSolverr
  # host, a commit with the tick saves it as Cinder's FlareSolverr URL before the indexers, and
  # a host changed since the preview refuses the batch. Prowlarr's answers are hand-written
  # (`Cinder.ProwlarrApiFixtures`), and so is the definition (`Cinder.DefinitionFixtures`).
  #
  # Not async: the Prowlarr source's config, the import lock, the Test runner and a settings
  # save's env overlay are app-wide.
  use Cinder.DataCase, async: false

  import Ecto.Query
  import Mox
  import Cinder.ProwlarrApiFixtures
  import Cinder.TestRunnerHelpers

  alias Cinder.Acquisition.IndexerSource.Native
  alias Cinder.Acquisition.IndexerSource.Native.TestRunner
  alias Cinder.Acquisition.IndexerSource.Prowlarr
  alias Cinder.ConfigCase
  alias Cinder.DefinitionFixtures
  alias Cinder.Indexers.{ConfiguredIndexer, FlareSolverrUrl, ProwlarrImport}
  alias Cinder.Indexers.ProwlarrImport.Preview

  @prowlarr_url "https://media.example.com/prowlarr"
  @prowlarr_key "stored-prowlarr-key-3e9a"
  @host "http://flaresolverr.lan:8191/"

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    ConfigCase.put_config(Prowlarr, base_url: @prowlarr_url, api_key: @prowlarr_key)
    block_tests()
    stop_tests_on_exit()
    :ok = TestRunner.subscribe()
    DefinitionFixtures.mirror!(DefinitionFixtures.definition("tracker"))
    :ok
  end

  defp preview! do
    assert {:ok, %Preview{} = preview} = ProwlarrImport.preview()
    preview
  end

  defp tick(id, name),
    do: {id, %{ticked: true, name: name, via_prowlarr: false, secrets: %{}}}

  defp configured, do: Repo.all(from c in ConfiguredIndexer, order_by: c.id)

  # A Cardigann tracker whose settings Prowlarr answers in clear, so a commit needs no typed
  # secret.
  defp tracker(id, tags) do
    fields = [
      field("username", "alice"),
      field("password", "clear-password-41"),
      field("apikey", nil),
      field("freeleech", true),
      select_field("sort", 1, ["Date", "Size"])
    ]

    cardigann(id, "tracker", name: "Tracker #{id}", fields: fields, tags: tags)
  end

  defp flaresolverr(id, tags, host) do
    id
    |> proxy("FlareSolverr", tags)
    |> Map.put("fields", [field("host", host), field("requestTimeout", 60)])
  end

  defp notes(report), do: Map.new(report.created, &{&1.prowlarr_id, &1.notes})

  describe "the preview" do
    test "reads the host of Prowlarr's FlareSolverr proxy, trimmed" do
      stub_api([tracker(1, [3])], [flaresolverr(1, [3], "  #{@host} ")])
      assert preview!().flaresolverr_host == @host
    end

    for {name, proxies} <- [
          {"no FlareSolverr proxy", [{"Http", "http://proxy.lan:3128/"}]},
          {"a host that is not an http or https URL",
           [{"FlareSolverr", "flaresolverr.lan:8191"}]},
          {"a host with user info", [{"FlareSolverr", "http://u:p@flaresolverr.lan:8191/"}]},
          {"two FlareSolverr proxies on different hosts",
           [{"FlareSolverr", @host}, {"FlareSolverr", "http://other.lan:8191/"}]}
        ] do
      @proxies proxies

      test "offers no host for #{name}" do
        proxies =
          for {{implementation, host}, i} <- Enum.with_index(@proxies, 1) do
            i
            |> proxy(implementation, [3])
            |> Map.put("fields", [field("host", host)])
          end

        stub_api([tracker(1, [3])], proxies)
        assert preview!().flaresolverr_host == nil
      end
    end

    test "two FlareSolverr proxies on one host offer it" do
      stub_api([tracker(1, [3])], [flaresolverr(1, [3], @host), flaresolverr(2, [4], @host)])
      assert preview!().flaresolverr_host == @host
    end
  end

  describe "the commit" do
    test "with the tick and no URL saved, saves Prowlarr's host and notes nothing" do
      stub_api([tracker(1, [3])], [flaresolverr(1, [3], @host)])

      assert {:ok, report} =
               ProwlarrImport.commit(preview!(), Map.new([tick(1, "Flare")]), nil,
                 save_flaresolverr_url: true
               )

      assert FlareSolverrUrl.get() == @host
      assert report.flaresolverr_url_saved == true
      assert notes(report) == %{1 => []}
      assert [%ConfiguredIndexer{flaresolverr: true}] = configured()
    end

    test "without the tick, saves nothing and lists each toggled indexer as URL not set" do
      stub_api([tracker(1, [3]), tracker(2, [4])], [flaresolverr(1, [3], @host)])

      assert {:ok, report} =
               ProwlarrImport.commit(preview!(), Map.new([tick(1, "Flare"), tick(2, "Plain")]))

      assert FlareSolverrUrl.get() == nil
      assert report.flaresolverr_url_saved == false
      assert notes(report) == %{1 => [:flaresolverr_url_not_set], 2 => []}
    end

    test "a URL already saved is kept, the tick aside, and no row is listed" do
      :ok = FlareSolverrUrl.put("http://kept.lan:8191")
      stub_api([tracker(1, [3])], [flaresolverr(1, [3], @host)])

      assert {:ok, report} =
               ProwlarrImport.commit(preview!(), Map.new([tick(1, "Flare")]), nil,
                 save_flaresolverr_url: true
               )

      assert FlareSolverrUrl.get() == "http://kept.lan:8191"
      assert report.flaresolverr_url_saved == false
      assert notes(report) == %{1 => []}
    end

    test "a host changed since the preview refuses the batch and saves nothing" do
      stub_api([tracker(1, [3])], [flaresolverr(1, [3], @host)])
      preview = preview!()
      stub_api([tracker(1, [3])], [flaresolverr(1, [3], "http://moved.lan:8191/")])

      assert {:error, {:changed, %Preview{flaresolverr_host: "http://moved.lan:8191/"}}} =
               ProwlarrImport.commit(preview, Map.new([tick(1, "Flare")]), nil,
                 save_flaresolverr_url: true
               )

      assert FlareSolverrUrl.get() == nil
      assert configured() == []
    end

    test "a batch whose rows the commit's checks refuse saves no host" do
      stub_api([tracker(1, [3])], [flaresolverr(1, [3], @host)])
      preview = preview!()
      {:ok, _row} = Cinder.Indexers.create(nil, tracker_taken_attrs(), %{})

      assert {:error, {:rows, %{1 => [:name_taken]}}} =
               ProwlarrImport.commit(preview, Map.new([tick(1, "Taken")]), nil,
                 save_flaresolverr_url: true
               )

      assert FlareSolverrUrl.get() == nil
    end
  end

  describe "the imported row" do
    test "searches through the host the tick saved" do
      stub_api([tracker(1, [3])], [flaresolverr(1, [3], @host)])

      assert {:ok, %{flaresolverr_url_saved: true}} =
               ProwlarrImport.commit(preview!(), Map.new([tick(1, "Flare")]), nil,
                 save_flaresolverr_url: true
               )

      # `block_tests/0` left Native no Cardigann adapter.
      ConfigCase.put_env(:indexer_adapters, %{cardigann: Cinder.Acquisition.Indexer.Cardigann})
      test_pid = self()

      # The site answers a Cloudflare challenge until a request carries FlareSolverr's clearance.
      Cinder.CardigannFixtures.route(%{
        "tracker.invalid" => fn conn, _query ->
          cookies = conn |> Plug.Conn.get_req_header("cookie") |> Enum.join("; ")

          if String.contains?(cookies, "cf_clearance=clear-1") and
               Plug.Conn.get_req_header(conn, "user-agent") == ["FlareSolverrImportTest"] do
            {200,
             "<table><tr><td><a href=\"/t/1\">Dune.2021.1080p.WEB-DL.x264-IMP</a></td></tr></table>"}
          else
            conn
            |> Plug.Conn.put_resp_header("server", "cloudflare")
            |> Plug.Conn.put_resp_content_type("text/html")
            |> Plug.Conn.send_resp(403, "<title>Just a moment...</title>")
          end
        end
      })

      Req.Test.stub(Cinder.FlareSolverrStub, fn conn ->
        send(test_pid, {:flaresolverr_at, conn.host, conn.port, conn.request_path})

        Req.Test.json(conn, %{
          "status" => "ok",
          "solution" => %{
            "url" => "https://tracker.invalid/",
            "status" => 200,
            "cookies" => [
              %{"name" => "cf_clearance", "value" => "clear-1", "domain" => ".tracker.invalid"}
            ],
            "userAgent" => "FlareSolverrImportTest",
            "response" => "<html></html>"
          }
        })
      end)

      [indexer] = configured()
      assert {:ok, _result} = Native.test_indexer(indexer.id)
      assert_received {:flaresolverr_at, "flaresolverr.lan", 8191, "/v1"}
    end
  end

  defp tracker_taken_attrs,
    do: %{name: "Taken", type: :newznab, base_url: "https://taken.example", api_path: "/api"}
end
