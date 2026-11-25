defmodule Cinder.Indexers.Definitions.Source.GitHubTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Cinder.Indexers.Definitions.Source.GitHub
  alias Cinder.Test.{GitAdvertisement, RequestDeadlines}

  import GitAdvertisement, only: [pkt: 1]

  @commit "56b20b19c18fee53869fca2bca72ba59101da2f9"
  @other "0123456789abcdef0123456789abcdef01234567"
  @info_refs_path "/Prowlarr/Indexers.git/info/refs"
  @zip_path "/Prowlarr/Indexers/zip/56b20b19c18fee53869fca2bca72ba59101da2f9"

  @head "56b20b19c18fee53869fca2bca72ba59101da2f9 HEAD\0multi_ack thin-pack side-band " <>
          "side-band-64k ofs-delta shallow deepen-since deepen-not deepen-relative no-progress " <>
          "include-tag multi_ack_detailed allow-tip-sha1-in-want allow-reachable-sha1-in-want " <>
          "no-done symref=HEAD:refs/heads/master filter object-format=sha1 agent=git/github-1a2b\n"

  # Shaped like GitHub's answer: the service line, a flush, `HEAD` with capabilities after a NUL,
  # then one line per ref and a closing flush.
  defp advertisement(ref_lines), do: GitAdvertisement.advertisement([@head | ref_lines])

  defp real_shaped do
    advertisement([
      "#{@other} refs/heads/develop\n",
      "#{@commit} refs/heads/master\n",
      "#{@other} refs/pull/1/head\n"
    ])
  end

  # Answers every request with `fun.(conn)` and reports it to the test process.
  defp stub(fun) do
    test_pid = self()

    Req.Test.stub(Cinder.DefinitionsSourceStub, fn conn ->
      send(test_pid, {:request, conn.host, conn.request_path, conn.query_string})
      fun.(conn)
    end)
  end

  defp answer(conn, status, body, content_type \\ "application/x-git-upload-pack-advertisement") do
    conn
    |> Plug.Conn.put_resp_content_type(content_type, nil)
    |> Plug.Conn.send_resp(status, body)
  end

  describe "master_commit/0" do
    test "reads master's commit from a body shaped like GitHub's, from the fixed URL" do
      stub(&answer(&1, 200, real_shaped()))

      assert {:ok, @commit} = GitHub.master_commit()
      assert_received {:request, "github.com", @info_refs_path, "service=git-upload-pack"}
    end

    test "reads master's commit from a line with capabilities after a NUL" do
      body =
        GitAdvertisement.advertisement([
          "#{@commit} refs/heads/master\0multi_ack thin-pack agent=git/github-1a2b3c\n",
          "#{@other} refs/heads/develop\n"
        ])

      stub(&answer(&1, 200, body))

      assert {:ok, @commit} = GitHub.master_commit()
    end

    test "reads a master line with no line feed" do
      stub(&answer(&1, 200, GitAdvertisement.advertisement(["#{@commit} refs/heads/master"])))

      assert {:ok, @commit} = GitHub.master_commit()
    end

    test "gives :no_master_ref when no line names exactly refs/heads/master by a 40-hex id" do
      upper = String.upcase(@commit)
      short = String.slice(@commit, 0, 39)

      for lines <- [
            ["#{@commit} refs/heads/master-old\n"],
            ["#{@commit} refs/heads/mastery\n"],
            ["#{@commit} refs/heads/develop\n"],
            ["#{short} refs/heads/master\n"],
            ["#{@commit}0 refs/heads/master\n"],
            ["#{upper} refs/heads/master\n"],
            ["#{@commit}  refs/heads/master\n"],
            ["#{@commit} refs/heads/master\n\n"],
            ["#{@commit} refs/heads/master x\n"],
            ["#{@commit} refs/heads/master\n", "#{@other} refs/heads/master\n"],
            []
          ] do
        stub(&answer(&1, 200, advertisement(lines)))

        assert {lines, {:error, :no_master_ref}} == {lines, GitHub.master_commit()}
      end
    end

    test "gives :no_master_ref on a body that is not the service line, a flush, refs, a flush" do
      service = pkt("# service=git-upload-pack\n")
      line = pkt("#{@commit} refs/heads/master\n")
      other = pkt("#{@other} refs/heads/develop\n")

      # The shape every case below breaks one part of.
      stub(&answer(&1, 200, service <> "0000" <> line <> "0000"))
      assert {:ok, @commit} = GitHub.master_commit()

      for body <- [
            # No closing flush.
            service <> "0000" <> line,
            # No service line, or another service.
            "0000" <> line <> "0000",
            pkt("# service=git-receive-pack\n") <> "0000" <> line <> "0000",
            # No flush after the service line.
            service <> line <> "0000",
            # A flush between refs, and bytes after the closing flush.
            service <> "0000" <> other <> "0000" <> line <> "0000",
            service <> "0000" <> line <> "0000" <> "0000",
            service <> "0000" <> line <> "0000" <> other,
            # A length past the end of the body.
            service <> "0000" <> "00ff" <> String.slice(line, 4..-1//1) <> "0000",
            # A length that is not four lowercase hex digits.
            service <> "0000" <> "003F" <> String.slice(line, 4..-1//1) <> "0000",
            service <> "0000" <> "+03f" <> String.slice(line, 4..-1//1) <> "0000",
            # A length under 4 that is not a flush.
            service <> "0000" <> "0003" <> line <> "0000",
            # A body cut inside a length.
            service <> "0000" <> line <> "00",
            # Lines not framed as pkt-lines at all.
            "#{@commit} refs/heads/master\n"
          ] do
        stub(&answer(&1, 200, body))

        assert {body, {:error, :no_master_ref}} == {body, GitHub.master_commit()}
      end
    end

    test "reads a pkt-line of 65,520 bytes, and refuses one of 65,521" do
      longest = pkt(:binary.copy("#", 65_516))
      assert byte_size(longest) == 65_520
      too_long = "fff1" <> :binary.copy("#", 65_517)

      stub(&answer(&1, 200, advertisement(["#{@commit} refs/heads/master\n"]) |> insert(longest)))
      assert {:ok, @commit} = GitHub.master_commit()

      stub(
        &answer(&1, 200, advertisement(["#{@commit} refs/heads/master\n"]) |> insert(too_long))
      )

      assert {:error, :no_master_ref} = GitHub.master_commit()
    end
  end

  describe "download/1" do
    test "downloads the commit's zip from the fixed codeload URL" do
      stub(&answer(&1, 200, "zip bytes", "application/zip"))

      assert {:ok, "zip bytes"} = GitHub.download(@commit)
      assert_received {:request, "codeload.github.com", @zip_path, ""}
    end

    test "refuses a commit that is not 40 lowercase hex characters before any request" do
      stub(&answer(&1, 200, "zip bytes", "application/zip"))

      for commit <- [
            String.upcase(@commit),
            String.slice(@commit, 0, 39),
            @commit <> "0",
            "../../evil",
            "master",
            ""
          ] do
        assert {commit, {:error, :invalid_commit}} == {commit, GitHub.download(commit)}
      end

      refute_received {:request, _host, _path, _query}

      assert {:ok, _zip} = GitHub.download(@other)
      assert_received {:request, "codeload.github.com", "/Prowlarr/Indexers/zip/" <> @other, ""}
    end
  end

  describe "errors" do
    test "a 301 from either URL gives {:http_status, 301} and no second request" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "https://github.com/elsewhere")
        |> answer(301, "")
      end)

      assert {:error, {:http_status, 301}} = GitHub.master_commit()
      assert_received {:request, "github.com", @info_refs_path, _query}
      refute_received {:request, _host, _path, _query}

      assert {:error, {:http_status, 301}} = GitHub.download(@commit)
      assert_received {:request, "codeload.github.com", @zip_path, _query}
      refute_received {:request, _host, _path, _query}
    end

    test "a 404 gives {:http_status, 404}" do
      stub(&answer(&1, 404, "Not Found", "text/plain"))

      assert {:error, {:http_status, 404}} = GitHub.master_commit()
      assert {:error, {:http_status, 404}} = GitHub.download(@commit)
    end

    test "another 2xx than 200 gives its status" do
      stub(&answer(&1, 204, ""))

      assert {:error, {:http_status, 204}} = GitHub.master_commit()
    end

    test "an info/refs body of 1,048,576 bytes reads, and one byte more is :too_large" do
      at_cap = pad_to(real_shaped(), 1_048_576)
      assert byte_size(at_cap) == 1_048_576

      stub(&answer(&1, 200, at_cap))
      assert {:ok, @commit} = GitHub.master_commit()

      stub(&answer(&1, 200, at_cap <> "0"))
      assert {:error, :too_large} = GitHub.master_commit()
    end

    test "a zip of 16,777,216 bytes downloads, and one byte more is :too_large" do
      at_cap = :binary.copy("z", 16_777_216)

      stub(&answer(&1, 200, at_cap, "application/zip"))
      assert {:ok, ^at_cap} = GitHub.download(@commit)

      stub(&answer(&1, 200, at_cap <> "z", "application/zip"))
      assert {:error, :too_large} = GitHub.download(@commit)
    end

    test "info/refs runs under a 30 s deadline and the zip under a 120 s one" do
      stub(&answer(&1, 200, real_shaped()))
      {_result, deadlines} = RequestDeadlines.capture(&GitHub.master_commit/0)
      assert deadlines == [{@info_refs_path, 30_000}]

      stub(&answer(&1, 200, "zip bytes", "application/zip"))
      {_result, deadlines} = RequestDeadlines.capture(fn -> GitHub.download(@commit) end)
      assert deadlines == [{@zip_path, 120_000}]
    end

    test "a receive timeout gives :timeout and another transport error :transport" do
      stub(&Req.Test.transport_error(&1, :timeout))
      assert {:error, :timeout} = GitHub.master_commit()
      assert {:error, :timeout} = GitHub.download(@commit)

      stub(&Req.Test.transport_error(&1, :econnrefused))
      assert {:error, :transport} = GitHub.master_commit()
      assert {:error, :transport} = GitHub.download(@commit)
    end

    test "a body labelled JSON reaches the parsers as its raw bytes, whatever the status" do
      for body <- [~s({"refs": "#{@commit} refs/heads/master"}), ~s("zip"), "{not json"] do
        stub(&answer(&1, 200, body, "application/json"))

        assert {body, {:error, :no_master_ref}} == {body, GitHub.master_commit()}
        assert {body, {:ok, body}} == {body, GitHub.download(@commit)}
      end

      stub(&answer(&1, 200, real_shaped(), "application/json"))
      assert {:ok, @commit} = GitHub.master_commit()

      stub(&answer(&1, 301, "{not json", "application/json"))
      assert {:error, {:http_status, 301}} = GitHub.master_commit()
      assert {:error, {:http_status, 301}} = GitHub.download(@commit)
    end

    test "no error and no logged line holds the request URL or a body byte" do
      # The test env logs at :warning, and `with_log/2`'s level does not lower that, so these
      # modules log every level for this test: an info line holding the URL would show here.
      modules = [GitHub, Cinder.HTTPPolicy, Req.Steps, Req.Request]
      Logger.put_module_level(modules, :debug)
      on_exit(fn -> Logger.delete_module_level(modules) end)
      marker = "MARKER-1f3a9c"

      answers = [
        &answer(&1, 500, marker, "text/plain"),
        &answer(&1, 404, marker, "text/plain"),
        &answer(&1, 301, marker, "text/plain"),
        &answer(&1, 200, ~s({"x": "#{marker}"}), "application/json"),
        &answer(&1, 200, "{#{marker}", "application/json"),
        &answer(&1, 200, advertisement(["#{marker} refs/heads/master\n"])),
        &answer(&1, 200, :binary.copy(marker, 100_000)),
        &Req.Test.transport_error(&1, :econnrefused)
      ]

      for fun <- answers do
        stub(fun)

        {results, log} =
          with_log([level: :debug], fn ->
            [GitHub.master_commit(), GitHub.download(@commit)]
          end)

        assert {:error, _} = hd(results)
        errors = for {:error, _} = error <- results, do: error
        text = inspect(errors, limit: :infinity, printable_limit: :infinity) <> log

        for secret <- [marker, "github.com", "codeload", "Prowlarr", "info/refs"] do
          refute text =~ secret, "#{inspect(secret)} in #{text}"
        end
      end
    end
  end

  # Puts `packet` just before the closing flush of `body`.
  defp insert(body, packet), do: binary_part(body, 0, byte_size(body) - 4) <> packet <> "0000"

  # Pads an advertisement to exactly `size` bytes with comment lines before its closing flush.
  defp pad_to(body, size), do: insert(body, padding(size - byte_size(body)))

  defp padding(0), do: ""

  defp padding(bytes) do
    length = min(bytes, 65_520)
    # A last line under 4 bytes cannot be framed, so the line before it leaves 4.
    length = if (bytes - length) in 1..3, do: length - 4, else: length
    pkt(:binary.copy("#", length - 4)) <> padding(bytes - length)
  end
end
