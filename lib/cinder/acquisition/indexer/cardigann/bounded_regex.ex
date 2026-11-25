defmodule Cinder.Acquisition.Indexer.Cardigann.BoundedRegex do
  @moduledoc ~S"""
  Compiles and runs every pattern the Cardigann engine meets (#1670, part of #1610): filter
  arguments, keyword filters and the `re_replace` inside a template. A pattern comes from an
  untrusted definition (#1615, threat model "Regexes"; ADR 0005 "Consequences"), so:

  - every pattern compiles with `:unicode` and `:ucp`, so `\w` and its kin read Unicode letters
    and digits, as .NET's do. They are not the same class: PCRE's `\w` also takes every other
    number, such as `³`, which .NET's does not. A pattern that does not compile is
    `{:error, :regex_invalid}`;
  - every match runs as `:re.run/3` with an explicit `{:match_limit, match_limit()}` and
    `:report_errors`, and a limit hit is `{:error, :regex_limit}`, never `:nomatch`. A
    `(*LIMIT_MATCH=...)` at the start of a pattern can only lower that limit;
  - replacements and splits are built here from the matches `:re.run/3` returns, one call per
    match, so no `:re.replace`, `:re.split`, `Regex.replace` or `Regex.split` runs: those return
    their input unchanged on a limit hit, or ignore the limit;
  - a subject that is not UTF-8 is `{:error, :regex_subject}`, since `:re.run/3` raises on it;
  - a pattern holding `\C`, PCRE's one-byte match, is `{:error, :regex_invalid}`, as .NET
    refuses that escape: it could end a match inside a character, where `:re.run/3` raises
    with the subject in its arguments or a group holds text that is not UTF-8. The check is on
    the pattern's text, read escape by escape as PCRE reads it (`\c` takes the next character,
    so `\c\\C` holds a `\C`), and a `\C` inside `\Q...\E` or a comment is refused too.

  Every error is a closed tag: none holds the pattern, the subject or the replacement.

  The scan follows .NET's `Regex.Replace`: the next match starts where the last one ended, and
  one code point later after an empty match. `:re`'s own `:global` retries a non-empty match at
  the place an empty one matched, so `(?=a)|a` on `baac` gives four matches where .NET gives
  two. Past the Basic Multilingual Plane the two differ: .NET steps one UTF-16 unit, so an empty
  match can fall between the two halves of a character such as an emoji, where Cinder steps over
  the whole character.

  A replacement reads .NET's syntax: `$N` and `${N}` insert group N (nothing when the group took
  no part in the match), `$0` and `$&` the whole match, `$$` one `$`. A `$N` that names a group
  the pattern lacks stays literal, as does any other `$`. Each rule comes from a `dotnet fsi`
  run (.NET 8.0.427). Outside the corpus (#1612), and refused with
  `{:error, {:not_supported, ...}}` rather than read wrong: `` $` ``, `$'`, `$+` and `$_`, which
  .NET substitutes, a named `${name}`, and any pattern with a named group, since .NET numbers
  named groups after the unnamed ones where PCRE numbers them in order. A group number past
  Int32, which .NET throws on, is `{:error, :replacement_invalid}`.
  """

  # Measured on #1670 over the 35 static patterns of nyaasi.yml and torrent9.yml: field values of
  # one hand-fetched search page per site need at most 4,621 (a 1,097-byte script), a 64 KiB
  # subject (the output cap) needs 193,116. 1,000,000 is about 5 times the second.
  @match_limit 1_000_000
  @int32_max 2_147_483_647
  @run_opts [{:match_limit, @match_limit}, :report_errors, {:capture, :all, :index}]

  @type error ::
          :regex_invalid
          | :regex_limit
          | :regex_subject
          | :replacement_invalid
          | :filter_output_cap
          | {:not_supported, :named_group | :split_group | {:replacement, String.t()}}

  @doc "The `match_limit` every `:re.run/3` here runs with."
  @spec match_limit() :: pos_integer()
  def match_limit, do: @match_limit

  @doc """
  The number of capture groups in `pattern`. `:re` keeps it in the compiled pattern's second
  slot, which its docs leave opaque; the tests pin it, so an OTP that moves it goes red.
  """
  @spec group_count(String.t()) :: {:ok, non_neg_integer()} | {:error, error()}
  def group_count(pattern) do
    with {:ok, mp} <- compile(pattern), do: groups(mp)
  end

  @doc """
  The first match's group 1, as the `regexp` filter reads it: empty text when nothing matches,
  or when group 1 took no part.
  """
  @spec first_group(String.t(), String.t()) :: {:ok, String.t()} | {:error, error()}
  def first_group(pattern, subject) do
    with {:ok, mp} <- compile(pattern),
         :ok <- unnamed(mp),
         :ok <- valid_subject(subject),
         {:ok, matches} <- run(mp, subject, 0) do
      {:ok, group_text(subject, matches, 1)}
    end
  end

  @doc """
  `subject` with every match of `pattern` replaced by `replacement` in .NET syntax. Stops with
  `{:error, :filter_output_cap}` as soon as the output passes `max_bytes`.
  """
  @spec replace(String.t(), String.t(), String.t(), non_neg_integer()) ::
          {:ok, String.t()} | {:error, error()}
  def replace(pattern, subject, replacement, max_bytes)
      when is_binary(replacement) and is_integer(max_bytes) do
    with {:ok, mp} <- compile(pattern),
         :ok <- unnamed(mp),
         {:ok, count} <- groups(mp),
         {:ok, parts} <- parse_replacement(replacement, count, []),
         :ok <- valid_subject(subject),
         {:ok, matches} <- scan(mp, subject) do
      build(matches, subject, parts, max_bytes)
    end
  end

  def replace(_pattern, _subject, _replacement, _max_bytes), do: {:error, :replacement_invalid}

  @doc """
  The text between the matches of `pattern`. A pattern with a capture group is
  `{:error, {:not_supported, :split_group}}`, since .NET's `Regex.Split` adds each group's text
  to the parts.
  """
  @spec split(String.t(), String.t()) :: {:ok, [String.t()]} | {:error, error()}
  def split(pattern, subject) do
    with {:ok, mp} <- compile(pattern),
         :ok <- no_groups(mp),
         :ok <- valid_subject(subject),
         {:ok, matches} <- scan(mp, subject) do
      {last, parts} =
        Enum.reduce(matches, {0, []}, fn [{start, len} | _], {from, acc} ->
          {start + len, [binary_part(subject, from, start - from) | acc]}
        end)

      {:ok, Enum.reverse([binary_part(subject, last, byte_size(subject) - last) | parts])}
    end
  end

  defp compile(pattern) when is_binary(pattern) do
    with false <- backslash_c?(pattern),
         {:ok, mp} <- :re.compile(pattern, [:unicode, :ucp]) do
      {:ok, mp}
    else
      _invalid -> {:error, :regex_invalid}
    end
  end

  defp compile(_pattern), do: {:error, :regex_invalid}

  # An escape is skipped whole, so `\\C` is a backslash and a `C`. `\c` takes the next
  # character as a control letter, a backslash included: `\c\\C` is 0x1C and a real `\C`.
  defp backslash_c?(<<?\\, ?C, _rest::binary>>), do: true
  defp backslash_c?(<<?\\, ?c, _control, rest::binary>>), do: backslash_c?(rest)
  defp backslash_c?(<<?\\, _escaped, rest::binary>>), do: backslash_c?(rest)
  defp backslash_c?(<<_byte, rest::binary>>), do: backslash_c?(rest)
  defp backslash_c?(<<>>), do: false

  defp groups({:re_pattern, count, _, _, _}) when is_integer(count) and count >= 0,
    do: {:ok, count}

  defp groups(_mp), do: {:error, :regex_invalid}

  defp no_groups(mp) do
    case groups(mp) do
      {:ok, 0} -> :ok
      {:ok, _count} -> {:error, {:not_supported, :split_group}}
      {:error, _} = error -> error
    end
  end

  defp unnamed(mp) do
    case :re.inspect(mp, :namelist) do
      {:namelist, []} -> :ok
      {:namelist, _names} -> {:error, {:not_supported, :named_group}}
    end
  end

  defp valid_subject(subject) when is_binary(subject) do
    if String.valid?(subject), do: :ok, else: {:error, :regex_subject}
  end

  defp valid_subject(_subject), do: {:error, :regex_subject}

  defp run(mp, subject, offset) do
    case :re.run(subject, mp, [{:offset, offset} | @run_opts]) do
      {:match, groups} -> {:ok, groups}
      :nomatch -> {:ok, nil}
      {:error, _limit} -> {:error, :regex_limit}
    end
  end

  # Every match from the start, each a list of `{start, length}` per group, in .NET's order.
  defp scan(mp, subject), do: scan(mp, subject, 0, [])

  defp scan(_mp, subject, offset, acc) when offset > byte_size(subject),
    do: {:ok, Enum.reverse(acc)}

  defp scan(mp, subject, offset, acc) do
    case run(mp, subject, offset) do
      {:ok, nil} ->
        {:ok, Enum.reverse(acc)}

      {:ok, [{start, len} | _] = match} ->
        scan(mp, subject, next(subject, start, len), [match | acc])

      {:error, _} = error ->
        error
    end
  end

  defp next(subject, start, 0) when start >= byte_size(subject), do: start + 1

  defp next(subject, start, 0) do
    <<_::binary-size(^start), char::utf8, _::binary>> = subject
    start + byte_size(<<char::utf8>>)
  end

  defp next(_subject, start, len), do: start + len

  defp group_text(_subject, nil, _group), do: ""

  defp group_text(subject, match, group) do
    case Enum.at(match, group) do
      {start, len} when start >= 0 -> binary_part(subject, start, len)
      _unset_or_absent -> ""
    end
  end

  defp build(matches, subject, parts, max_bytes) do
    result =
      Enum.reduce_while(matches, {0, [], 0}, fn [{start, len} | _] = match, {from, acc, size} ->
        piece = [binary_part(subject, from, start - from) | expand(parts, subject, match)]
        add(piece, {start + len, [acc | piece], size}, max_bytes)
      end)

    with {from, acc, size} <- result,
         tail = binary_part(subject, from, byte_size(subject) - from),
         {:cont, {_from, acc, _size}} <- add(tail, {from, [acc | tail], size}, max_bytes) do
      {:ok, IO.iodata_to_binary(acc)}
    else
      {:halt, error} -> error
      {:error, _} = error -> error
    end
  end

  defp add(piece, {from, acc, size}, max_bytes) do
    size = size + IO.iodata_length(piece)

    if size > max_bytes,
      do: {:halt, {:error, :filter_output_cap}},
      else: {:cont, {from, acc, size}}
  end

  defp expand(parts, subject, match) do
    Enum.map(parts, fn
      {:text, text} -> text
      {:group, group} -> group_text(subject, match, group)
    end)
  end

  # .NET's replacement grammar, read once per call into text and group parts.
  defp parse_replacement("", _count, acc), do: {:ok, Enum.reverse(acc)}

  defp parse_replacement("$$" <> rest, count, acc),
    do: parse_replacement(rest, count, [{:text, "$"} | acc])

  defp parse_replacement("$&" <> rest, count, acc),
    do: parse_replacement(rest, count, [{:group, 0} | acc])

  defp parse_replacement(<<"$", c, _::binary>>, _count, _acc) when c in [?`, ?', ?+, ?_],
    do: {:error, {:not_supported, {:replacement, <<"$", c>>}}}

  defp parse_replacement("${" <> rest, count, acc) do
    case braced(rest) do
      {:number, n, _rest} when n > @int32_max -> {:error, :replacement_invalid}
      {:number, n, rest} when n <= count -> parse_replacement(rest, count, [{:group, n} | acc])
      :name -> {:error, {:not_supported, {:replacement, "${name}"}}}
      _literal -> parse_replacement("{" <> rest, count, [{:text, "$"} | acc])
    end
  end

  defp parse_replacement(<<"$", d, _::binary>> = text, count, acc) when d in ?0..?9 do
    "$" <> rest = text
    {digits, after_digits} = take_digits(rest, "")
    n = String.to_integer(digits)

    cond do
      n > @int32_max -> {:error, :replacement_invalid}
      n <= count -> parse_replacement(after_digits, count, [{:group, n} | acc])
      true -> parse_replacement(rest, count, [{:text, "$"} | acc])
    end
  end

  defp parse_replacement(<<char::utf8, rest::binary>>, count, acc),
    do: parse_replacement(rest, count, [{:text, <<char::utf8>>} | acc])

  defp parse_replacement(_invalid_utf8, _count, _acc), do: {:error, :replacement_invalid}

  # After `${`: a group number closed by `}`, a name closed by `}`, or anything else.
  defp braced(<<d, _::binary>> = text) when d in ?0..?9 do
    case take_digits(text, "") do
      {digits, "}" <> rest} -> {:number, String.to_integer(digits), rest}
      _unclosed -> :literal
    end
  end

  defp braced(<<c, _::binary>> = text) when c in ?a..?z or c in ?A..?Z or c == ?_ do
    {_name, rest} = take_word(text, "")
    if String.starts_with?(rest, "}"), do: :name, else: :literal
  end

  defp braced(_text), do: :literal

  defp take_digits(<<d, rest::binary>>, acc) when d in ?0..?9, do: take_digits(rest, acc <> <<d>>)
  defp take_digits(rest, acc), do: {acc, rest}

  defp take_word(<<c, rest::binary>>, acc)
       when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_,
       do: take_word(rest, acc <> <<c>>)

  defp take_word(rest, acc), do: {acc, rest}
end
