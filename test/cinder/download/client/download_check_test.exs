defmodule Cinder.Download.Client.DownloadCheckTest do
  # The body check every download-link fetch runs before a client sees the bytes (#1658), through
  # `Fetch.bytes/3`, the Prowlarr source's `fetch_download/3`. The answer comes from a `Req.Test`
  # stub, and the trust in the answer's host from `Fetch` itself: the release's source origin is
  # `@origin`, and `other.example` is another host.
  use ExUnit.Case, async: true

  alias Cinder.Download.Client.DownloadCheck
  alias Cinder.Download.Client.Fetch
  alias Cinder.NzbFixture

  @origin "https://indexer.example"
  @link "https://indexer.example/getnzb/1?id=9"
  @stub Cinder.DownloadCheckStub
  @max_bytes 64 * 1024

  defp fetch(link \\ @link, opts \\ []) do
    Fetch.bytes(
      link,
      @origin,
      Keyword.merge(
        [
          max_bytes: @max_bytes,
          error_tag: :nzb_fetch_status,
          plug: {Req.Test, @stub},
          resolver: fn _host -> {:ok, [{93, 184, 216, 34}]} end
        ],
        opts
      )
    )
  end

  # Answers each path the test names; any other path fails the test. A hop off the source origin
  # reaches its validated address, so the stub sees that address as the host, not the name.
  defp serve(routes) do
    Req.Test.stub(@stub, fn conn ->
      case Map.fetch(routes, conn.request_path) do
        {:ok, respond} -> respond.(conn)
        :error -> flunk("unexpected request #{conn.host}#{conn.request_path}")
      end
    end)
  end

  defp answer(status, body, headers \\ []) do
    fn conn ->
      headers
      |> Enum.reduce(conn, fn {name, value}, conn ->
        Plug.Conn.put_resp_header(conn, name, value)
      end)
      |> Plug.Conn.send_resp(status, body)
    end
  end

  defp redirect_to(location), do: answer(302, "", [{"location", location}])

  defp error_body(code, description),
    do:
      ~s(<?xml version="1.0" encoding="UTF-8"?>\n<error code="#{code}" description="#{description}"/>)

  defp from_source(status, body, headers \\ []),
    do: serve(%{"/getnzb/1" => answer(status, body, headers)})

  # The same answer from another host, reached through the source's cross-origin redirect.
  defp from_other_host(status, body, headers \\ []) do
    serve(%{
      "/getnzb/1" => redirect_to("https://other.example/file"),
      "/file" => answer(status, body, headers)
    })
  end

  @torrent "d4:infod6:lengthi1e4:name1:a12:piece lengthi16384e6:pieces20:" <>
             :binary.copy("p", 20) <> "ee"

  describe "a recognised file" do
    test "an NZB with the NZB 1.1 document type declaration reaches the client as it came" do
      from_source(200, NzbFixture.minimal())
      assert fetch() == {:ok, NzbFixture.minimal()}
    end

    test "a torrent reaches the client as it came" do
      from_source(200, @torrent)
      assert fetch() == {:ok, @torrent}
    end

    test "an NZB from another host is recognised as from the source" do
      from_other_host(200, NzbFixture.minimal())
      assert fetch() == {:ok, NzbFixture.minimal()}
    end

    test "an NZB that declares ISO-8859-1 and holds a Latin-1 byte is recognised" do
      body =
        ~s(<?xml version="1.0" encoding="iso-8859-1" ?>\n) <>
          String.replace(NzbFixture.document(), "WEB-DL", "Caf\xe9")

      from_source(200, body)
      assert fetch() == {:ok, body}
    end

    # The root's start tag is as far as the check reads, so the Latin-1 byte sits before it.
    test "an NZB with a Latin-1 byte before its root is recognised" do
      body = NzbFixture.prolog() <> "<!-- G\xe9n\xe9r\xe9 -->\n" <> NzbFixture.document()
      from_source(200, body)
      assert fetch() == {:ok, body}
    end

    test "an NZB whose root carries a namespace prefix is recognised" do
      body =
        NzbFixture.prolog() <>
          ~s(<n:nzb xmlns:n="http://www.newzbin.com/DTD/2003/nzb"><n:file/></n:nzb>)

      from_source(200, body)
      assert fetch() == {:ok, body}
    end

    test "an NZB on a 203 keeps its status" do
      from_source(203, NzbFixture.minimal())
      assert fetch() == {:error, {:nzb_fetch_status, 203}}
    end

    test "an NZB after a UTF-8 byte order mark, or with no prolog at all, is recognised" do
      for body <- ["\xEF\xBB\xBF" <> NzbFixture.minimal(), NzbFixture.document()] do
        from_source(200, body)
        assert {body, fetch()} == {body, {:ok, body}}
      end
    end

    test "a gzip-compressed NZB reaches the client decompressed" do
      from_source(200, :zlib.gzip(NzbFixture.minimal()))
      assert fetch() == {:ok, NzbFixture.minimal()}
    end

    # RFC 1952: a gzip file is a series of members, each inflated after the one before.
    test "a gzip body of two members reaches the client as both, under one cap" do
      {first, second} = String.split_at(NzbFixture.minimal(), 40)
      from_source(200, :zlib.gzip(first) <> :zlib.gzip(second))
      assert fetch() == {:ok, NzbFixture.minimal()}

      half = div(@max_bytes, 2) + 1
      {first, second} = String.split_at(NzbFixture.padded(2 * half), half)
      from_source(200, :zlib.gzip(first) <> :zlib.gzip(second))
      assert fetch() == {:error, :response_too_large}
    end

    # gunzip drops bytes after the last member that open no other member, and so does the check.
    test "a gzip body with a newline or zero padding after its last member keeps its members" do
      nzb = NzbFixture.minimal()
      {first, second} = String.split_at(nzb, 40)

      for {name, body} <- [
            {"newline", :zlib.gzip(nzb) <> "\n"},
            {"zero padding", :zlib.gzip(nzb) <> <<0, 0, 0, 0>>},
            {"two members and a newline", :zlib.gzip(first) <> :zlib.gzip(second) <> "\n"}
          ] do
        from_source(200, body)
        assert {name, fetch()} == {name, {:ok, nzb}}
      end
    end

    # The first member holds the root start tag, so it alone would read as an NZB.
    test "a gzip body whose second member is cut short is no file" do
      nzb = NzbFixture.minimal()
      {at, _length} = :binary.match(nzb, "<file")
      {first, second} = String.split_at(nzb, at)
      cut = binary_part(:zlib.gzip(second), 0, 12)
      from_source(200, :zlib.gzip(first) <> cut)
      assert fetch() == {:error, :bad_download_file}
    end

    test "a gzip body that inflates to exactly the cap is kept, one byte more is refused" do
      exact = NzbFixture.padded(@max_bytes)
      from_source(200, :zlib.gzip(exact))
      assert fetch() == {:ok, exact}

      from_source(200, :zlib.gzip(NzbFixture.padded(@max_bytes + 1)))
      assert fetch() == {:error, :response_too_large}
    end

    test "a gzip body whose stream is corrupt or cut short is no file" do
      gzip = :zlib.gzip(NzbFixture.minimal())
      <<head::binary-size(20), _rest::binary>> = gzip

      for body <- [head <> "not deflate", binary_part(gzip, 0, byte_size(gzip) - 30)] do
        from_source(200, body)
        assert fetch() == {:error, :bad_download_file}
      end
    end

    test "an NZB 1.0 declaration in single quotes, after a comment, is recognised" do
      body =
        ~s(<?xml version="1.0"?>\n<!-- made by an indexer -->\n) <>
          ~s(<!DOCTYPE nzb PUBLIC '-//newzBin//DTD NZB 1.0//EN' 'https://h.example/nzb.dtd'>) <>
          NzbFixture.document()

      from_source(200, body)
      assert fetch() == {:ok, body}
    end

    test "a 401 or a 200 labelled JSON that does not decode is still sorted by its status" do
      from_source(401, "{not json", [{"content-type", "application/json"}])
      assert fetch() == {:error, :indexer_auth_failed}

      from_source(200, NzbFixture.minimal(), [{"content-type", "application/json"}])
      assert fetch() == {:ok, NzbFixture.minimal()}
    end
  end

  # On #1658 a member followed by a newline or a second member was refused when it ended 1 to 10
  # bytes past a multiple of 8,192 from 16,384 on: zlib answered `:continue` with no output once
  # before `:finished`. The check is called itself, on NZBs whose first segment is base64 text.
  #
  # The first test builds each member by hand at every size from 15 bytes below each multiple in
  # `@bases` to 40 above it: an extra field (RFC 1952 FEXTRA) in its header is padded to that
  # size, so the deflate stream and the bytes after it move one byte at a time. Base64 lengths
  # alone skip some sizes, as one more input byte can add two compressed bytes. The other tests
  # use `:zlib.gzip/1`'s own header, over the lengths in `@lengths`: a window around 16,384, which
  # the window test pins, and two lengths outside it.
  describe "gzip bodies across compressed sizes" do
    # Each multiple, with a base64 length whose deflate stream leaves room for the header's padding.
    @bases [{16_384, 21_090}, {24_576, 31_900}, {32_768, 42_700}, {40_960, 53_490}]
    @lengths Enum.to_list(21_090..21_240) ++ [20_000, 60_000]
    @second_segment ~s(<segment bytes="1" number="3">)

    defp base64_text(seed, length) do
      :rand.seed(:exsss, seed)
      :rand.bytes(div(length * 3, 4) + 3) |> Base.encode64() |> binary_part(0, length)
    end

    defp base64_nzb(length, second \\ "") do
      first = ~s(<segment bytes="1" number="2">#{base64_text({16, 58, 1}, length)}</segment>)
      NzbFixture.document(first <> second)
    end

    # `data`'s raw deflate stream and its trailer, the parts of a member after its header.
    defp deflated(data) do
      z = :zlib.open()
      :ok = :zlib.deflateInit(z, :default, :deflated, -15, 8, :default)
      stream = IO.iodata_to_binary(:zlib.deflate(z, data, :finish))
      :zlib.close(z)
      stream <> <<:erlang.crc32(data)::little-32, byte_size(data)::little-32>>
    end

    # A member of exactly `size` bytes: the 10-byte header with FEXTRA set, the extra field's
    # 2-byte length and its padding, then `deflated`.
    defp member(deflated, size) do
      pad = size - 12 - byte_size(deflated)
      if pad < 0, do: raise(ArgumentError, "no member of #{size} bytes holds this stream")
      <<0x1F, 0x8B, 8, 0x04, 0::32, 0, 255, pad::little-16>> <> :binary.copy("x", pad) <> deflated
    end

    defp check(body) do
      answer = %{status: 200, headers: %{}, body: body, url: URI.parse(@link), trusted: true}

      DownloadCheck.check({:ok, answer},
        max_bytes: 20 * 1024 * 1024,
        error_tag: :nzb_fetch_status
      )
    end

    # Each failure is listed as its member size and body, so one run shows every size that fails.
    # In "two large members" the first member ends before a second segment of 21,000 base64 bytes.
    test "a member of each size around four multiples of 8,192 gives the NZB alone, before a newline or another member, or after an empty member" do
      second = @second_segment <> base64_text({3, 2, 1}, 21_000) <> "</segment>"

      failures =
        for {multiple, length} <- @bases,
            nzb = base64_nzb(length),
            {head, tail} = String.split_at(nzb, byte_size(nzb) - 40),
            large = base64_nzb(length, second),
            {at, _length} = :binary.match(large, @second_segment),
            {large_head, large_tail} = String.split_at(large, at),
            {whole, head, large_head} = {deflated(nzb), deflated(head), deflated(large_head)},
            size <- (multiple - 15)..(multiple + 40),
            {name, body, want} <- [
              {"lone", member(whole, size), nzb},
              {"newline", member(whole, size) <> "\n", nzb},
              {"two members", member(head, size) <> :zlib.gzip(tail), nzb},
              {"two large members", member(large_head, size) <> :zlib.gzip(large_tail), large},
              {"empty member first", :zlib.gzip("") <> member(whole, size), nzb}
            ],
            check(body) != {:ok, want},
            do: {size, name}

      assert failures == []
    end

    test "the window of lengths puts the compressed NZB on both sides of 16,384 bytes" do
      sizes = Enum.map(21_090..21_240, &byte_size(:zlib.gzip(base64_nzb(&1))))
      assert Enum.min(sizes) < 16_384 - 15 and Enum.max(sizes) > 16_384 + 40
    end

    test "a gzip member of each length gives the NZB, alone, with a newline or before another" do
      failures =
        for length <- @lengths,
            nzb = base64_nzb(length),
            gzip = :zlib.gzip(nzb),
            {head, tail} = String.split_at(nzb, byte_size(nzb) - 40),
            {name, body} <- [
              {"lone", gzip},
              {"newline", gzip <> "\n"},
              {"two members", :zlib.gzip(head) <> :zlib.gzip(tail)},
              {"empty member first", :zlib.gzip("") <> gzip}
            ],
            check(body) != {:ok, nzb},
            do: {length, name}

      assert failures == []
    end

    # A cut member comes back raw, which is no file, not as the part that inflated, which holds
    # the root start tag and would read as an NZB.
    test "a member cut short in its stream or its trailer is no file" do
      failures =
        for length <- @lengths,
            gzip = :zlib.gzip(base64_nzb(length)),
            cut <- [30, 4],
            body = binary_part(gzip, 0, byte_size(gzip) - cut),
            check(body) != {:error, :bad_download_file},
            do: {length, cut}

      assert failures == []
    end

    # zlib answers two `:continue`s in a row with no output on each of the first three members,
    # whose long stretches inflate to nothing.
    test "a member with a long header field, or empty stored blocks, gives the NZB" do
      nzb = base64_nzb(21_140)
      stream = deflated(nzb)
      header = fn flags, field -> <<0x1F, 0x8B, 8, flags, 0::32, 0, 255>> <> field end
      empty_stored_blocks = :binary.copy(<<0, 0, 0, 0xFF, 0xFF>>, 4_000)

      for {name, body} <- [
            {"comment", header.(0x10, :binary.copy("c", 20_000) <> <<0>>) <> stream},
            {"extra field", member(stream, byte_size(stream) + 12 + 20_000)},
            {"empty stored blocks", header.(0, empty_stored_blocks) <> stream},
            {"newlines after", :zlib.gzip(nzb) <> :binary.copy("\n", 20_000)}
          ] do
        assert {name, check(body)} == {name, {:ok, nzb}}
      end
    end
  end

  # A regex that backtracked over a body of 5 MiB or more raised `SystemLimitError` here.
  describe "bodies near the 20 MiB cap that a tag or comment spans" do
    test "each gives its answer" do
      fill = :binary.copy("a", 20 * 1024 * 1024 - 1024)
      fill_space = :binary.copy(" ", 20 * 1024 * 1024 - 1024)
      page = "<!DOCTYPE html><html><body>"

      doctype =
        ~s(<!DOCTYPE nzb PUBLIC "-//newzBin//DTD NZB 1.1//EN" "http://www.newzbin.com/DTD/nzb/nzb-1.1.dtd">)

      nzb_after = fn prolog -> prolog <> doctype <> NzbFixture.document() end

      for {name, body, want} <- [
            {"an input tag left open", page <> "<input " <> fill, {:error, :challenge_page}},
            {"input tags left open", page <> :binary.copy("<input a ", 2_000_000),
             {:error, :challenge_page}},
            {"a comment left open", page <> "<!--" <> fill, {:error, :challenge_page}},
            {"closed input tags, then a password input",
             page <> :binary.copy("<INPUT >", 2_500_000) <> ~s(<input type="password">),
             {:error, :indexer_auth_failed}},
            {"type set to blank space", page <> ~s(<input type=) <> fill_space <> ">",
             {:error, :challenge_page}},
            {"a comment, then a password input",
             page <> "<!--" <> fill <> ~s(--><input type="password">),
             {:error, :indexer_auth_failed}},
            {"an XML declaration left open", "<?xml " <> fill, {:error, :bad_download_file}},
            {"a comment left open before the NZB", "<!--" <> fill, {:error, :bad_download_file}},
            {"a comment before the declaration", nzb_after.("<!--" <> fill <> "-->"), :nzb},
            {"blank space before the declaration", nzb_after.(:binary.copy(" ", 20_000_000)),
             :nzb}
          ] do
        want = if want == :nzb, do: {:ok, body}, else: want
        assert {name, check(body)} == {name, want}
      end
    end
  end

  describe "an NZB's XML declaration" do
    test "blank space before it is skipped, and one without a blank after <?xml or a ? before > is no file" do
      for {prolog, want} <- [
            {~s(  <?xml version="1.0"?>), :nzb},
            {~s(<?xmlfoo?>), :bad_download_file},
            {~s(<?xml version="1.0">), :bad_download_file}
          ] do
        body = prolog <> NzbFixture.document()
        from_source(200, body)
        want = if want == :nzb, do: {:ok, body}, else: {:error, want}
        assert {prolog, fetch()} == {prolog, want}
      end
    end
  end

  describe "an NZB that declares more than the NZB 1.1 identifiers" do
    test "an internal subset, even behind a system identifier holding >, is no file" do
      for prolog <- [
            ~s(<!DOCTYPE nzb [<!ENTITY boom "boom">]>\n),
            ~s(<!DOCTYPE nzb SYSTEM "a>b" [<!ATTLIST nzb x CDATA "y">]>\n),
            ~s(<!DOCTYPE nzb PUBLIC "-//newzBin//DTD NZB 1.1//EN" "nzb.dtd" [<!ENTITY x "y">]>\n),
            ~s(<!DOCTYPE nzb SYSTEM "file:///etc/passwd">\n),
            ~s(<!DOCTYPE nzb SYSTEM "https://h.example/nzb-1.1.dtd">\n),
            ~s(<!DOCTYPE nzb PUBLIC "-//Other//DTD X//EN" "https://h.example/x.dtd">\n),
            ~s(<!DOCTYPE nzb PUBLIC "-//newzBin//DTD NZB 1.1//EN" "http://h/x.dtd" [ ]>\n)
          ] do
        body = ~s(<?xml version="1.0"?>\n) <> prolog <> NzbFixture.document()
        from_source(200, body)
        assert {prolog, fetch()} == {prolog, {:error, :bad_download_file}}
      end
    end

    test "another NZB version or a system literal that is not http(s) is no file" do
      for prolog <- [
            ~s(<!DOCTYPE nzb PUBLIC "-//newzBin//DTD NZB 2.0//EN" "http://h.example/nzb.dtd">\n),
            ~s(<!DOCTYPE nzb PUBLIC "-//newzBin//DTD NZB 1.1//EN" "file:///etc/passwd">\n),
            ~s(<!DOCTYPE nzb PUBLIC "-//newzBin//DTD NZB 1.1//EN" "ftp://h.example/nzb.dtd">\n)
          ] do
        body = ~s(<?xml version="1.0"?>\n) <> prolog <> NzbFixture.document()
        from_source(200, body)
        assert {prolog, fetch()} == {prolog, {:error, :bad_download_file}}
      end
    end

    test "an entity declaration or a second document type declaration is no file" do
      for body <- [
            NzbFixture.prolog() <> ~s(<!ENTITY x "y">) <> NzbFixture.document(),
            NzbFixture.prolog() <> ~s(<!DOCTYPE nzb>) <> NzbFixture.document(),
            String.replace(NzbFixture.minimal(), "<head>", ~s(<head><!ENTITY x "y">))
          ] do
        from_source(200, body)
        assert {body, fetch()} == {body, {:error, :bad_download_file}}
      end
    end

    # With no XML declaration before it, the document type declaration opens the body.
    test "a SYSTEM-only declaration that opens the body is no file" do
      body =
        ~s(<!DOCTYPE nzb SYSTEM "https://indexer.example/nzb.dtd">\n) <> NzbFixture.document()

      from_source(200, body)
      assert fetch() == {:error, :bad_download_file}
    end

    test "a document type declaration for another root, or a root other than nzb, is no file" do
      for body <- [
            ~s(<!DOCTYPE rss SYSTEM "rss.dtd">) <> NzbFixture.document(),
            NzbFixture.prolog() <> "<rss><channel/></rss>"
          ] do
        from_source(200, body)
        assert {body, fetch()} == {body, {:error, :bad_download_file}}
      end
    end
  end

  describe "rejected credentials" do
    test "a Newznab error 100 from the source origin is :indexer_auth_failed" do
      from_source(200, error_body(100, "Incorrect user credentials"))
      assert fetch() == {:error, :indexer_auth_failed}
    end

    test "errors 101, 102 and 910 from the source origin are :indexer_auth_failed" do
      for code <- [101, 102, 910] do
        from_source(200, error_body(code, "Account suspended"))
        assert {code, fetch()} == {code, {:error, :indexer_auth_failed}}
      end
    end

    test "the same error from another host is no file" do
      from_other_host(200, error_body(100, "Incorrect user credentials"))
      assert fetch() == {:error, :bad_download_file}
    end

    test "a cross-origin redirect that comes back to the source origin stays another host's" do
      serve(%{
        "/getnzb/1" => redirect_to("https://other.example/bounce"),
        "/bounce" => redirect_to("https://indexer.example/back"),
        "/back" => answer(200, error_body(100, "Incorrect user credentials"))
      })

      assert fetch() == {:error, :bad_download_file}
    end

    test "HTTP 401 from the source origin is :indexer_auth_failed, from another host a status" do
      from_source(401, "")
      assert fetch() == {:error, :indexer_auth_failed}

      from_other_host(401, "")
      assert fetch() == {:error, {:nzb_fetch_status, 401}}
    end

    test "HTTP 401 with a body past the answer parser's 4 MiB is still :indexer_auth_failed" do
      from_source(401, :binary.copy("x", 4 * 1024 * 1024 + 1))
      assert fetch(@link, max_bytes: 5 * 1024 * 1024) == {:error, :indexer_auth_failed}
    end

    # The status reads before the body, and the answer parser reads no body past its 4 MiB, so
    # such a body on a 200 is no file.
    test "a Newznab error 100 on a 503 is :indexer_auth_failed, on a 404 or a 410 or past 4 MiB it is not" do
      body = error_body(100, "Incorrect user credentials")
      oversize = body <> :binary.copy(" ", 4 * 1024 * 1024)

      for {status, body, reason} <- [
            {503, body, :indexer_auth_failed},
            {404, body, {:nzb_fetch_status, 404}},
            {410, body, {:nzb_fetch_status, 410}},
            {503, oversize, {:nzb_fetch_status, 503}},
            {200, oversize, :bad_download_file}
          ] do
        from_source(status, body)
        result = fetch(@link, max_bytes: 5 * 1024 * 1024)
        assert {status, byte_size(body), result} == {status, byte_size(body), {:error, reason}}
      end
    end

    test "a redirect to /login on the source origin is :indexer_auth_failed, unfollowed" do
      for location <- ["/login", "https://indexer.example/account/Login?next=%2Fgetnzb"] do
        serve(%{"/getnzb/1" => redirect_to(location)})
        assert {location, fetch()} == {location, {:error, :indexer_auth_failed}}
      end
    end

    test "an HTML page with a password input from the source origin is :indexer_auth_failed" do
      page =
        ~s(<!DOCTYPE html><html><form><input name="user">) <>
          ~s(<INPUT Type='Password' name="pass"></form></html>)

      for status <- [200, 203, 403] do
        from_source(status, page)
        assert {status, fetch()} == {status, {:error, :indexer_auth_failed}}
      end
    end

    test "a password input inside an HTML comment, closed, left open or over several lines, is no login sign" do
      for comment <- [
            ~s(<!-- <input type="password"> -->),
            ~s(<!-- <input type="password">),
            ~s(<!--\n<input type="password">\n-->)
          ] do
        from_source(200, "<html><body>Try again#{comment}</body></html>")
        assert {comment, fetch()} == {comment, {:error, :challenge_page}}
      end
    end

    # A known gap: the check reads bytes, not HTML elements.
    test "a <!-- inside a script string opens a comment too, so it hides a password input after it" do
      from_source(200, ~s(<html><script>var s = "<!--";</script><input type="password"></html>))
      assert fetch() == {:error, :challenge_page}
    end

    test "a password input after a closed comment, or in a tag a comment splits, is a login sign" do
      for page <- [
            ~s(<html><!-- note --><input type="password"></html>),
            ~s(<html><input <!-- x --> type="password"></html>)
          ] do
        from_source(200, page)
        assert {page, fetch()} == {page, {:error, :indexer_auth_failed}}
      end
    end

    test "a password input is read in any case, after other tags and inputs, up to its tag's first >" do
      for {page, reason} <- [
            {~s(<html><INPUT name="u"><Input\nTYPE = 'Password'></html>), :indexer_auth_failed},
            {~s(<html><input name="u"><input value=">" type="password"></html>), :challenge_page},
            {~s(<html><inputs type="password"></html>), :challenge_page},
            {~s(<html><input type="passwords"></html>), :challenge_page},
            {~s(<html><p type="password"><input name="u"></html>), :challenge_page},
            {~s(<html><input name="u"> type="password"</html>), :challenge_page},
            {~s(<html><input name="u" type="password"), :indexer_auth_failed}
          ] do
        from_source(200, page)
        assert {page, fetch()} == {page, {:error, reason}}
      end
    end

    # `Fetch` stops at a redirect to a login path; any other answer from such a path is read as
    # its status and body say.
    test "a 304 from a /login link is its status, not a login redirect" do
      serve(%{"/login" => answer(304, "")})
      assert fetch("https://indexer.example/login") == {:error, {:nzb_fetch_status, 304}}
    end

    test "an attribute that only ends in type is no password input" do
      from_source(200, ~s(<html><input data-type="password" name="q"></html>))
      assert fetch() == {:error, :challenge_page}
    end

    test "a body that is no HTML page is no login sign, password input or not" do
      from_source(200, ~s(user notes: <input type="password">))
      assert fetch() == {:error, :bad_download_file}
    end

    # `Fetch` sets the content type aside while Req reads the answer; a header the server sends
    # under the name Fetch might use is not a content type.
    test "a header the server names x-cinder-content-type is no content type" do
      from_source(200, ~s(<form><input type="password"></form>), [
        {"x-cinder-content-type", "text/html"}
      ])

      assert fetch() == {:error, :bad_download_file}
    end

    test "a login page on another host, or the page a /login redirect there reaches, is a challenge page" do
      from_other_host(200, ~s(<html><input type="password"></html>))
      assert fetch() == {:error, :challenge_page}

      serve(%{
        "/getnzb/1" => redirect_to("https://other.example/login"),
        "/login" => answer(200, "<html>Sign in</html>")
      })

      assert fetch() == {:error, :challenge_page}
    end
  end

  describe "a limit" do
    test "HTTP 429 with Retry-After: 600 is a limit that ends 10 minutes later" do
      from_source(429, "", [{"retry-after", "600"}])
      before = DateTime.utc_now(:second)
      assert {:error, {:indexer_limit, until}} = fetch()
      assert DateTime.diff(until, before) in 600..602
    end

    test "a limit from another host keeps its status, so it is no limit of the indexer's" do
      from_other_host(429, "", [{"retry-after", "120"}])
      assert fetch() == {:error, {:nzb_fetch_status, 429}}

      from_other_host(200, error_body(500, "Request limit reached"))
      assert fetch() == {:error, {:nzb_fetch_status, 200}}
    end

    test "HTTP 429 with no stated wait ends the limit after one hour" do
      from_source(429, "")
      before = DateTime.utc_now(:second)
      assert {:error, {:indexer_limit, until}} = fetch()
      assert DateTime.diff(until, before) in 3600..3602
    end

    test "Newznab errors 500 and 501 that hold \"limit\" are limits, timed by Retry in N minutes" do
      for code <- [500, 501] do
        from_source(200, error_body(code, "Request limit reached. Retry in 5 minutes"))
        before = DateTime.utc_now(:second)
        assert {:error, {:indexer_limit, until}} = fetch()
        assert {code, DateTime.diff(until, before) in 300..302} == {code, true}
      end
    end

    test "HTTP 429 that says Indexer is disabled till is a capped failure, not a limit" do
      body =
        error_body(429, "Indexer is disabled till 11/26/2026 06:00:00 due to recent failures.")

      from_source(429, body, [{"retry-after", "600"}])
      assert fetch() == {:error, :indexer_disabled}

      from_other_host(429, body, [{"retry-after", "600"}])
      assert fetch() == {:error, {:nzb_fetch_status, 429}}
    end

    # The parser reads no body past its 4 MiB, so the status alone sorts the answer.
    test "HTTP 429 past the answer parser's 4 MiB is a limit, whatever its body says" do
      body = error_body(429, "Indexer is disabled till 11/26/2026 06:00:00")
      from_source(429, body <> :binary.copy(" ", 4 * 1024 * 1024))
      assert {:error, {:indexer_limit, _until}} = fetch(@link, max_bytes: 5 * 1024 * 1024)
    end

    test "a Newznab limit error on a 503 is a limit, on a 401, a 404, a 410 or past 4 MiB it is not" do
      body = error_body(500, "Request limit reached")

      for {status, body, reason} <- [
            {401, body, :indexer_auth_failed},
            {404, body, {:nzb_fetch_status, 404}},
            {410, body, {:nzb_fetch_status, 410}},
            {503, body <> :binary.copy(" ", 4 * 1024 * 1024), {:nzb_fetch_status, 503}}
          ] do
        from_source(status, body)
        result = fetch(@link, max_bytes: 5 * 1024 * 1024)
        assert {status, byte_size(body), result} == {status, byte_size(body), {:error, reason}}
      end

      from_source(503, body)
      assert {:error, {:indexer_limit, _until}} = fetch()
    end
  end

  describe "a capped failure" do
    test "Newznab error 900, and 500 or 501 without \"limit\", are indexer errors" do
      for code <- [900, 500, 501] do
        from_source(200, error_body(code, "Internal error"))
        assert {code, fetch()} == {code, {:error, {:indexer_error, code}}}

        from_other_host(200, error_body(code, "Internal error"))
        assert {code, fetch()} == {code, {:error, {:nzb_fetch_status, 200}}}
      end
    end

    test "an HTML page with no password input from the source origin is a challenge page" do
      from_source(200, "  <!doctype html><html><body>Checking your browser</body></html>")
      assert fetch() == {:error, :challenge_page}

      from_source(200, "<p>Just a moment</p>", [{"content-type", "text/html; charset=utf-8"}])
      assert fetch() == {:error, :challenge_page}
    end

    test "a login form on a 503 from the source origin keeps its status" do
      from_source(503, ~s(<html><input type="password"></html>))
      assert fetch() == {:error, {:nzb_fetch_status, 503}}
    end

    test "a status keeps the reason it had before the check, past 401 and 429" do
      for status <- [403, 404, 410, 500, 503] do
        from_source(status, "<html>nope</html>")
        assert {status, fetch()} == {status, {:error, {:nzb_fetch_status, status}}}
      end
    end

    test "a Newznab error on a status that is not 200 keeps that status, unless it is a sign" do
      from_source(503, error_body(300, "No such item"))
      assert fetch() == {:error, {:nzb_fetch_status, 503}}

      from_other_host(503, error_body(100, "Incorrect user credentials"))
      assert fetch() == {:error, {:nzb_fetch_status, 503}}

      for status <- [403, 503] do
        from_source(status, error_body(100, "Incorrect user credentials"))
        assert {status, fetch()} == {status, {:error, :indexer_auth_failed}}
      end
    end

    test "a 404 or a 410 from the source origin keeps its status, error 100 or not" do
      for status <- [404, 410] do
        from_source(status, error_body(100, "Incorrect user credentials"))
        assert {status, fetch()} == {status, {:error, {:nzb_fetch_status, status}}}
      end
    end
  end

  describe "anything else" do
    test "a 200 body that is neither an NZB nor a torrent is :bad_download_file" do
      for body <- ["nzb-bytes", ~s({"error":"x"}), "", error_body(300, "No such item")] do
        from_source(200, body)
        assert {body, fetch()} == {body, {:error, :bad_download_file}}
      end
    end

    test "a 200 JSON body labelled JSON is :bad_download_file" do
      from_source(200, ~s({"error":"x"}), [{"content-type", "application/json"}])
      assert fetch() == {:error, :bad_download_file}
    end

    test "a 200 body past the answer parser's 4 MiB that is no file is :bad_download_file" do
      from_source(200, :binary.copy("x", 4 * 1024 * 1024 + 1))
      assert fetch(@link, max_bytes: 5 * 1024 * 1024) == {:error, :bad_download_file}
    end
  end
end
