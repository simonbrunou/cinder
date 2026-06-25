defmodule Cinder.Download.Client.SabnzbdTest do
  use ExUnit.Case, async: true

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

  test "status/1 reports a queued download as :downloading with coerced progress" do
    stub(fn conn ->
      assert conn.params["mode"] == "queue"
      assert conn.params["nzo_ids"] == "nzo-1"

      Req.Test.json(conn, %{
        "queue" => %{
          "slots" => [%{"nzo_id" => "nzo-1", "status" => "Downloading", "percentage" => "42"}]
        }
      })
    end)

    assert {:ok, %{state: :downloading, progress: progress}} = Sabnzbd.status("nzo-1")
    assert_in_delta progress, 0.42, 0.0001
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
end
