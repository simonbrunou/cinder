defmodule Cinder.Library.MediaServerTest do
  use ExUnit.Case, async: true

  alias Cinder.Library.MediaServer

  describe "absolute_http_url/1" do
    # RFC 3986 section 3.1: a scheme is case-insensitive. Phoenix's <.link> raises on an
    # upper-case one, so the reader writes it lower-case and leaves the rest as typed.
    test "reads an http(s) scheme in any ASCII letter case and writes it lower-case" do
      for {web_url, expected} <- [
            {"http://plex.example", "http://plex.example"},
            {"HTTP://plex.example", "http://plex.example"},
            {"Http://plex.example", "http://plex.example"},
            {"hTtP://plex.example", "http://plex.example"},
            {"https://plex.example", "https://plex.example"},
            {"HTTPS://plex.example", "https://plex.example"},
            {"Https://plex.example", "https://plex.example"},
            {"HTTPS://Plex.Example:32400/Some/Path?x=Y#Z",
             "https://Plex.Example:32400/Some/Path?x=Y#Z"},
            {"HTTP://jellyfin.example/", "http://jellyfin.example/"}
          ] do
        assert MediaServer.absolute_http_url(web_url) == expected, "for #{inspect(web_url)}"
      end
    end

    test "refuses a value that is not an absolute http(s) URL, in any letter case, without raising" do
      for bad <- [
            "http://",
            "HTTP://",
            "https://",
            "HTTPS://",
            "Https://",
            "plex.example.com",
            "Plex.Example.com",
            "/relative",
            "javascript:alert(1)",
            "JAVASCRIPT:alert(1)",
            "ftp://x.test",
            "FTP://x.test",
            "http:/x.test",
            "HTTP:x.test",
            "",
            # Bytes that are not valid UTF-8 where the scheme would be.
            <<0xFF, 0xFE, "TTP://x.test">>,
            <<"HTTPS:/", 0xC3, "x.test">>,
            # A two-byte character straddling the 7th and 8th bytes.
            "https:/é.test",
            nil,
            42
          ] do
        assert MediaServer.absolute_http_url(bad) == nil, "for #{inspect(bad)}"
      end
    end
  end
end
