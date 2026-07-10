defmodule Cinder.Subtitles.Translator.LibreTranslateTest do
  use ExUnit.Case, async: true

  alias Cinder.Subtitles.Translator.LibreTranslate

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
end
