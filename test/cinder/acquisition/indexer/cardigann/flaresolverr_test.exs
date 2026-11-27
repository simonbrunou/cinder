defmodule Cinder.Acquisition.Indexer.Cardigann.FlareSolverrTest do
  # The pure rules of the FlareSolverr step (#1682): Prowlarr's challenge detection
  # (`CloudFlareDetectionService.cs`, `b0b5774`) and the deadline split.
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.Indexer.Cardigann.FlareSolverr

  defp response(status, headers, body),
    do: %Req.Response{
      status: status,
      headers: Map.new(headers, fn {k, v} -> {k, [v]} end),
      body: body
    }

  describe "challenge?/1" do
    test "each title, error code 1020 and the DDoS-Guard title in another case, on a 403 or 503" do
      for status <- [403, 503],
          server <- ["cloudflare", "Cloudflare-Nginx", "DDOS-GUARD"],
          body <- [
            "<html><title>Just a moment...</title></html>",
            "<title>Access denied</title>",
            "<title>Attention Required! | Cloudflare</title>",
            "  error code: 1020\n",
            "<TITLE>ddos-guard</TITLE>",
            "<title>DDoS-Guard</title>"
          ] do
        assert FlareSolverr.challenge?(response(status, [{"server", server}], body)),
               "#{status} #{server} #{inspect(body)}"
      end
    end

    test "the Vary rule: Accept-Encoding,User-Agent, no Content-Encoding, ddos in the body" do
      vary = [{"server", "ddos-guard"}, {"vary", "Accept-Encoding,User-Agent"}]
      assert FlareSolverr.challenge?(response(200, vary, "checking your browser: DDoS"))
      assert FlareSolverr.challenge?(response(403, vary, "anti-ddos"))

      # Each part of the rule is needed.
      refute FlareSolverr.challenge?(response(200, vary, "no such word"))

      refute FlareSolverr.challenge?(response(200, [{"content-encoding", "gzip"} | vary], "ddos"))

      refute FlareSolverr.challenge?(
               response(200, [{"server", "ddos-guard"}, {"vary", "Accept-Encoding"}], "ddos")
             )
    end

    test "a title with no matching Server header, a 200 with a title, and other bodies are not" do
      title = "<title>Just a moment...</title>"
      refute FlareSolverr.challenge?(response(403, [], title))
      refute FlareSolverr.challenge?(response(403, [{"server", "nginx"}], title))
      # The Server value is matched whole, as Prowlarr does.
      refute FlareSolverr.challenge?(response(403, [{"server", "cloudflare-x"}], title))
      refute FlareSolverr.challenge?(response(200, [{"server", "cloudflare"}], title))
      refute FlareSolverr.challenge?(response(404, [{"server", "cloudflare"}], title))
      refute FlareSolverr.challenge?(response(403, [{"server", "cloudflare"}], ""))

      refute FlareSolverr.challenge?(
               response(503, [{"server", "cloudflare"}], "error code: 1021")
             )

      # The three Cloudflare titles are matched with case, as Prowlarr does.
      refute FlareSolverr.challenge?(
               response(403, [{"server", "cloudflare"}], "<title>just a moment...</title>")
             )
    end

    test "a gzip body is read inflated" do
      body = :zlib.gzip("<title>Just a moment...</title>")

      assert FlareSolverr.challenge?(
               response(403, [{"server", "cloudflare"}, {"content-encoding", "gzip"}], body)
             )
    end
  end

  describe "max_timeout_ms/1" do
    test "the budget is 60 s at most and maxTimeout leaves FlareSolverr's call 5 s" do
      assert FlareSolverr.budget_ms() == 60_000
      assert FlareSolverr.margin_ms() == 5_000
      # 20 s left in the seam call at the solve.
      assert FlareSolverr.max_timeout_ms(20_000) == 15_000
      # 90 s left: the 60 s budget less the margin.
      assert FlareSolverr.max_timeout_ms(60_000) == 55_000
      # A few ms spent before the solve round up to the whole second.
      assert FlareSolverr.max_timeout_ms(19_993) == 15_000
      # No time for a solve.
      assert FlareSolverr.max_timeout_ms(5_000) == nil
      assert FlareSolverr.max_timeout_ms(0) == nil
    end
  end
end
