defmodule Cinder.Download.Client.DownloadCheck do
  @moduledoc """
  Checks a download link's answer (`Cinder.Download.Client.Fetch.answer/3`) before any download
  client sees it (#1658). `Fetch.bytes/3`, the Prowlarr source's `fetch_download/3`, runs it on
  every fetch, and Native's Newznab and Torznab fetch (`Cinder.Acquisition.Indexer.Newznab.Grab`)
  runs `check_classified/2`, the same check with the parser's class beside it. A client receives `{:ok, bytes}` of a recognised file, `{:magnet, link}` or
  `{:error, reason}`, and no reason carries a URL, a header or a body. A magnet and a fetch error
  pass through unchanged.

  ## The check, in order

  1. A body that starts with the gzip bytes `1f 8b` is inflated, every member of it, under the
     fetch's `max_bytes`: one that grows past it is `{:error, :response_too_large}`, the fetch's
     own refusal of a raw body that size. Bytes after the last member that open no other member
     are dropped. A body with a member that does not inflate stays as it came.
  2. A 200 answer whose body is an NZB or a torrent is the file. An NZB is a document whose root
     element is `nzb`, read by `Cinder.Acquisition.Indexer.Newznab.XML.root/1` as far as that
     start tag, on a Latin-1 reading of the body, so an NZB that declares ISO-8859-1 or holds a
     byte that is not UTF-8 is still one. A UTF-8 byte order mark and the XML declaration are
     skipped first, and then, after any comments, one document type declaration when it names
     the `nzb` root, the NZB 1.0 or 1.1 public identifier and an `http(s)` system literal, and
     nothing else: the form every NZB Cinder grabbed in production carries. Any other document
     type declaration, an internal subset included, and any `<!ENTITY` is refused there, so the
     body is no NZB. A torrent is a body `Cinder.Download.Torrent.infohash/1` reads.
  3. A login sign from the link's source origin is `:indexer_auth_failed`: a redirect on that
     origin whose target path ends in `/login` (`Fetch` stops there and sets `:login_redirect`),
     or an HTML page on a 2xx, 401 or 403 answer with an `<input` tag whose bytes up to the first
     `>` set `type` to `password`, outside every comment. A comment runs from any `<!--`, one in
     a script string included, to the next `-->` or the end of the body.
  4. Every other answer is read by `Cinder.Acquisition.Indexer.NewznabAnswer.classify/4` and
     sorted below, the first row that matches winning. "Trusted" means every hop stayed on the
     source origin (`Fetch`'s `:trusted`); `tag` is the fetch's `error_tag`. The status reads
     before the body: a 401 or a 429 is sorted by its status, and a 404 or a 410 keeps its status
     whatever its body says. A body over the parser's 4 MiB reaches it as none, so only its status
     sorts it: a trusted 429 that large is a limit even when it says the indexer is disabled.

  | Answer | Trusted | From another host |
  |---|---|---|
  | HTTP 401, or Newznab error 100 to 102 or 910 | `:indexer_auth_failed` | `:bad_download_file` on a 200, else `{tag, status}` |
  | HTTP 429 whose description starts "Indexer is disabled till" | `:indexer_disabled` | `{tag, status}` |
  | HTTP 429, or error 500 or 501 whose description holds "limit" | `{:indexer_limit, until}` | `{tag, status}` |
  | Error 900, or 500 or 501 without "limit", on a 200 | `{:indexer_error, code}` | `{tag, 200}` |
  | Any other Newznab error on a 200 | `:bad_download_file` | `:bad_download_file` |
  | An HTML page on a 200 | `:challenge_page` | `:challenge_page` |
  | Anything else on a 200 | `:bad_download_file` | `:bad_download_file` |
  | Any other status | `{tag, status}` | `{tag, status}` |

  `until` is `NewznabAnswer.limit_until/2` of the wait the answer stated, so the limit ends 1 min
  to 24 h after the check. The check counts a wait from the `:now` option, a `DateTime`, and
  from the wall clock without one. An indexer sign from another host never reads as the
  indexer's own, so a redirect target cannot fail or limit a healthy indexer.
  `Cinder.Download.GrabFailure` says what `Cinder.Download` does with each reason.
  """

  alias Cinder.Acquisition.Indexer
  alias Cinder.Acquisition.Indexer.Newznab.XML
  alias Cinder.Acquisition.Indexer.NewznabAnswer
  alias Cinder.Download.Client.Fetch
  alias Cinder.Download.Torrent

  @capped_codes [900, 500, 501]
  # A regex that backtracks over a body of several MiB raises `SystemLimitError` once it reaches
  # PCRE's match limit. So each regex below reads one tag or, as `@html_start`, the body's first
  # 512 bytes, but `@password_type`, which searches the whole text and repeats only blank space:
  # the size-cap test runs it on 20 MiB of blank space after `type=`.
  #
  # The NZB 1.0 or 1.1 public identifier and an http(s) system literal, each in either quote, in
  # a declaration read to its first `>`.
  @public_id ~S{(["'])-//newzBin//DTD NZB 1\.[01]//EN\1}
  @system ~S{(?:"https?://[^"<>\[\]\s]*"|'https?://[^'<>\[\]\s]*')}
  @nzb_doctype Regex.compile!("\\A<!DOCTYPE\\s+nzb\\s+PUBLIC\\s+#{@public_id}\\s+#{@system}\\s*>")
  # `<input` in each of its 32 mixes of upper and lower case.
  @input_tags (for mask <- 0..31 do
                 for {byte, bit} <- Enum.with_index(~c"input"), into: "<" do
                   if Bitwise.band(mask, Bitwise.bsl(1, bit)) == 0,
                     do: <<byte>>,
                     else: <<byte - 32>>
                 end
               end)
  # The bytes a regex `\w` matches.
  @word_bytes Enum.concat([?a..?z, ?A..?Z, ?0..?9, [?_]])
  # A `type` attribute set to `password`.
  @password_type ~r/\stype\s*=\s*["']?password\b/i
  # The bytes a regex `\s` matches.
  @space ~c"\t\n\v\f\r "
  # A body that opens as HTML, after a UTF-8 byte order mark and blank space.
  @html_start ~r/\A(?:\xEF\xBB\xBF)?\s*<(?:!doctype\s+html|html|head|body)\b/i

  @doc "Checks `result`, an answer of `Fetch.answer/3`, for a client; see the moduledoc."
  @spec check({:ok, Fetch.answer()} | {:magnet, String.t()} | {:error, term()}, keyword()) ::
          {:ok, binary()} | {:magnet, String.t()} | {:error, term()}
  def check(result, opts), do: result |> check_classified(opts) |> elem(0)

  @doc """
  `check/2`'s answer, beside the class `NewznabAnswer.classify/4` gave the answer the check
  sorted, its stated wait included, or nil when the check read none: a magnet, a fetch error, a
  body that inflates past `max_bytes`, a recognised file, a login sign, or an answer the parser
  reads as an RSS document. The class is the parser's own, whatever host sent the answer.
  `Cinder.Acquisition.Indexer.Newznab` reads a disabled-till wait from it for Native's backoff
  state (#1659).
  """
  @spec check_classified(
          {:ok, Fetch.answer()} | {:magnet, String.t()} | {:error, term()},
          keyword()
        ) ::
          {{:ok, binary()} | {:magnet, String.t()} | {:error, term()},
           NewznabAnswer.class() | nil}
  def check_classified({:ok, answer}, opts) do
    case inflate(answer.body, Keyword.fetch!(opts, :max_bytes)) do
      {:ok, body} ->
        answer = %{answer | body: body}

        if answer.status == 200 and file?(body) do
          {{:ok, body}, nil}
        else
          now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
          {reason, class} = sort(answer, Keyword.fetch!(opts, :error_tag), now)
          {{:error, reason}, class}
        end

      too_large ->
        {too_large, nil}
    end
  end

  def check_classified(magnet_or_error, _opts), do: {magnet_or_error, nil}

  # --- gzip ---

  @doc """
  `body` as the check's step 1 reads it: every gzip member inflated under `max_bytes`, past
  which it is `{:error, :response_too_large}`, and any other body as it came. A Cardigann grab
  reads a link's first byte from it (#1672).
  """
  @spec inflated(term(), pos_integer()) :: {:ok, term()} | {:error, :response_too_large}
  def inflated(body, max_bytes), do: inflate(body, max_bytes)

  defp inflate(<<0x1F, 0x8B, _rest::binary>> = body, max_bytes),
    do: members(body, [], max_bytes, body)

  defp inflate(body, _max_bytes), do: {:ok, body}

  # One member a pass (RFC 1952), each in zlib's cut mode, which stops at the member's end and
  # ignores what follows. The member's trailer, the CRC-32 and size of what it inflated, marks
  # where the next member starts. Bytes after the last member that open no other member, such as
  # a newline or zero padding, are dropped, as gunzip drops them. A member that does not inflate
  # leaves the body as it came.
  defp members(<<0x1F, 0x8B, _rest::binary>> = bytes, acc, left, raw) do
    case member(bytes, left) do
      {:ok, output} ->
        members(after_trailer(bytes, output), [acc | output], left - byte_size(output), raw)

      {:error, :response_too_large} = too_large ->
        too_large

      :error ->
        {:ok, raw}
    end
  end

  defp members(_trailing, acc, _left, _raw), do: {:ok, IO.iodata_to_binary(acc)}

  defp member(bytes, left) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, 31)
      inflated(z, :zlib.safeInflate(z, bytes), [], 0, left)
    rescue
      ErlangError -> :error
    after
      :zlib.close(z)
    end
  end

  # `:zlib.safeInflate/2` returns a bounded piece a call, so the cap is checked as the body grows.
  # `:finished` says the input is used up; `:zlib.inflateEnd/1` then raises `data_error` when the
  # stream stopped before its end. A `:continue` can carry no output, as on a long header field,
  # empty stored blocks, or a whole member with bytes after it, so it only asks for the next piece.
  defp inflated(z, {state, output}, acc, size, left) when state in [:continue, :finished] do
    size = size + IO.iodata_length(output)

    cond do
      size > left ->
        {:error, :response_too_large}

      state == :finished ->
        :ok = :zlib.inflateEnd(z)
        {:ok, IO.iodata_to_binary([acc | output])}

      true ->
        inflated(z, :zlib.safeInflate(z, []), [acc | output], size, left)
    end
  end

  defp inflated(_z, _need_dictionary, _acc, _size, _left), do: :error

  # The bytes after the member's 8-byte trailer when they open the next member: one search, after
  # the 10-byte header, for the trailer followed by `1f 8b`. A trailer alone can match early, as
  # the 8 zero bytes of an empty member's do one byte into them. With no such match the member is
  # the last, and what follows it is dropped.
  defp after_trailer(bytes, output) do
    next = <<:erlang.crc32(output)::little-32, byte_size(output)::little-32, 0x1F, 0x8B>>

    case :binary.match(bytes, next, scope: {10, byte_size(bytes) - 10}) do
      {at, 10} -> binary_part(bytes, at + 8, byte_size(bytes) - at - 8)
      :nomatch -> ""
    end
  end

  # --- the file ---

  defp file?(body) when is_binary(body),
    do: nzb?(body) or match?({:ok, _}, Torrent.infohash(body))

  defp file?(_body), do: false

  defp nzb?(body) do
    rest =
      body
      |> String.replace_prefix("\xEF\xBB\xBF", "")
      |> drop_xml_declaration()
      |> drop_nzb_doctype()

    case rest |> :unicode.characters_to_binary(:latin1, :utf8) |> XML.root() do
      {:ok, name} -> name == "nzb" or String.ends_with?(name, ":nzb")
      {:error, :bad_response} -> false
    end
  end

  # After blank space, `<?xml`, a blank, and every byte to the first `>`, which follows a `?`.
  # A body with no such declaration comes back whole.
  defp drop_xml_declaration(body) do
    rest = skip_space(body)

    with <<"<?xml", blank, _tail::binary>> when blank in @space <- rest,
         {close, 1} when close > 6 <- :binary.match(rest, ">"),
         ?? <- :binary.at(rest, close - 1) do
      binary_part(rest, close + 1, byte_size(rest) - close - 1)
    else
      _no_declaration -> body
    end
  end

  # Comments and blank space, then one declaration `@nzb_doctype` reads whole, all of which go.
  # A body with no such declaration after them comes back whole, its comments kept.
  defp drop_nzb_doctype(body) do
    rest = skip_comments(body)

    with <<"<!DOCTYPE", _tail::binary>> <- rest,
         {close, 1} <- :binary.match(rest, ">"),
         true <- Regex.match?(@nzb_doctype, binary_part(rest, 0, close + 1)) do
      binary_part(rest, close + 1, byte_size(rest) - close - 1)
    else
      _no_declaration -> body
    end
  end

  # Drops blank space and each closed comment before the first other byte.
  defp skip_comments(body) do
    rest = skip_space(body)

    with <<"<!--", _tail::binary>> <- rest,
         close when is_integer(close) <- match_end(rest, "-->", 4) do
      skip_comments(binary_part(rest, close, byte_size(rest) - close))
    else
      _no_closed_comment -> rest
    end
  end

  # Where the first `pattern` at or after byte `from` ends, or nil.
  defp match_end(body, pattern, from) do
    case :binary.match(body, pattern, scope: {from, byte_size(body) - from}) do
      {at, length} -> at + length
      :nomatch -> nil
    end
  end

  defp skip_space(<<byte, rest::binary>>) when byte in @space, do: skip_space(rest)
  defp skip_space(body), do: body

  # --- every other answer ---

  # The reason, and the class the parser gave the answer (nil for a login sign or an RSS read).
  defp sort(answer, tag, now) do
    if login?(answer) do
      {:indexer_auth_failed, nil}
    else
      classified = classify(answer, now)
      {outcome(classified, answer, tag, now), class_of(classified)}
    end
  end

  defp class_of({:error, class}), do: class
  defp class_of({:ok, _items}), do: nil

  defp login?(%{trusted: true, login_redirect: true}), do: true

  defp login?(%{trusted: true, status: status} = answer)
       when status in 200..299 or status in [401, 403],
       do: html?(answer) and password_input?(answer.body)

  defp login?(_answer), do: false

  # The answer parser refuses a body over its own 4 MiB as `:too_large` before it reads the
  # status, so such a body reaches it as none and the status still sorts the answer.
  defp classify(%{status: status, headers: headers, body: body}, now) do
    body =
      if is_binary(body) and byte_size(body) > Indexer.max_response_bytes(), do: nil, else: body

    NewznabAnswer.classify(status, headers, body, now)
  end

  defp outcome({:error, {:rejected_credentials, _by}}, %{trusted: true}, _tag, _now),
    do: :indexer_auth_failed

  defp outcome({:error, {:rejected_credentials, _by}}, %{status: 200}, _tag, _now),
    do: :bad_download_file

  defp outcome({:error, {:limit, wait}}, %{trusted: true}, _tag, now),
    do: {:indexer_limit, NewznabAnswer.limit_until(wait, now)}

  defp outcome({:error, {:disabled_till, _wait}}, %{trusted: true}, _tag, _now),
    do: :indexer_disabled

  defp outcome({:error, {kind, _wait}}, %{status: status}, tag, _now)
       when kind in [:limit, :disabled_till],
       do: {tag, status}

  defp outcome({:error, {kind, code}}, %{status: 200} = answer, tag, _now)
       when kind in [:indexer_error, :query_error] do
    cond do
      code not in @capped_codes -> :bad_download_file
      answer.trusted -> {:indexer_error, code}
      true -> {tag, 200}
    end
  end

  defp outcome(_class, %{status: 200} = answer, _tag, _now),
    do: if(html?(answer), do: :challenge_page, else: :bad_download_file)

  defp outcome(_class, %{status: status}, tag, _now), do: {tag, status}

  defp html?(%{headers: headers, body: body}) do
    content_type = headers |> Map.get("content-type", []) |> Enum.join(",") |> String.downcase()

    String.starts_with?(content_type, ["text/html", "application/xhtml+xml"]) or
      html_body?(body)
  end

  defp html_body?(body) when is_binary(body),
    do: Regex.match?(@html_start, binary_part(body, 0, min(byte_size(body), 512)))

  defp html_body?(_body), do: false

  # A password input is a `@password_type` hit inside an input tag: after an `<input` and before
  # the next `>`. A text with no hit reads no tag.
  defp password_input?(body) when is_binary(body) do
    text = body |> outside_comments(0, []) |> IO.iodata_to_binary()
    in_input_tag?(text, :binary.compile_pattern(@input_tags), 0, next_hit(text, 0))
  end

  defp password_input?(_body), do: false

  # The start of the first `@password_type` hit at or after byte `from`, or nil.
  defp next_hit(text, from) do
    case Regex.run(@password_type, text, offset: from, return: :index) do
      [{at, _length}] -> at
      nil -> nil
    end
  end

  # The bytes outside every comment, which runs from `<!--` to the next `-->` or the end.
  defp outside_comments(body, from, kept) do
    case :binary.match(body, "<!--", scope: {from, byte_size(body) - from}) do
      {open, 4} -> after_comment(body, open, [kept | binary_part(body, from, open - from)])
      :nomatch -> [kept | binary_part(body, from, byte_size(body) - from)]
    end
  end

  defp after_comment(body, open, kept) do
    case match_end(body, "-->", open + 4) do
      nil -> kept
      close -> outside_comments(body, close, kept)
    end
  end

  # Walks `text` from byte `from`, outside any tag, `hit` holding the first hit at or after it. It
  # finds the next `<input`, and a hit before that is outside every input tag, so the next hit is
  # searched from the tag. Then it finds the tag's first `>`: a hit before it, or a tag with no
  # `>`, is a password input. Each search starts where the same search last ended, and only the
  # next hit is kept, so the walk reads the text once in each search and holds no list.
  defp in_input_tag?(_text, _inputs, _from, nil), do: false

  defp in_input_tag?(text, inputs, from, hit) do
    with at when is_integer(at) <- next_input(text, inputs, from),
         hit when is_integer(hit) <- if(hit > at, do: hit, else: next_hit(text, at)) do
      case :binary.match(text, ">", scope: {at, byte_size(text) - at}) do
        {close, 1} when close < hit -> in_input_tag?(text, inputs, close + 1, hit)
        _hit_inside -> true
      end
    else
      nil -> false
    end
  end

  # The first `<input` at or after `from` that no letter, digit or `_` follows, which would name
  # another tag.
  defp next_input(text, inputs, from) do
    case :binary.match(text, inputs, scope: {from, byte_size(text) - from}) do
      {at, 6} -> if word_byte?(text, at + 6), do: next_input(text, inputs, at + 6), else: at
      :nomatch -> nil
    end
  end

  defp word_byte?(text, at) when at < byte_size(text), do: :binary.at(text, at) in @word_bytes
  defp word_byte?(_text, _at), do: false
end
