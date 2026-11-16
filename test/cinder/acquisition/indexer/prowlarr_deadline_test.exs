defmodule Cinder.Acquisition.Indexer.ProwlarrDeadlineTest do
  # Not async: one test changes the shared Prowlarr config, and one sets a global trace pattern on
  # `HTTPPolicy.bounded_request/2,3`.
  use ExUnit.Case, async: false

  alias Cinder.Acquisition.Indexer.Prowlarr

  # Sends `:answer` to the stub 10 s after it reports in, unless the stub died first.
  defp answer_unless_killed do
    receive do
      {:stub, stub} ->
        ref = Process.monitor(stub)

        receive do
          {:DOWN, ^ref, :process, _pid, _reason} -> :ok
        after
          10_000 -> send(stub, :answer)
        end
    after
      10_000 -> :ok
    end
  end

  # Traces each call the test process makes into `bounded_request/2` or `/3`, and returns the
  # tracer. Only remote calls match, so the default deadline that `/2` passes on to `/3` inside
  # `HTTPPolicy` adds no message. A process that traces itself gets no trace messages, so a
  # supervised tracer forwards each one to the test; `deliver_traces/1` waits for them.
  defp trace_bounded_request do
    Code.ensure_loaded!(Cinder.HTTPPolicy)
    test = self()
    tracer = start_supervised!({Task, fn -> forward_to(test) end}, id: make_ref())

    for arity <- [2, 3] do
      mfa = {Cinder.HTTPPolicy, :bounded_request, arity}
      assert 1 == :erlang.trace_pattern(mfa, true, [])
      on_exit(fn -> :erlang.trace_pattern(mfa, false, []) end)
    end

    assert 1 == :erlang.trace(test, true, [:call, {:tracer, tracer}])
    tracer
  end

  defp forward_to(test) do
    receive do
      message -> send(test, message)
    end

    forward_to(test)
  end

  # Returns once every trace message of the calls made so far sits in the test's mailbox:
  # `trace_delivered/1` waits until the tracer has them, and the tracer forwards the sync message
  # after them.
  defp deliver_traces(tracer) do
    ref = :erlang.trace_delivered(self())
    assert_receive {:trace_delivered, _pid, ^ref}, 5_000
    send(tracer, {:traces_forwarded, ref})
    assert_receive {:traces_forwarded, ^ref}, 5_000
  end

  test "a search ends at the receive_timeout the configured req_options set" do
    req_options = Application.get_env(:cinder, Prowlarr)[:req_options]

    Cinder.ConfigCase.put_config(Prowlarr,
      req_options: Keyword.put(req_options, :receive_timeout, 200)
    )

    conductor = start_supervised!({Task, &answer_unless_killed/0})

    # The stub answers only on the conductor's signal, so no answer races the deadline.
    Req.Test.stub(Cinder.ProwlarrStub, fn conn ->
      send(conductor, {:stub, self()})

      receive do
        :answer -> Req.Test.json(conn, [])
      end
    end)

    started = System.monotonic_time(:millisecond)
    assert {:error, :request_timeout} = Prowlarr.search("tt0000001")
    # A loaded runner can wake the caller well past the deadline (ci.md "Wall-clock tests").
    assert System.monotonic_time(:millisecond) - started < 5_200
  end

  test "every search's total deadline is its 90 s receive_timeout, and health/0 keeps the default" do
    Req.Test.stub(Cinder.ProwlarrStub, fn conn ->
      case conn.request_path do
        "/api/v1/health" -> Plug.Conn.send_resp(conn, 200, "")
        "/api/v1/search" -> Req.Test.json(conn, [])
      end
    end)

    tracer = trace_bounded_request()

    searches = [
      {"search/1", fn -> Prowlarr.search("tt0000001") end, 1},
      {"search_tv/3 with a TVDB id", fn -> Prowlarr.search_tv(81_189, "Show", 1) end, 2},
      {"search_tv/3 without a TVDB id", fn -> Prowlarr.search_tv(nil, "Show", 1) end, 1},
      {"search_movie_query/2", fn -> Prowlarr.search_movie_query("Film", []) end, 1},
      {"search_tv_query/2", fn -> Prowlarr.search_tv_query("Show", []) end, 1},
      {"search_book/3", fn -> Prowlarr.search_book("Author", "Title", []) end, 1},
      {"search_book_query/2", fn -> Prowlarr.search_book_query("Title", []) end, 1},
      {"search_audiobook/3", fn -> Prowlarr.search_audiobook("Author", "Title", []) end, 1},
      {"search_audiobook_query/2", fn -> Prowlarr.search_audiobook_query("Title", []) end, 1}
    ]

    for {name, search, requests} <- searches do
      assert search.() == {:ok, []}, name
      deliver_traces(tracer)

      for _request <- 1..requests do
        assert_received {:trace, _pid, :call,
                         {Cinder.HTTPPolicy, :bounded_request, [request, _max_bytes, 90_000]}},
                        name

        assert Req.Request.get_option(request, :receive_timeout) == 90_000, name
      end

      refute_received {:trace, _pid, :call, _call}, name
    end

    assert :ok = Prowlarr.health()
    deliver_traces(tracer)

    assert_received {:trace, _pid, :call,
                     {Cinder.HTTPPolicy, :bounded_request, [_request, _max_bytes]}}

    refute_received {:trace, _pid, :call, _call}
  end
end
