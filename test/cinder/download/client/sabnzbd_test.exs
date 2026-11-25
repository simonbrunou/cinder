defmodule Cinder.Download.Client.SabnzbdTest do
  use ExUnit.Case, async: true

  import Cinder.ConfigCase
  import ExUnit.CaptureLog

  alias Cinder.ConfigCase
  alias Cinder.Download.Client.{Fetch, Sabnzbd}

  defp stub(fun), do: Req.Test.stub(Cinder.SabnzbdStub, fun)

  defp configure_path_mapping(remote, local) do
    keys = [:sabnzbd_remote_path_prefix, :sabnzbd_local_path_prefix]
    original = Map.new(keys, &{&1, Application.get_env(:cinder, &1)})

    Application.put_env(:cinder, :sabnzbd_remote_path_prefix, remote)
    Application.put_env(:cinder, :sabnzbd_local_path_prefix, local)

    on_exit(fn ->
      Enum.each(original, fn
        {key, nil} -> Application.delete_env(:cinder, key)
        {key, value} -> Application.put_env(:cinder, key, value)
      end)
    end)
  end

  # status/1 hits queue first, then history. This stub answers an empty queue and
  # the given history body, asserting both calls scope by nzo_ids (without it,
  # SABnzbd's default page limit could hide the job and yield a false :not_found).
  defp stub_queue_then_history(history_body) do
    stub(fn conn ->
      assert conn.request_path == "/api"
      assert conn.params["nzo_ids"] == "nzo-1"
      assert conn.params["apikey"] == "test-key"

      case conn.params["mode"] do
        "queue" -> Req.Test.json(conn, %{"queue" => %{"slots" => []}})
        "history" -> Req.Test.json(conn, history_body)
      end
    end)
  end

  # Since add/1 now fetches the NZB itself before calling SABnzbd, every add stub must answer
  # both the (arbitrary-host) fetch request and the `/api` addfile call. This one differentiates
  # by request_path, which is enough since none of these tests' fetch URLs share the api path.
  defp stub_fetch_then_addfile(respond) do
    stub(fn conn ->
      case conn.request_path do
        "/api" ->
          assert conn.params["mode"] == "addfile"
          respond.(conn)

        _ ->
          Req.Test.text(conn, "nzb-bytes")
      end
    end)
  end

  test "add/1 fetches the NZB itself, then posts addfile, and returns the nzo_id" do
    stub(fn conn ->
      case conn.request_path do
        "/getnzb/1" ->
          assert conn.host == "93.184.216.34"
          assert conn.query_string == "apikey=k&id=9"
          Req.Test.text(conn, "nzb-bytes")

        "/api" ->
          assert conn.params["mode"] == "addfile"
          assert conn.params["apikey"] == "test-key"
          assert conn.params["output"] == "json"
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          assert body =~ "nzb-bytes"
          Req.Test.json(conn, %{"status" => true, "nzo_ids" => ["SABnzbd_nzo_abc"]})
      end
    end)

    assert {:ok, "SABnzbd_nzo_abc"} =
             Sabnzbd.add(%{download_url: "http://prowlarr/getnzb/1?apikey=k&id=9"},
               fetch: &Fetch.bytes/3
             )
  end

  test "add/1 pins an untrusted NZB fetch to the validated address" do
    stub(fn conn ->
      case conn.request_path do
        "/pinned.nzb" ->
          assert conn.host == "93.184.216.34"
          Req.Test.text(conn, "nzb-bytes")

        "/api" ->
          Req.Test.json(conn, %{"status" => true, "nzo_ids" => ["nzo-pinned"]})
      end
    end)

    assert {:ok, "nzo-pinned"} =
             Sabnzbd.add(%{download_url: "https://provider.test/pinned.nzb"},
               fetch: &Fetch.bytes/3
             )
  end

  test "add/1 never tells SABnzbd the URL — addfile carries file bytes, not the URL" do
    stub(fn conn ->
      case conn.request_path do
        "/getnzb/1" ->
          Req.Test.text(conn, "nzb-bytes")

        "/api" ->
          # "name" is the addfile field for the uploaded content (an actual file, not a
          # string) — SABnzbd never learns the URL, so it can't resolve/redirect it itself.
          assert %Plug.Upload{} = conn.params["name"]
          refute conn.query_string =~ "getnzb"
          Req.Test.json(conn, %{"status" => true, "nzo_ids" => ["nzo-1"]})
      end
    end)

    assert {:ok, "nzo-1"} =
             Sabnzbd.add(%{download_url: "http://prowlarr/getnzb/1"}, fetch: &Fetch.bytes/3)
  end

  test "add/1 rejects an SSRF redirect during the NZB fetch before ever contacting SABnzbd" do
    stub(fn conn ->
      case conn.request_path do
        "/api" ->
          flunk("SABnzbd must not be contacted when the fetch redirect is unsafe")

        "/redirect" ->
          conn
          |> Plug.Conn.put_resp_header("location", "http://127.0.0.1/internal")
          |> Plug.Conn.send_resp(302, "")
      end
    end)

    assert {:error, :forbidden_address} =
             Sabnzbd.add(%{download_url: "http://provider.test/redirect"}, fetch: &Fetch.bytes/3)
  end

  test "add/1 refuses a fetch redirect whose host is not valid UTF-8, before SABnzbd hears of it" do
    stub(fn conn ->
      case conn.request_path do
        "/api" ->
          flunk("SABnzbd must not be contacted when the fetch redirect is invalid")

        "/redirect" ->
          conn
          |> Plug.Conn.put_resp_header("location", "https://\xff.example/file.nzb")
          |> Plug.Conn.send_resp(302, "")
      end
    end)

    assert {:error, :invalid_url} =
             Sabnzbd.add(%{download_url: "http://provider.test/redirect"}, fetch: &Fetch.bytes/3)
  end

  test "add/2 names the job with the operation key when the release has no title" do
    stub_fetch_then_addfile(fn conn ->
      assert conn.params["nzbname"] == "cinder-op-123"
      Req.Test.json(conn, %{"status" => true, "nzo_ids" => ["nzo-123"]})
    end)

    assert {:ok, "nzo-123"} =
             Sabnzbd.add(%{download_url: "http://x/nzb"},
               operation_key: "op-123",
               fetch: &Fetch.bytes/3
             )
  end

  test "add/2 names the job after the release title, suffixed with the operation key" do
    # SABnzbd's "deobfuscate final filenames" renames the video to the job name — a
    # title-bearing name survives that, a bare cinder-<key> name would erase every
    # episode marker the downstream parser needs.
    stub_fetch_then_addfile(fn conn ->
      assert conn.params["nzbname"] == "Cowboy.Bebop.S01E22.1080p.BluRay-Kitsune.cinder-op-123"
      Req.Test.json(conn, %{"status" => true, "nzo_ids" => ["nzo-123"]})
    end)

    assert {:ok, "nzo-123"} =
             Sabnzbd.add(
               %{download_url: "http://x/nzb", title: "Cowboy.Bebop.S01E22.1080p.BluRay-Kitsune"},
               operation_key: "op-123",
               fetch: &Fetch.bytes/3
             )
  end

  test "add/2 falls back to the plain operation-key name when the title is empty" do
    stub_fetch_then_addfile(fn conn ->
      assert conn.params["nzbname"] == "cinder-op-123"
      Req.Test.json(conn, %{"status" => true, "nzo_ids" => ["nzo-123"]})
    end)

    assert {:ok, "nzo-123"} =
             Sabnzbd.add(%{download_url: "http://x/nzb", title: ""},
               operation_key: "op-123",
               fetch: &Fetch.bytes/3
             )
  end

  test "add/2 sanitizes filesystem-hostile characters out of the title" do
    stub_fetch_then_addfile(fn conn ->
      assert conn.params["nzbname"] == "A.B.C.D.cinder-op-123"
      Req.Test.json(conn, %{"status" => true, "nzo_ids" => ["nzo-123"]})
    end)

    assert {:ok, "nzo-123"} =
             Sabnzbd.add(
               %{download_url: "http://x/nzb", title: ~s(A/B\\C:D*?"<>|)},
               operation_key: "op-123",
               fetch: &Fetch.bytes/3
             )
  end

  test "add/2 caps the nzbname at 200 bytes for a very long ASCII title" do
    long_title = String.duplicate("A", 260)

    stub_fetch_then_addfile(fn conn ->
      nzbname = conn.params["nzbname"]
      assert byte_size(nzbname) == 200
      assert String.ends_with?(nzbname, "cinder-op-123")
      Req.Test.json(conn, %{"status" => true, "nzo_ids" => ["nzo-123"]})
    end)

    assert {:ok, "nzo-123"} =
             Sabnzbd.add(
               %{download_url: "http://x/nzb", title: long_title},
               operation_key: "op-123",
               fetch: &Fetch.bytes/3
             )
  end

  test "add/2 caps the nzbname at 200 bytes for a long multi-byte (CJK) title" do
    long_title = String.duplicate("葬", 260)

    stub_fetch_then_addfile(fn conn ->
      nzbname = conn.params["nzbname"]
      assert byte_size(nzbname) <= 200
      assert String.ends_with?(nzbname, "cinder-op-123")
      assert String.valid?(nzbname)
      Req.Test.json(conn, %{"status" => true, "nzo_ids" => ["nzo-123"]})
    end)

    assert {:ok, "nzo-123"} =
             Sabnzbd.add(
               %{download_url: "http://x/nzb", title: long_title},
               operation_key: "op-123",
               fetch: &Fetch.bytes/3
             )
  end

  test "find_by_operation_key/1 finds a legacy slot named exactly cinder-<key>" do
    stub(fn conn ->
      assert conn.params["search"] == "cinder-op-123"

      body =
        case conn.params["mode"] do
          "queue" ->
            %{
              "queue" => %{
                "slots" => [%{"filename" => "cinder-op-123", "nzo_id" => "nzo-queue"}]
              }
            }

          "history" ->
            %{"history" => %{"slots" => []}}
        end

      Req.Test.json(conn, body)
    end)

    assert {:ok, "nzo-queue"} = Sabnzbd.find_by_operation_key("op-123")
  end

  test "find_by_operation_key/1 finds a slot named with the title-suffixed format" do
    stub(fn conn ->
      body =
        case conn.params["mode"] do
          "queue" ->
            %{
              "queue" => %{
                "slots" => [
                  %{
                    "filename" => "Cowboy.Bebop.S01E22.cinder-op-123",
                    "nzo_id" => "nzo-queue"
                  }
                ]
              }
            }

          "history" ->
            %{"history" => %{"slots" => []}}
        end

      Req.Test.json(conn, body)
    end)

    assert {:ok, "nzo-queue"} = Sabnzbd.find_by_operation_key("op-123")
  end

  test "find_by_operation_key/1 does not match a slot whose name merely starts with the key" do
    stub(fn conn ->
      case {conn.params["mode"], conn.params["archive"]} do
        {"queue", _} ->
          Req.Test.json(conn, %{
            "queue" => %{
              "slots" => [%{"filename" => "cinder-op-123-extra", "nzo_id" => "wrong"}]
            }
          })

        {"history", _} ->
          Req.Test.json(conn, %{"history" => %{"slots" => []}})
      end
    end)

    assert :not_found = Sabnzbd.find_by_operation_key("op-123")
  end

  test "find_by_operation_key/1 searches normal history after a queue miss" do
    stub(fn conn ->
      case {conn.params["mode"], conn.params["archive"]} do
        {"queue", _} ->
          Req.Test.json(conn, %{
            "queue" => %{
              "slots" => [%{"filename" => "cinder-op-999", "nzo_id" => "wrong"}]
            }
          })

        {"history", "0"} ->
          assert conn.params["search"] == "cinder-op-123"

          Req.Test.json(conn, %{
            "history" => %{
              "slots" => [%{"name" => "cinder-op-123", "nzo_id" => "nzo-history"}]
            }
          })

        {"history", "1"} ->
          Req.Test.json(conn, %{"history" => %{"slots" => []}})
      end
    end)

    assert {:ok, "nzo-history"} = Sabnzbd.find_by_operation_key("op-123")
  end

  test "find_by_operation_key/1 searches archived history after normal history misses" do
    stub(fn conn ->
      case {conn.params["mode"], conn.params["archive"]} do
        {"queue", _} ->
          Req.Test.json(conn, %{"queue" => %{"slots" => []}})

        {"history", "0"} ->
          Req.Test.json(conn, %{"history" => %{"slots" => []}})

        {"history", "1"} ->
          assert conn.params["search"] == "cinder-op-123"

          Req.Test.json(conn, %{
            "history" => %{
              "slots" => [
                %{"nzb_name" => "Title.cinder-op-123.nzb", "nzo_id" => "nzo-archive"}
              ]
            }
          })
      end
    end)

    assert {:ok, "nzo-archive"} = Sabnzbd.find_by_operation_key("op-123")
  end

  test "find_by_operation_key/1 matches a failed-URL-fetch job SABnzbd renamed with ' - <url>'" do
    # urlgrabber.py's fail_to_history renames the job to "<our nzbname> - <url>", appended
    # AFTER our suffix — the key ends up mid-string, not at the tail.
    stub(fn conn ->
      body =
        case conn.params["mode"] do
          "queue" ->
            %{"queue" => %{"slots" => []}}

          "history" ->
            %{
              "history" => %{
                "slots" => [
                  %{
                    # Uppercase scheme: the URL validator downcases only for checking and
                    # submits the original string, so SAB's fail-rename can carry "HTTP://".
                    "name" => "Title.cinder-op-123 - HTTP://indexer/get/123",
                    "nzo_id" => "nzo-failed"
                  }
                ]
              }
            }
        end

      Req.Test.json(conn, body)
    end)

    assert {:ok, "nzo-failed"} = Sabnzbd.find_by_operation_key("op-123")
  end

  test "find_by_operation_key/1 rejects duplicate exact queue names" do
    stub(fn conn ->
      body =
        case conn.params["mode"] do
          "queue" ->
            %{
              "queue" => %{
                "slots" => [
                  %{"filename" => "cinder-op-123", "nzo_id" => "nzo-1"},
                  %{"filename" => "cinder-op-123", "nzo_id" => "nzo-2"}
                ]
              }
            }

          "history" ->
            %{"history" => %{"slots" => []}}
        end

      Req.Test.json(conn, body)
    end)

    assert {:error, :ambiguous_operation_key} = Sabnzbd.find_by_operation_key("op-123")
  end

  test "find_by_operation_key/1 rejects distinct exact matches across queue and history" do
    stub(fn conn ->
      body =
        case {conn.params["mode"], conn.params["archive"]} do
          {"queue", _} ->
            %{"queue" => %{"slots" => [%{"name" => "cinder-op-123", "nzo_id" => "nzo-1"}]}}

          {"history", "0"} ->
            %{"history" => %{"slots" => [%{"name" => "cinder-op-123", "nzo_id" => "nzo-2"}]}}

          {"history", "1"} ->
            %{"history" => %{"slots" => []}}
        end

      Req.Test.json(conn, body)
    end)

    assert {:error, :ambiguous_operation_key} = Sabnzbd.find_by_operation_key("op-123")
  end

  test "find_by_operation_key/1 deduplicates one nzo_id repeated across tiers" do
    stub(fn conn ->
      mode = conn.params["mode"]

      Req.Test.json(conn, %{
        mode => %{
          "slots" => [%{"name" => "cinder-op-123", "nzo_id" => "same-nzo"}]
        }
      })
    end)

    assert {:ok, "same-nzo"} = Sabnzbd.find_by_operation_key("op-123")
  end

  test "find_by_operation_key/1 returns :not_found when queue and history miss" do
    stub(fn conn ->
      Req.Test.json(conn, %{conn.params["mode"] => %{"slots" => []}})
    end)

    assert :not_found = Sabnzbd.find_by_operation_key("missing")
  end

  test "find_by_operation_key/1 propagates a bad API key instead of :not_found" do
    stub(fn conn ->
      Req.Test.json(conn, %{"status" => false, "error" => "API Key Incorrect"})
    end)

    assert {:error, {:sabnzbd_api_error, "API Key Incorrect"}} =
             Sabnzbd.find_by_operation_key("op-123")
  end

  test "add/1 returns :add_rejected when SABnzbd creates no job (duplicate)" do
    stub_fetch_then_addfile(fn conn ->
      Req.Test.json(conn, %{"status" => true, "nzo_ids" => []})
    end)

    assert {:error, :add_rejected} =
             Sabnzbd.add(%{download_url: "http://x/nzb"}, fetch: &Fetch.bytes/3)
  end

  test "add/1 returns :add_rejected when SABnzbd reports status false" do
    stub_fetch_then_addfile(fn conn ->
      Req.Test.json(conn, %{"status" => false, "error" => "nope"})
    end)

    assert {:error, :add_rejected} =
             Sabnzbd.add(%{download_url: "http://x/nzb"}, fetch: &Fetch.bytes/3)
  end

  test "add/1 rejects a non-binary download_url without calling SABnzbd" do
    assert {:error, :unsupported_download_url} = Sabnzbd.add(%{download_url: nil})
  end

  defp drain_requests(acc \\ []) do
    receive do
      {:request, host, path} -> drain_requests([{host, path} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # The torrent clients read a download_url's scheme in any letter case (#1195). SABnzbd fetches
  # an upper-case http(s) link and refuses a redirect to a magnet, as before that change. A magnet
  # or ftp download_url is refused as unsupported before any request (#1230).
  test "add/1 refuses magnet and ftp links before any request, fetches upper-case http(s) links and refuses a redirect to MAGNET:" do
    test_pid = self()
    hash = "0123456789abcdef0123456789abcdef01234567"
    fetched = &[{"93.184.216.34", &1}]

    stub(fn conn ->
      send(test_pid, {:request, conn.host, conn.request_path})

      case conn.request_path do
        "/dl/" <> scheme ->
          conn
          |> Plug.Conn.put_resp_header("location", "#{scheme}:?xt=urn:btih:#{hash}")
          |> Plug.Conn.send_resp(302, "")

        _ ->
          Plug.Conn.send_resp(conn, 500, "")
      end
    end)

    for {url, expected, requests} <- [
          {"MAGNET:?xt=urn:btih:#{hash}&dn=Movie", {:error, :unsupported_download_url}, []},
          {"Magnet:?xt=urn:btih:#{hash}&dn=Movie", {:error, :unsupported_download_url}, []},
          {"MAGNET:?xt=urn:btih:#{hash}&dn=a b", {:error, :unsupported_download_url}, []},
          {"MAGNET:?xt=urn:btih:#{hash}&dn=a>b", {:error, :unsupported_download_url}, []},
          {"MAGNET:", {:error, :unsupported_download_url}, []},
          {"HTTP://indexer.example/file.torrent", {:error, {:nzb_fetch_status, 500}},
           fetched.("/file.torrent")},
          {"HTTPS://indexer.example/file.torrent", {:error, {:nzb_fetch_status, 500}},
           fetched.("/file.torrent")},
          {"ftp://indexer.example/file.torrent", {:error, :unsupported_download_url}, []},
          {"https://indexer.example/dl/MAGNET", {:error, :unsupported_download_url},
           fetched.("/dl/MAGNET")},
          {"https://indexer.example/dl/magnet", {:error, :unsupported_download_url},
           fetched.("/dl/magnet")}
        ] do
      assert {url, Sabnzbd.add(%{download_url: url}, fetch: &Fetch.bytes/3)} == {url, expected}
      assert {url, drain_requests()} == {url, requests}
    end
  end

  # Each `/hop/<n>` redirects to `/hop/<n + 1>`, and `/hop/<last>` redirects to `last_location`.
  # Every request reports its host and path, so a test can tell the hops from a call to `/api`.
  defp stub_redirect_hops(last, last_location) do
    test_pid = self()

    stub(fn conn ->
      send(test_pid, {:request, conn.host, conn.request_path})

      case conn.request_path do
        "/hop/" <> n ->
          conn
          |> Plug.Conn.put_resp_header("location", hop_location(n, last, last_location))
          |> Plug.Conn.send_resp(302, "")

        "/api" ->
          Req.Test.json(conn, %{"status" => true, "nzo_ids" => ["nzo-hop"]})
      end
    end)
  end

  defp hop_location(n, last, last_location) do
    case String.to_integer(n) do
      ^last -> last_location
      hop -> "/hop/#{hop + 1}"
    end
  end

  defp hops(range), do: Enum.map(range, &{"93.184.216.34", "/hop/#{&1}"})

  test "add/1 follows five http redirects and refuses a sixth without contacting SABnzbd" do
    stub_redirect_hops(1_000, "/never")

    assert {:error, :too_many_redirects} =
             Sabnzbd.add(%{download_url: "https://indexer.example/hop/0"}, fetch: &Fetch.bytes/3)

    assert drain_requests() == hops(0..5)
  end

  test "add/1 refuses the magnet that a sixth redirect names without contacting SABnzbd" do
    hash = "0123456789abcdef0123456789abcdef01234567"
    stub_redirect_hops(5, "magnet:?xt=urn:btih:#{hash}&dn=Movie")

    assert {:error, :unsupported_download_url} =
             Sabnzbd.add(%{download_url: "https://indexer.example/hop/0"}, fetch: &Fetch.bytes/3)

    assert drain_requests() == hops(0..5)
  end

  test "add/1 refuses an NZB one byte over the 20 MiB cap without contacting SABnzbd" do
    test_pid = self()

    stub(fn conn ->
      send(test_pid, {:request, conn.host, conn.request_path})
      Req.Test.text(conn, String.duplicate("x", 20 * 1024 * 1024 + 1))
    end)

    assert {:error, :response_too_large} =
             Sabnzbd.add(%{download_url: "https://indexer.example/big.nzb"},
               fetch: &Fetch.bytes/3
             )

    assert drain_requests() == [{"93.184.216.34", "/big.nzb"}]
  end

  # `Req.Test` parses a multipart body of at most 8 MB, so SABnzbd's side here is a Req adapter
  # function, which reads the posted body as it is.
  test "add/1 fetches an NZB of exactly the 20 MiB cap and posts all of it to SABnzbd" do
    test_pid = self()
    nzb = String.duplicate("x", 20 * 1024 * 1024)

    sabnzbd = fn request ->
      body = request.body |> Enum.to_list() |> IO.iodata_to_binary()
      send(test_pid, {:addfile, request.method, request.url.path, String.contains?(body, nzb)})

      response =
        Req.Response.new(status: 200, body: ~s({"nzo_ids": ["nzo-big"]}))
        |> Req.Response.put_header("content-type", "application/json")

      {request, response}
    end

    ConfigCase.put_config(Sabnzbd, req_options: [adapter: sabnzbd, retry: false])
    stub(fn conn -> Req.Test.text(conn, nzb) end)

    assert {:ok, "nzo-big"} =
             Sabnzbd.add(%{download_url: "https://indexer.example/big.nzb"},
               fetch: &Fetch.bytes/3
             )

    assert_received {:addfile, :post, "/api", true}
  end

  test "add/1 does not retry a transient failure (no duplicate downloads)" do
    # Re-enable Req's default retry for this test; the addfile path must override it to false.
    # Without the fix a 503 on the side-effecting POST would be retried up to 3×, re-queuing it.
    ConfigCase.put_config(Sabnzbd, req_options: [plug: {Req.Test, Cinder.SabnzbdStub}])
    test_pid = self()

    stub(fn conn ->
      case conn.request_path do
        "/api" ->
          send(test_pid, :add_called)
          conn |> Plug.Conn.put_status(503) |> Req.Test.text("busy")

        _ ->
          Req.Test.text(conn, "nzb-bytes")
      end
    end)

    assert {:error, {:sabnzbd_status, 503}} =
             Sabnzbd.add(%{download_url: "http://x/nzb"}, fetch: &Fetch.bytes/3)

    assert_received :add_called
    refute_received :add_called
  end

  test "add/1 succeeds on a non-empty nzo_ids regardless of the status field's type" do
    # Robust to SABnzbd version variance: a returned job id means success even if
    # `status` is reported as 1/absent rather than the boolean true.
    stub_fetch_then_addfile(fn conn ->
      Req.Test.json(conn, %{"status" => 1, "nzo_ids" => ["SABnzbd_nzo_z"]})
    end)

    assert {:ok, "SABnzbd_nzo_z"} =
             Sabnzbd.add(%{download_url: "http://x/nzb"}, fetch: &Fetch.bytes/3)
  end

  test "status/1 normalizes a queued download's progress and eta" do
    stub(fn conn ->
      assert conn.params["mode"] == "queue"
      assert conn.params["nzo_ids"] == "nzo-1"

      Req.Test.json(conn, %{
        "queue" => %{
          "slots" => [
            %{
              "nzo_id" => "nzo-1",
              "status" => "Downloading",
              "percentage" => "42",
              "timeleft" => "0:01:30"
            }
          ]
        }
      })
    end)

    assert {:ok, %{state: :downloading, progress: 0.42, speed: nil, eta: 90}} =
             Sabnzbd.status("nzo-1")
  end

  test "status/1 omits a malformed SABnzbd eta" do
    stub(fn conn ->
      Req.Test.json(conn, %{
        "queue" => %{
          "slots" => [
            %{
              "nzo_id" => "nzo-1",
              "status" => "Downloading",
              "percentage" => "42",
              "timeleft" => "unknown"
            }
          ]
        }
      })
    end)

    assert {:ok, %{state: :downloading, progress: 0.42, speed: nil, eta: nil}} =
             Sabnzbd.status("nzo-1")
  end

  describe "status/1 under a queue-wide pause" do
    # What SABnzbd 5.1.3 answers for a job waiting in a paused queue: its own status stays
    # `Queued`, the header says `paused`, and every non-forced slot's `timeleft` is `0:00:00`.
    @waiting %{
      "nzo_id" => "nzo-1",
      "status" => "Queued",
      "priority" => "Normal",
      "percentage" => "0",
      "timeleft" => "0:00:00"
    }

    defp stub_queue(slot, header) do
      stub(fn conn ->
        assert conn.params["mode"] == "queue"
        assert conn.params["nzo_ids"] == "nzo-1"
        Req.Test.json(conn, %{"queue" => Map.put(header, "slots", [slot])})
      end)
    end

    test "reports a waiting job as paused by the client, with no estimate" do
      stub_queue(@waiting, %{"paused" => true, "status" => "Paused"})

      assert {:ok, %{state: :downloading, client_paused: true, progress: +0.0, eta: nil}} =
               Sabnzbd.status("nzo-1")
    end

    test "does not report a job as paused while the queue runs" do
      stub_queue(%{@waiting | "timeleft" => "0:01:30"}, %{"paused" => false})

      assert {:ok, %{state: :downloading, eta: 90} = report} = Sabnzbd.status("nzo-1")
      refute Map.has_key?(report, :client_paused)
    end

    # SABnzbd keeps downloading a Force job through a global pause, so its clock must keep running.
    test "does not report a forced job as paused" do
      forced = %{
        @waiting
        | "priority" => "Force",
          "status" => "Downloading",
          "timeleft" => "0:02:00"
      }

      stub_queue(forced, %{"paused" => true})

      assert {:ok, %{state: :downloading, eta: 120} = report} = Sabnzbd.status("nzo-1")
      refute Map.has_key?(report, :client_paused)
    end

    test "keeps a job paused or failed on its own as an error" do
      for status <- ["Paused", "Failed"] do
        stub_queue(%{@waiting | "status" => status}, %{"paused" => true})

        result = Sabnzbd.status("nzo-1")
        assert match?({:ok, %{state: :error}}, result), status
        {:ok, report} = result
        refute Map.has_key?(report, :client_paused), status
      end
    end

    test "reads the pause only from a boolean true" do
      for header <- [%{}, %{"paused" => "true"}, %{"paused" => 1}, %{"paused" => nil}] do
        stub_queue(@waiting, header)

        result = Sabnzbd.status("nzo-1")
        assert match?({:ok, %{state: :downloading}}, result), inspect(header)
        {:ok, report} = result
        refute Map.has_key?(report, :client_paused), inspect(header)
      end
    end

    test "gives no estimate for a 0:00:00 timeleft in a running queue" do
      stub_queue(%{@waiting | "status" => "Propagating"}, %{"paused" => false})

      assert {:ok, %{state: :downloading, eta: nil}} = Sabnzbd.status("nzo-1")
    end

    # A job that left the queue is post-processing, which a queue pause does not hold.
    test "does not report a job in post-processing as paused" do
      stub_queue_then_history(%{
        "history" => %{"slots" => [%{"nzo_id" => "nzo-1", "status" => "Extracting"}]}
      })

      assert {:ok, %{state: :downloading, progress: 1.0} = report} = Sabnzbd.status("nzo-1")
      refute Map.has_key?(report, :client_paused)
    end

    test "list_managed/0 keeps each queued job's state under a paused queue" do
      stub(fn conn ->
        body =
          case conn.params["mode"] do
            "queue" ->
              %{
                "queue" => %{
                  "paused" => true,
                  "slots" => [
                    %{
                      "filename" => "Waiting.cinder-3f2504e0-4f89-11d3-9a0c-0305e82c3301",
                      "nzo_id" => "nzo-q",
                      "status" => "Queued"
                    },
                    %{
                      "filename" => "Own.cinder-3f2504e0-4f89-11d3-9a0c-0305e82c3302",
                      "nzo_id" => "nzo-p",
                      "status" => "Paused"
                    }
                  ]
                }
              }

            "history" ->
              %{"history" => %{"slots" => []}}
          end

        Req.Test.json(conn, body)
      end)

      assert {:ok, entries} = Sabnzbd.list_managed()

      assert entries |> Map.new(&{&1.id, &1.state}) ==
               %{"nzo-q" => :downloading, "nzo-p" => :error}
    end
  end

  test "status/1 reports a paused queue slot as :error so the poller can bound it" do
    # A queued-but-stalled slot (Paused — e.g. SABnzbd's Pause on Duplicates) would
    # otherwise read as :downloading forever and never advance or fail.
    stub(fn conn ->
      assert conn.params["mode"] == "queue"

      Req.Test.json(conn, %{
        "queue" => %{
          "slots" => [%{"nzo_id" => "nzo-1", "status" => "Paused", "percentage" => "0"}]
        }
      })
    end)

    # `:reason` carries the actionable detail the poller persists as the park reason.
    assert {:ok, %{state: :error, reason: reason}} = Sabnzbd.status("nzo-1")
    assert reason =~ "Paused by the download client"
  end

  test "status/1 reports a failed queue slot as :error" do
    stub(fn conn ->
      Req.Test.json(conn, %{
        "queue" => %{
          "slots" => [%{"nzo_id" => "nzo-1", "status" => "Failed", "percentage" => "0"}]
        }
      })
    end)

    assert {:ok, %{state: :error, reason: "The download client reported the job failed."}} =
             Sabnzbd.status("nzo-1")
  end

  test "status/1 reports a completed download as :completed with the storage path" do
    stub_queue_then_history(%{
      "history" => %{
        "slots" => [
          %{"nzo_id" => "nzo-1", "status" => "Completed", "storage" => "/downloads/done/Movie"}
        ]
      }
    })

    assert {:ok, %{state: :completed, content_path: "/downloads/done/Movie"}} =
             Sabnzbd.status("nzo-1")
  end

  test "status/1 translates mapped storage at the adapter boundary" do
    configure_path_mapping("/downloads/", "/media/usenet/")

    stub_queue_then_history(%{
      "history" => %{
        "slots" => [
          %{"nzo_id" => "nzo-1", "status" => "Completed", "storage" => "/downloads/done/Movie"}
        ]
      }
    })

    assert {:ok, %{content_path: "/media/usenet/done/Movie"}} = Sabnzbd.status("nzo-1")
  end

  test "status/1 reports a failed download as :error, carrying SABnzbd's fail_message" do
    stub_queue_then_history(%{
      "history" => %{
        "slots" => [%{"nzo_id" => "nzo-1", "status" => "Failed", "fail_message" => "boom"}]
      }
    })

    assert {:ok, %{state: :error, reason: "boom"}} = Sabnzbd.status("nzo-1")
  end

  test "status/1 falls back to a generic reason for a failed download with no fail_message" do
    stub_queue_then_history(%{
      "history" => %{"slots" => [%{"nzo_id" => "nzo-1", "status" => "Failed"}]}
    })

    assert {:ok, %{state: :error, reason: "The download client reported the job failed."}} =
             Sabnzbd.status("nzo-1")
  end

  test "status/1 treats a post-processing history slot as still :downloading" do
    stub_queue_then_history(%{
      "history" => %{"slots" => [%{"nzo_id" => "nzo-1", "status" => "Extracting"}]}
    })

    assert {:ok, %{state: :downloading}} = Sabnzbd.status("nzo-1")
  end

  test "status/1 returns :not_found when the nzo_id is in neither queue nor history" do
    stub_queue_then_history(%{"history" => %{"slots" => []}})

    assert {:error, :not_found} = Sabnzbd.status("nzo-1")
  end

  # The test config's `req_options` set `retry: false`, so this test sets only the plug: Req would
  # otherwise retry a GET that answers 503 three times, 1, 2 and 4 s apart (#1429).
  test "status/1 sends one request to a server that answers 503" do
    test_pid = self()
    put_config(Sabnzbd, req_options: [plug: {Req.Test, Cinder.SabnzbdStub}])

    stub(fn conn ->
      send(test_pid, {:request, conn.params["mode"]})
      Plug.Conn.send_resp(conn, 503, "")
    end)

    assert {:error, {:sabnzbd_status, 503}} = Sabnzbd.status("nzo-1")
    assert_received {:request, "queue"}
    refute_received {:request, _mode}
  end

  test "status/1 propagates a bad API key instead of :not_found" do
    stub(fn conn ->
      assert conn.params["nzo_ids"] == "nzo-1"
      Req.Test.json(conn, %{"status" => false, "error" => "API Key Incorrect"})
    end)

    assert {:error, {:sabnzbd_api_error, "API Key Incorrect"}} = Sabnzbd.status("nzo-1")
  end

  test "health/0 pings an auth-checked mode with the api key and returns :ok on success" do
    stub(fn conn ->
      assert conn.request_path == "/api"
      assert conn.params["apikey"] == "test-key"

      # A healthy probe also reads misc config (best-effort); a benign config logs nothing.
      case conn.params["mode"] do
        "queue" ->
          Req.Test.json(conn, %{"queue" => %{"slots" => []}})

        "get_config" ->
          Req.Test.json(conn, %{"config" => %{"misc" => %{"folder_max_length" => 246}}})
      end
    end)

    assert :ok = Sabnzbd.health()
  end

  test "health/0 warns without marking reachable SABnzbd as an error" do
    stub(fn conn ->
      case conn.params["mode"] do
        "queue" ->
          Req.Test.json(conn, %{"queue" => %{"slots" => []}})

        "get_config" ->
          Req.Test.json(conn, %{
            "config" => %{
              "misc" => %{"folder_max_length" => 60, "no_dupes" => 0, "no_series_dupes" => 2}
            }
          })
      end
    end)

    log =
      capture_log(fn ->
        assert {:warning,
                {:sabnzbd_config,
                 [
                   {:folder_max_length, 60},
                   {:duplicate_handling, :series, 2}
                 ]}} = Sabnzbd.health()
      end)

    assert log =~ "folder_max_length is 60"
    assert log =~ "series duplicate detection"
    refute log =~ "Pause on Duplicates"
  end

  test "health/0 stays :ok when the config read fails or is shaped unexpectedly" do
    stub(fn conn ->
      case conn.params["mode"] do
        "queue" -> Req.Test.json(conn, %{"queue" => %{"slots" => []}})
        "get_config" -> conn |> Plug.Conn.put_status(500) |> Req.Test.text("boom")
      end
    end)

    log = capture_log(fn -> assert :ok = Sabnzbd.health() end)
    refute log =~ "folder_max_length"
  end

  test "health/0 rejects a configured mapping whose local prefix is missing" do
    missing =
      Path.join(System.tmp_dir!(), "cinder-missing-#{System.unique_integer([:positive])}")

    configure_path_mapping("/downloads", missing)

    stub(fn conn ->
      case conn.params["mode"] do
        "queue" ->
          Req.Test.json(conn, %{"queue" => %{"slots" => []}})

        "get_config" ->
          Req.Test.json(conn, %{
            "config" => %{"misc" => %{"folder_max_length" => 60}}
          })
      end
    end)

    assert {:error, {:path_mapping_local_prefix_unreadable, ^missing}} = Sabnzbd.health()
  end

  test "health/0 returns an error when SABnzbd rejects the api key (200 + status false)" do
    stub(fn conn ->
      Req.Test.json(conn, %{"status" => false, "error" => "API Key Incorrect"})
    end)

    assert {:error, :bad_api_key} = Sabnzbd.health()
  end

  test "health/0 returns an error tuple on a non-2xx status" do
    stub(fn conn -> conn |> Plug.Conn.put_status(500) |> Req.Test.text("boom") end)

    assert {:error, {:sabnzbd_status, 500}} = Sabnzbd.health()
  end

  test "health/0 probes exactly once — no retries against a failing server" do
    # The probe is bounded (retry: false): Req's default policy would re-hit a 500
    # up to 3 more times with backoff, hanging "Test connection" for ~7s per probe.
    parent = self()

    stub(fn conn ->
      send(parent, :probed)
      conn |> Plug.Conn.put_status(500) |> Req.Test.text("boom")
    end)

    assert {:error, {:sabnzbd_status, 500}} = Sabnzbd.health()
    assert_received :probed
    refute_received :probed
  end

  test "status/1 falls through to history when the queue response omits slots" do
    # A queue payload without a "slots" key must not short-circuit to an error
    # that strands the poll — fall through to history (where a finished job lives).
    stub(fn conn ->
      case conn.params["mode"] do
        "queue" ->
          Req.Test.json(conn, %{"queue" => %{"paused" => false}})

        "history" ->
          Req.Test.json(conn, %{
            "history" => %{
              "slots" => [%{"nzo_id" => "nzo-1", "status" => "Completed", "storage" => "/d/M"}]
            }
          })
      end
    end)

    assert {:ok, %{state: :completed, content_path: "/d/M"}} = Sabnzbd.status("nzo-1")
  end

  test "remove/2 deletes from the queue with del_files=1 by default" do
    stub(fn conn ->
      assert conn.request_path == "/api"
      assert conn.params["mode"] == "queue"
      assert conn.params["name"] == "delete"
      assert conn.params["value"] == "nzo-1"
      assert conn.params["del_files"] == "1"
      assert conn.params["apikey"] == "test-key"
      Req.Test.json(conn, %{"status" => true})
    end)

    assert :ok = Sabnzbd.remove("nzo-1", [])
  end

  test "remove/2 falls through to history when the queue delete reports no match" do
    stub(fn conn ->
      case conn.params["mode"] do
        "queue" ->
          Req.Test.json(conn, %{"status" => false})

        "history" ->
          assert conn.params["name"] == "delete"
          assert conn.params["value"] == "nzo-1"
          Req.Test.json(conn, %{"status" => true})
      end
    end)

    assert :ok = Sabnzbd.remove("nzo-1", [])
  end

  test "remove/2 honours delete_files: false (del_files=0)" do
    stub(fn conn ->
      assert conn.params["del_files"] == "0"
      Req.Test.json(conn, %{"status" => true})
    end)

    assert :ok = Sabnzbd.remove("nzo-1", delete_files: false)
  end

  test "remove/2 is idempotent: an unknown id (false in both lists) still returns :ok" do
    stub(fn conn -> Req.Test.json(conn, %{"status" => false}) end)
    assert :ok = Sabnzbd.remove("ghost", [])
  end

  test "remove/2 returns an error tuple on a non-2xx status" do
    stub(fn conn -> conn |> Plug.Conn.put_status(500) |> Req.Test.text("boom") end)
    assert {:error, {:sabnzbd_status, 500}} = Sabnzbd.remove("nzo-1", [])
  end

  test "remove/2 propagates a bad API key instead of :ok" do
    stub(fn conn ->
      Req.Test.json(conn, %{"status" => false, "error" => "API Key Incorrect"})
    end)

    assert {:error, {:sabnzbd_api_error, "API Key Incorrect"}} = Sabnzbd.remove("nzo-1", [])
  end

  test "add/1 does not forward the API query key across redirects" do
    # SABnzbd's own /api response must never be auto-followed on a redirect (redirect: false):
    # the apikey query param only ever appears on calls to SABnzbd's own base_url, so this
    # exercises the addfile POST specifically, with the NZB fetch itself uninvolved.
    parent = self()

    for status <- [301, 302, 303, 307, 308] do
      stub(fn conn ->
        case {conn.host, conn.request_path} do
          {"attacker.test", _} ->
            send(parent, {:attacker_called, conn.query_string})
            Req.Test.json(conn, %{"nzo_ids" => ["bad"]})

          {_, "/getnzb"} ->
            Req.Test.text(conn, "nzb-bytes")

          {_, "/api"} ->
            conn
            |> Plug.Conn.put_resp_header("location", "https://attacker.test/api")
            |> Plug.Conn.send_resp(status, "")
        end
      end)

      log =
        capture_log(fn ->
          assert {:error, {:sabnzbd_status, ^status}} =
                   Sabnzbd.add(%{download_url: "https://provider.test/getnzb"},
                     fetch: &Fetch.bytes/3
                   )
        end)

      refute_received {:attacker_called, _}
      refute log =~ "test-key"
    end
  end

  test "add/1 rejects an unsafe provider URL before delegating the fetch" do
    stub(fn _conn -> flunk("unsafe provider URL must not reach SABnzbd") end)

    assert {:error, :forbidden_address} =
             Sabnzbd.add(%{download_url: "http://127.0.0.1/private.nzb"}, fetch: &Fetch.bytes/3)
  end

  test "add/1 delegates a private URL proven to share the configured indexer origin" do
    stub(fn conn ->
      case conn.request_path do
        "/getnzb/1" ->
          assert conn.host == "127.0.0.1"
          Req.Test.text(conn, "nzb-bytes")

        "/api" ->
          assert conn.params["mode"] == "addfile"
          Req.Test.json(conn, %{"status" => true, "nzo_ids" => ["nzo-proxy"]})
      end
    end)

    assert {:ok, "nzo-proxy"} =
             Sabnzbd.add(
               %{
                 download_url: "http://127.0.0.1:9696/getnzb/1",
                 download_url_origin: "http://127.0.0.1:9696"
               },
               fetch: &Fetch.bytes/3
             )
  end

  test "status/1 rejects an oversized JSON response" do
    stub(fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"padding":"#{String.duplicate("x", 4 * 1024 * 1024)}"}))
    end)

    assert {:error, :response_too_large} = Sabnzbd.status("nzo-1")
  end

  @key "3f2504e0-4f89-11d3-9a0c-0305e82c3301"

  test "files/1 returns the job's file names" do
    stub(fn conn ->
      assert conn.params["mode"] == "get_files"
      assert conn.params["value"] == "nzo-1"

      Req.Test.json(conn, %{
        "files" => [
          %{"filename" => "Movie.mkv", "bytes" => 1},
          %{"filename" => "Movie.nfo", "bytes" => 2},
          %{"bytes" => 3}
        ]
      })
    end)

    assert {:ok, ["Movie.mkv", "Movie.nfo"]} = Sabnzbd.files("nzo-1")
  end

  test "files/1 treats a job with no file list as no opinion, not a failure" do
    stub(fn conn -> Req.Test.json(conn, %{"error" => "no such job"}) end)

    assert {:ok, []} = Sabnzbd.files("nzo-gone")
  end

  test "list_managed/0 reports cinder-named queue and history jobs with their state" do
    stub(fn conn ->
      assert conn.params["search"] == "cinder-"

      body =
        case conn.params["mode"] do
          "queue" ->
            %{
              "queue" => %{
                "slots" => [
                  %{
                    "filename" => "Movie.cinder-#{@key}",
                    "nzo_id" => "nzo-q",
                    "status" => "Downloading"
                  },
                  # The household's own job — no cinder marker, so not ours.
                  %{
                    "filename" => "Some.Other.Job",
                    "nzo_id" => "nzo-mine",
                    "status" => "Downloading"
                  }
                ]
              }
            }

          "history" ->
            %{
              "history" => %{
                "slots" => [
                  %{
                    "name" => "Show.cinder-#{@key}.nzb",
                    "nzo_id" => "nzo-h",
                    "status" => "Failed"
                  }
                ]
              }
            }
        end

      Req.Test.json(conn, body)
    end)

    assert {:ok, entries} = Sabnzbd.list_managed()

    assert entries == [
             %{id: "nzo-q", operation_key: @key, state: :downloading},
             %{id: "nzo-h", operation_key: @key, state: :error}
           ]
  end

  # The collision the module's find_by_operation_key/1 comment warns about: a completed download's
  # own output file re-entering the indexer as a future release title. The key is mid-string there,
  # not at the tail, so it must not be claimed — a caller that removes what it finds would
  # otherwise reap someone else's job.
  test "list_managed/0 does not claim a job whose name merely contains a key mid-string" do
    stub(fn conn ->
      body =
        case conn.params["mode"] do
          "queue" ->
            %{
              "queue" => %{
                "slots" => [
                  %{"filename" => "Movie.cinder-#{@key}.mkv", "nzo_id" => "nzo-repost"}
                ]
              }
            }

          "history" ->
            %{"history" => %{"slots" => []}}
        end

      Req.Test.json(conn, body)
    end)

    assert {:ok, []} = Sabnzbd.list_managed()
  end

  test "list_managed/0 reports a finished job's completion time from its history slot" do
    stub(fn conn ->
      body =
        case conn.params["mode"] do
          "queue" ->
            %{"queue" => %{"slots" => [], "noofslots" => 0}}

          "history" ->
            %{
              "history" => %{
                "slots" => [
                  %{
                    "name" => "Show.cinder-#{@key}",
                    "nzo_id" => "nzo-h",
                    "status" => "Completed",
                    "completed" => 1_760_000_000
                  }
                ],
                "noofslots" => 1
              }
            }
        end

      Req.Test.json(conn, body)
    end)

    assert {:ok, [%{id: "nzo-h", state: :completed, completed_at: 1_760_000_000}]} =
             Sabnzbd.list_managed()
  end

  # #684: SABnzbd answers one page (10 slots) unless told otherwise, so a sweep that stopped at
  # the first response could never see an orphan older than the newest 10 Cinder jobs.
  test "list_managed/0 pages through more Cinder history entries than fit one page" do
    keys = for _ <- 1..250, do: Ecto.UUID.generate()

    history =
      keys
      |> Enum.with_index()
      |> Enum.map(fn {key, i} ->
        %{"name" => "Show.#{i}.cinder-#{key}", "nzo_id" => "nzo-#{i}", "status" => "Completed"}
      end)

    stub(fn conn ->
      params = conn.params

      body =
        case params["mode"] do
          "queue" ->
            %{"queue" => %{"slots" => [], "noofslots" => 0}}

          "history" ->
            start = String.to_integer(params["start"] || "0")
            limit = String.to_integer(params["limit"] || "10")

            %{
              "history" => %{
                "slots" => history |> Enum.drop(start) |> Enum.take(limit),
                "noofslots" => length(history)
              }
            }
        end

      Req.Test.json(conn, body)
    end)

    assert {:ok, entries} = Sabnzbd.list_managed()
    assert Enum.map(entries, & &1.id) == for(i <- 0..249, do: "nzo-#{i}")
    assert Enum.all?(entries, &(&1.state == :completed))
  end

  test "list_managed/0 stops paging when SABnzbd misreports its total" do
    stub(fn conn ->
      mode = conn.params["mode"]
      start = String.to_integer(conn.params["start"])

      # Always a full page of fresh slots and a total that never gets reached.
      slots =
        for i <- start..(start + String.to_integer(conn.params["limit"]) - 1) do
          %{"name" => "S.cinder-#{Ecto.UUID.generate()}", "nzo_id" => "nzo-#{i}"}
        end

      Req.Test.json(conn, %{mode => %{"slots" => slots, "noofslots" => 1_000_000_000}})
    end)

    # Returns (bounded) instead of looping forever; the exact cap is an implementation detail.
    assert {:ok, entries} = Sabnzbd.list_managed()
    assert length(entries) > 1_000
  end

  test "list_managed/0 tolerates a 200 with no slots" do
    stub(fn conn -> Req.Test.json(conn, %{}) end)

    assert {:ok, []} = Sabnzbd.list_managed()
  end
end
