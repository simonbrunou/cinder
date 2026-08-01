defmodule Cinder.Download.Client.SabnzbdTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Cinder.Download.Client.Sabnzbd

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
          assert conn.host == "prowlarr"
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
             Sabnzbd.add(%{download_url: "http://prowlarr/getnzb/1?apikey=k&id=9"})
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

    assert {:ok, "nzo-1"} = Sabnzbd.add(%{download_url: "http://prowlarr/getnzb/1"})
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
             Sabnzbd.add(%{download_url: "http://provider.test/redirect"})
  end

  test "add/2 names the job with the operation key when the release has no title" do
    stub_fetch_then_addfile(fn conn ->
      assert conn.params["nzbname"] == "cinder-op-123"
      Req.Test.json(conn, %{"status" => true, "nzo_ids" => ["nzo-123"]})
    end)

    assert {:ok, "nzo-123"} =
             Sabnzbd.add(%{download_url: "http://x/nzb"}, operation_key: "op-123")
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
               operation_key: "op-123"
             )
  end

  test "add/2 falls back to the plain operation-key name when the title is empty" do
    stub_fetch_then_addfile(fn conn ->
      assert conn.params["nzbname"] == "cinder-op-123"
      Req.Test.json(conn, %{"status" => true, "nzo_ids" => ["nzo-123"]})
    end)

    assert {:ok, "nzo-123"} =
             Sabnzbd.add(%{download_url: "http://x/nzb", title: ""}, operation_key: "op-123")
  end

  test "add/2 sanitizes filesystem-hostile characters out of the title" do
    stub_fetch_then_addfile(fn conn ->
      assert conn.params["nzbname"] == "A.B.C.D.cinder-op-123"
      Req.Test.json(conn, %{"status" => true, "nzo_ids" => ["nzo-123"]})
    end)

    assert {:ok, "nzo-123"} =
             Sabnzbd.add(
               %{download_url: "http://x/nzb", title: ~s(A/B\\C:D*?"<>|)},
               operation_key: "op-123"
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
               operation_key: "op-123"
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
               operation_key: "op-123"
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

  test "add/1 returns :add_rejected when SABnzbd creates no job (duplicate)" do
    stub_fetch_then_addfile(fn conn ->
      Req.Test.json(conn, %{"status" => true, "nzo_ids" => []})
    end)

    assert {:error, :add_rejected} = Sabnzbd.add(%{download_url: "http://x/nzb"})
  end

  test "add/1 returns :add_rejected when SABnzbd reports status false" do
    stub_fetch_then_addfile(fn conn ->
      Req.Test.json(conn, %{"status" => false, "error" => "nope"})
    end)

    assert {:error, :add_rejected} = Sabnzbd.add(%{download_url: "http://x/nzb"})
  end

  test "add/1 rejects a non-binary download_url without calling SABnzbd" do
    assert {:error, :unsupported_download_url} = Sabnzbd.add(%{download_url: nil})
  end

  test "add/1 does not retry a transient failure (no duplicate downloads)" do
    # Re-enable Req's default retry for this test; the addfile path must override it to false.
    # Without the fix a 503 on the side-effecting POST would be retried up to 3×, re-queuing it.
    prev = Application.get_env(:cinder, Sabnzbd)
    on_exit(fn -> Application.put_env(:cinder, Sabnzbd, prev) end)

    Application.put_env(:cinder, Sabnzbd,
      base_url: "http://localhost:8080",
      api_key: "test-key",
      fetch_plug: {Req.Test, Cinder.SabnzbdStub},
      url_resolver: fn _host -> {:ok, [{93, 184, 216, 34}]} end,
      req_options: [plug: {Req.Test, Cinder.SabnzbdStub}]
    )

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

    assert {:error, {:sabnzbd_status, 503}} = Sabnzbd.add(%{download_url: "http://x/nzb"})

    assert_received :add_called
    refute_received :add_called
  end

  test "add/1 succeeds on a non-empty nzo_ids regardless of the status field's type" do
    # Robust to SABnzbd version variance: a returned job id means success even if
    # `status` is reported as 1/absent rather than the boolean true.
    stub_fetch_then_addfile(fn conn ->
      Req.Test.json(conn, %{"status" => 1, "nzo_ids" => ["SABnzbd_nzo_z"]})
    end)

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

  test "health/0 warns (but stays :ok) on config that wedges Cinder's grabs" do
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

    log = capture_log(fn -> assert :ok = Sabnzbd.health() end)
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
    stub(fn conn -> Req.Test.json(conn, %{"queue" => %{"slots" => []}}) end)

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
                   Sabnzbd.add(%{download_url: "https://provider.test/getnzb"})
        end)

      refute_received {:attacker_called, _}
      refute log =~ "test-key"
    end
  end

  test "add/1 rejects an unsafe provider URL before delegating the fetch" do
    stub(fn _conn -> flunk("unsafe provider URL must not reach SABnzbd") end)

    assert {:error, :forbidden_address} =
             Sabnzbd.add(%{download_url: "http://127.0.0.1/private.nzb"})
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
             Sabnzbd.add(%{
               download_url: "http://127.0.0.1:9696/getnzb/1",
               download_url_origin: "http://127.0.0.1:9696"
             })
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

  test "list_managed/0 tolerates a 200 with no slots" do
    stub(fn conn -> Req.Test.json(conn, %{}) end)

    assert {:ok, []} = Sabnzbd.list_managed()
  end
end
