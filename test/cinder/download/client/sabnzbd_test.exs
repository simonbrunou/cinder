defmodule Cinder.Download.Client.SabnzbdTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Cinder.Download.Client.Sabnzbd

  defp stub(fun), do: Req.Test.stub(Cinder.SabnzbdStub, fun)

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

  test "add/1 posts addurl and returns the nzo_id" do
    stub(fn conn ->
      assert conn.request_path == "/api"
      assert conn.params["mode"] == "addurl"
      assert conn.params["name"] == "http://prowlarr/getnzb/1?apikey=k&id=9"
      assert conn.params["apikey"] == "test-key"
      assert conn.params["output"] == "json"
      Req.Test.json(conn, %{"status" => true, "nzo_ids" => ["SABnzbd_nzo_abc"]})
    end)

    assert {:ok, "SABnzbd_nzo_abc"} =
             Sabnzbd.add(%{download_url: "http://prowlarr/getnzb/1?apikey=k&id=9"})
  end

  test "add/2 names the job with the operation key" do
    stub(fn conn ->
      assert conn.params["mode"] == "addurl"
      assert conn.params["nzbname"] == "cinder-op-123"
      Req.Test.json(conn, %{"status" => true, "nzo_ids" => ["nzo-123"]})
    end)

    assert {:ok, "nzo-123"} =
             Sabnzbd.add(%{download_url: "http://x/nzb"}, operation_key: "op-123")
  end

  test "find_by_operation_key/1 finds an exact queue name" do
    stub(fn conn ->
      assert conn.params["mode"] == "queue"
      assert conn.params["search"] == "cinder-op-123"

      Req.Test.json(conn, %{
        "queue" => %{
          "slots" => [%{"filename" => "cinder-op-123", "nzo_id" => "nzo-queue"}]
        }
      })
    end)

    assert {:ok, "nzo-queue"} = Sabnzbd.find_by_operation_key("op-123")
  end

  test "find_by_operation_key/1 searches normal history after an exact queue miss" do
    stub(fn conn ->
      case {conn.params["mode"], conn.params["archive"]} do
        {"queue", _} ->
          Req.Test.json(conn, %{
            "queue" => %{
              "slots" => [%{"filename" => "cinder-op-123-extra", "nzo_id" => "wrong"}]
            }
          })

        {"history", "0"} ->
          assert conn.params["search"] == "cinder-op-123"

          Req.Test.json(conn, %{
            "history" => %{
              "slots" => [%{"name" => "cinder-op-123", "nzo_id" => "nzo-history"}]
            }
          })
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
              "slots" => [%{"nzb_name" => "cinder-op-123", "nzo_id" => "nzo-archive"}]
            }
          })
      end
    end)

    assert {:ok, "nzo-archive"} = Sabnzbd.find_by_operation_key("op-123")
  end

  test "find_by_operation_key/1 rejects duplicate exact queue names" do
    stub(fn conn ->
      Req.Test.json(conn, %{
        "queue" => %{
          "slots" => [
            %{"filename" => "cinder-op-123", "nzo_id" => "nzo-1"},
            %{"filename" => "cinder-op-123", "nzo_id" => "nzo-2"}
          ]
        }
      })
    end)

    assert {:error, :ambiguous_operation_key} = Sabnzbd.find_by_operation_key("op-123")
  end

  test "find_by_operation_key/1 returns :not_found when queue and history miss" do
    stub(fn conn ->
      Req.Test.json(conn, %{conn.params["mode"] => %{"slots" => []}})
    end)

    assert :not_found = Sabnzbd.find_by_operation_key("missing")
  end

  test "add/1 returns :add_rejected when SABnzbd creates no job (duplicate)" do
    stub(fn conn -> Req.Test.json(conn, %{"status" => true, "nzo_ids" => []}) end)

    assert {:error, :add_rejected} = Sabnzbd.add(%{download_url: "http://x/nzb"})
  end

  test "add/1 returns :add_rejected when SABnzbd reports status false" do
    stub(fn conn -> Req.Test.json(conn, %{"status" => false, "error" => "nope"}) end)

    assert {:error, :add_rejected} = Sabnzbd.add(%{download_url: "http://x/nzb"})
  end

  test "add/1 rejects a non-binary download_url without calling SABnzbd" do
    assert {:error, :unsupported_download_url} = Sabnzbd.add(%{download_url: nil})
  end

  test "add/1 does not retry a transient failure (no duplicate downloads)" do
    # Re-enable Req's default retry for this test; the add path must override it to false. Without
    # the fix a 503 on the side-effecting `addurl` GET would be retried up to 3×, re-queuing it.
    prev = Application.get_env(:cinder, Sabnzbd)
    on_exit(fn -> Application.put_env(:cinder, Sabnzbd, prev) end)

    Application.put_env(:cinder, Sabnzbd,
      base_url: "http://localhost:8080",
      api_key: "test-key",
      url_resolver: fn _host -> {:ok, [{93, 184, 216, 34}]} end,
      req_options: [plug: {Req.Test, Cinder.SabnzbdStub}]
    )

    test_pid = self()

    stub(fn conn ->
      send(test_pid, :add_called)
      conn |> Plug.Conn.put_status(503) |> Req.Test.text("busy")
    end)

    assert {:error, {:sabnzbd_status, 503}} = Sabnzbd.add(%{download_url: "http://x/nzb"})

    assert_received :add_called
    refute_received :add_called
  end

  test "add/1 succeeds on a non-empty nzo_ids regardless of the status field's type" do
    # Robust to SABnzbd version variance: a returned job id means success even if
    # `status` is reported as 1/absent rather than the boolean true.
    stub(fn conn -> Req.Test.json(conn, %{"status" => 1, "nzo_ids" => ["SABnzbd_nzo_z"]}) end)

    assert {:ok, "SABnzbd_nzo_z"} = Sabnzbd.add(%{download_url: "http://x/nzb"})
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

    assert {:ok, %{state: :error}} = Sabnzbd.status("nzo-1")
  end

  test "status/1 reports a failed queue slot as :error" do
    stub(fn conn ->
      Req.Test.json(conn, %{
        "queue" => %{
          "slots" => [%{"nzo_id" => "nzo-1", "status" => "Failed", "percentage" => "0"}]
        }
      })
    end)

    assert {:ok, %{state: :error}} = Sabnzbd.status("nzo-1")
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

  test "status/1 reports a failed download as :error" do
    stub_queue_then_history(%{
      "history" => %{
        "slots" => [%{"nzo_id" => "nzo-1", "status" => "Failed", "fail_message" => "boom"}]
      }
    })

    assert {:ok, %{state: :error}} = Sabnzbd.status("nzo-1")
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

  test "health/0 pings an auth-checked mode with the api key and returns :ok on success" do
    stub(fn conn ->
      assert conn.request_path == "/api"
      assert conn.params["mode"] == "queue"
      assert conn.params["apikey"] == "test-key"
      Req.Test.json(conn, %{"queue" => %{"slots" => []}})
    end)

    assert :ok = Sabnzbd.health()
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

  test "add/1 does not forward the API query key across redirects" do
    parent = self()

    for status <- [301, 302, 303, 307, 308] do
      stub(fn conn ->
        if conn.host == "attacker.test" do
          send(parent, {:attacker_called, conn.query_string})
          Req.Test.json(conn, %{"nzo_ids" => ["bad"]})
        else
          conn
          |> Plug.Conn.put_resp_header("location", "https://attacker.test/api")
          |> Plug.Conn.send_resp(status, "")
        end
      end)

      log =
        capture_log(fn ->
          assert {:error, {:sabnzbd_status, ^status}} =
                   Sabnzbd.add(%{download_url: "https://provider.test/file.nzb"})
        end)

      refute_received {:attacker_called, _}
      refute log =~ "test-key"
      refute log =~ "provider.test"
    end
  end

  test "add/1 rejects an unsafe provider URL before delegating the fetch" do
    stub(fn _conn -> flunk("unsafe provider URL must not reach SABnzbd") end)

    assert {:error, :forbidden_address} =
             Sabnzbd.add(%{download_url: "http://127.0.0.1/private.nzb"})
  end

  test "status/1 rejects an oversized JSON response" do
    stub(fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"padding":"#{String.duplicate("x", 4 * 1024 * 1024)}"}))
    end)

    assert {:error, :response_too_large} = Sabnzbd.status("nzo-1")
  end
end
