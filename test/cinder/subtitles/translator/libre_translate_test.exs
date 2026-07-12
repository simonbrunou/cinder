defmodule Cinder.Subtitles.Translator.LibreTranslateTest do
  use ExUnit.Case, async: true

  alias Cinder.Subtitles.Translator.LibreTranslate

  defp put_batch_size(size) do
    saved = Application.get_env(:cinder, LibreTranslate)
    Application.put_env(:cinder, LibreTranslate, Keyword.put(saved, :batch_size, size))
    on_exit(fn -> Application.put_env(:cinder, LibreTranslate, saved) end)
  end

  test "translate/2 posts ordered cue bodies with autodetection and HTML preservation" do
    Req.Test.stub(Cinder.LibreTranslateStub, fn conn ->
      assert conn.request_path == "/translate"
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert Jason.decode!(body) == %{
               "q" => ["<i>Hello</i>", "Goodbye"],
               "source" => "auto",
               "target" => "fr",
               "format" => "html"
             }

      Req.Test.json(conn, %{"translatedText" => ["<i>Bonjour</i>", "Au revoir"]})
    end)

    assert {:ok, ["<i>Bonjour</i>", "Au revoir"]} =
             LibreTranslate.translate(["<i>Hello</i>", "Goodbye"], "fr")
  end

  test "translate/2 splits large cue lists into ordered batches and concatenates in order" do
    parent = self()
    put_batch_size(2)

    Req.Test.stub(Cinder.LibreTranslateStub, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"q" => q} = Jason.decode!(body)
      send(parent, {:batch, q})
      Req.Test.json(conn, %{"translatedText" => Enum.map(q, &("fr:" <> &1))})
    end)

    assert {:ok, ~w(fr:a fr:b fr:c fr:d fr:e)} =
             LibreTranslate.translate(~w(a b c d e), "fr")

    # batch_size 2 → [a,b] [c,d] [e], in order, nothing more
    assert_received {:batch, ["a", "b"]}
    assert_received {:batch, ["c", "d"]}
    assert_received {:batch, ["e"]}
    refute_received {:batch, _}
  end

  test "translate/2 halts on the first failing batch and returns its error" do
    parent = self()
    put_batch_size(2)

    Req.Test.stub(Cinder.LibreTranslateStub, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"q" => q} = Jason.decode!(body)
      send(parent, {:batch, q})

      if "BOOM" in q do
        Plug.Conn.send_resp(conn, 500, "boom")
      else
        Req.Test.json(conn, %{"translatedText" => Enum.map(q, &("fr:" <> &1))})
      end
    end)

    assert {:error, {:http, 500}} = LibreTranslate.translate(~w(a b BOOM d), "fr")

    # first batch ran, the BOOM batch failed and halted, no further batch sent
    assert_received {:batch, ["a", "b"]}
    assert_received {:batch, ["BOOM", "d"]}
    refute_received {:batch, _}
  end

  test "translate/2 returns {:ok, []} for empty cues without any HTTP call" do
    parent = self()

    Req.Test.stub(Cinder.LibreTranslateStub, fn conn ->
      send(parent, :called)
      Req.Test.json(conn, %{"translatedText" => []})
    end)

    assert {:ok, []} = LibreTranslate.translate([], "fr")
    refute_received :called
  end

  test "translate/2 halts with :invalid_response when a batch returns a mismatched length" do
    parent = self()
    put_batch_size(2)

    Req.Test.stub(Cinder.LibreTranslateStub, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"q" => q} = Jason.decode!(body)
      send(parent, {:batch, q})
      # one fewer translation than requested (engine dropped/merged a cue) — the
      # equal-length guard is what protects Srt.render from a misaligned sidecar
      Req.Test.json(conn, %{"translatedText" => Enum.drop(Enum.map(q, &("fr:" <> &1)), 1)})
    end)

    assert {:error, :invalid_response} = LibreTranslate.translate(~w(a b c d), "fr")

    # the short first batch halts; the second batch is never sent
    assert_received {:batch, ["a", "b"]}
    refute_received {:batch, _}
  end

  test "translate/2 returns the HTTP status for non-200 responses" do
    Req.Test.stub(Cinder.LibreTranslateStub, fn conn ->
      Plug.Conn.send_resp(conn, 429, "too many requests")
    end)

    assert {:error, {:http, 429}} = LibreTranslate.translate(["Hello"], "fr")
  end

  test "translate/2 returns not_configured without an HTTP call" do
    saved = Application.get_env(:cinder, LibreTranslate)
    Application.put_env(:cinder, LibreTranslate, base_url: nil)
    on_exit(fn -> Application.put_env(:cinder, LibreTranslate, saved) end)

    assert {:error, :not_configured} = LibreTranslate.translate(["Hello"], "fr")
  end

  test "translate/2 does not forward JSON or API key across redirects" do
    parent = self()
    saved = Application.get_env(:cinder, LibreTranslate)
    Application.put_env(:cinder, LibreTranslate, Keyword.put(saved, :api_key, "secret-key"))
    on_exit(fn -> Application.put_env(:cinder, LibreTranslate, saved) end)

    for status <- [301, 302, 303, 307, 308] do
      Req.Test.stub(Cinder.LibreTranslateStub, fn conn ->
        if conn.host == "attacker.test" do
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(parent, {:attacker_called, body})
          Req.Test.json(conn, %{"translatedText" => ["stolen"]})
        else
          conn
          |> Plug.Conn.put_resp_header("location", "https://attacker.test/translate")
          |> Plug.Conn.send_resp(status, "")
        end
      end)

      assert {:error, {:http, ^status}} = LibreTranslate.translate(["Hello"], "fr")
      refute_received {:attacker_called, _}
    end
  end

  test "translate/2 rejects an oversized request before sending it" do
    Req.Test.stub(Cinder.LibreTranslateStub, fn _conn ->
      flunk("oversized body must not be sent")
    end)

    assert {:error, :request_too_large} =
             LibreTranslate.translate([String.duplicate("x", 8 * 1024 * 1024)], "fr")
  end

  test "translate/2 rejects an oversized JSON response" do
    Req.Test.stub(Cinder.LibreTranslateStub, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"padding":"#{String.duplicate("x", 8 * 1024 * 1024)}"}))
    end)

    assert {:error, :response_too_large} = LibreTranslate.translate(["Hello"], "fr")
  end
end
