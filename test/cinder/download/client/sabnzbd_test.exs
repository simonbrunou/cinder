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
end
