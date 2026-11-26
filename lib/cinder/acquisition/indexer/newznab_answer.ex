defmodule Cinder.Acquisition.Indexer.NewznabAnswer do
  @moduledoc """
  Classifies one Newznab or Torznab answer (#1653): the search answers of
  `Cinder.Acquisition.Indexer.Newznab` and `Cinder.Acquisition.Indexer.Torznab`, their `t=caps`
  answers, and the download link answers `Cinder.Download.Client.DownloadCheck` sorts (#1658).
  The rules are #1619 point 1 as #1636 point 2 amends it; the first that matches gives the class:

  0. A body over 4 MiB is `:too_large`, whatever its status. `Cinder.Acquisition.Indexer.request/3`
     refuses such a body with the same tag before it reaches this module.
  1. HTTP 401: `{:rejected_credentials, {:http_status, 401}}`.
  2. HTTP 429 whose `<error>` answer (rule 6 says which element is one) has a description that
     starts with "Indexer is disabled till", Prowlarr's answer for an indexer in its failure
     backoff: `{:disabled_till, wait}`.
  3. Any other HTTP 429: `{:limit, wait}`.
  4. HTTP 410, Prowlarr's "Indexer is disabled": `{:http_status, 410}`.
  5. HTTP 404: `{:http_status, 404}`.
  6. An `<error>` answer, a root `<error>` element whose `code` reads through
     `Cinder.Acquisition.Indexer.Newznab.XML.integer/1` (a non-negative integer of at most 18
     digits), on any other status: codes 100 to 102 and 910 are
     `{:rejected_credentials, {:code, code}}`; code 500 or 501 whose description holds "limit",
     in any case, is `{:limit, wait}`; codes 200 to 203 and 300 are `{:query_error, code}`; any
     other code, 900 included, is
     `{:indexer_error, code}`. In a search answer `{:query_error, code}` fails that request only,
     and the adapter still sends the search's other requests; in a caps answer it fails the caps
     fetch, so the indexer is not searched. An `<error>` element below the root, or one whose
     `code` does not read as such an integer, is no `<error>` answer.
  7. A 2xx answer whose body reads as the kind asked for: a success. `classify/4` reads an `rss`
     root holding a `channel` and answers `{:ok, items}`, the channel's `item` elements in order,
     none included. `classify_caps/4` reads a `caps` root and answers `{:ok, element}`.
  8. Anything else: `:bad_response` for a 2xx answer (a body that does not parse, an HTML page,
     another root), else `{:http_status, status}`.

  Every body is read through `Cinder.Acquisition.Indexer.Newznab.XML`, which refuses a document
  type declaration.

  ## The stated wait

  `wait` is a `DateTime` or nil, never the header or the description text: the `Retry-After`
  header's first value as whole seconds (digits only) added to `now`, or as an HTTP date in one
  of RFC 9110's three forms; else the N of "Retry in N minute" (any case, plural or not) in the
  `<error>` answer's description, added to `now`; else nil. The IMF-fixdate form reads through
  `Req.Utils.parse_http_date/1`, which refuses a day name that does not match the date; the
  obsolete RFC 850 and asctime forms read here, a two-digit year more than 50 years ahead being
  the century before. A wait longer than 366 days reads as 366 days, so a huge number gives a
  date every reader can store. `limit_until/2` ends a limit from its wait: the default and the
  clamp are its own (#1654), and Native's backoff state and report read the limit through it.

  `reason/1` maps a class to the reason the report carries: `{:rejected_credentials, by}` is
  `:rejected_credentials`, `{:disabled_till, wait}` is `{:http_status, 429}` and
  `{:query_error, code}` is `{:indexer_error, code}`; every other class is its own reason. No
  class carries a URL, a header or a body.
  """

  alias Cinder.Acquisition.Indexer
  alias Cinder.Acquisition.Indexer.Newznab.XML

  @max_wait_s 366 * 24 * 60 * 60

  # A limit's end (#1619 point 3): the stated wait, else 1 h, clamped to 1 min and 24 h.
  @default_limit_s 60 * 60
  @min_limit_s 60
  @max_limit_s 24 * 60 * 60
  # 31,622,400 s (the cap) has 8 digits and the cap in minutes 6, so 12 digits leaves room.
  @max_wait_digits 12

  @disabled_till "Indexer is disabled till"

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)
  @rfc850 ~r/\A[A-Za-z]+, (\d{2})-([A-Za-z]{3})-(\d{2}) (\d{2}):(\d{2}):(\d{2}) GMT\z/
  @asctime ~r/\A[A-Za-z]{3} ([A-Za-z]{3}) ([ \d]\d) (\d{2}):(\d{2}):(\d{2}) (\d{4})\z/

  @type wait :: DateTime.t() | nil
  @type class ::
          {:rejected_credentials, {:code | :http_status, integer()}}
          | {:disabled_till, wait()}
          | {:limit, wait()}
          | {:http_status, integer()}
          | {:query_error, integer()}
          | {:indexer_error, integer()}
          | :bad_response
          | :too_large
  @type headers :: %{optional(String.t()) => [String.t()]}

  @doc "Classifies a search answer; see the moduledoc."
  @spec classify(integer(), headers(), term(), DateTime.t()) ::
          {:ok, [XML.element()]} | {:error, class()}
  def classify(status, headers, body, now), do: ladder(status, headers, body, now, &items/1)

  @doc "Classifies a `t=caps` answer; see the moduledoc."
  @spec classify_caps(integer(), headers(), term(), DateTime.t()) ::
          {:ok, XML.element()} | {:error, class()}
  def classify_caps(status, headers, body, now),
    do: ladder(status, headers, body, now, &caps_root/1)

  @doc """
  Classifies what `Cinder.Acquisition.Indexer.request/3` answered for a search: a response as
  `classify/4` reads it, and a transport tag as it is.
  """
  @spec read({:ok, Req.Response.t()} | {:error, atom()}, DateTime.t()) ::
          {:ok, [XML.element()]} | {:error, class() | atom()}
  def read({:ok, %Req.Response{status: status, headers: headers, body: body}}, now),
    do: classify(status, headers, body, now)

  def read({:error, tag}, _now) when is_atom(tag), do: {:error, tag}

  @doc "`read/2` for a `t=caps` answer, read as `classify_caps/4` reads it."
  @spec read_caps({:ok, Req.Response.t()} | {:error, atom()}, DateTime.t()) ::
          {:ok, XML.element()} | {:error, class() | atom()}
  def read_caps({:ok, %Req.Response{status: status, headers: headers, body: body}}, now),
    do: classify_caps(status, headers, body, now)

  def read_caps({:error, tag}, _now) when is_atom(tag), do: {:error, tag}

  @doc """
  When a limit that `now` answered ends (#1654): `wait`, the time a limit class carries or a
  number of seconds after `now`, else 1 h after `now`, clamped between 1 min and 24 h after
  `now`. The answer is whole seconds. `Cinder.Download.Client.DownloadCheck` ends a grab's limit
  with it (#1658).
  """
  @spec limit_until(wait() | non_neg_integer(), DateTime.t()) :: DateTime.t()
  def limit_until(wait, %DateTime{} = now) do
    now = DateTime.truncate(now, :second)
    shortest = DateTime.add(now, @min_limit_s, :second)
    longest = DateTime.add(now, @max_limit_s, :second)

    until = wait |> limit_end(now) |> DateTime.truncate(:second)
    [until, shortest] |> Enum.max(DateTime) |> then(&Enum.min([&1, longest], DateTime))
  end

  defp limit_end(nil, now), do: DateTime.add(now, @default_limit_s, :second)
  defp limit_end(seconds, now) when is_integer(seconds), do: DateTime.add(now, seconds, :second)
  defp limit_end(%DateTime{} = until, _now), do: until

  @doc "The report's failure reason for a class or a transport tag; see the moduledoc."
  @spec reason(class() | atom()) :: atom() | tuple()
  def reason({:rejected_credentials, _by}), do: :rejected_credentials
  def reason({:disabled_till, _wait}), do: {:http_status, 429}
  def reason({:query_error, code}), do: {:indexer_error, code}
  def reason(class), do: class

  # --- the ladder ---

  defp ladder(status, headers, body, now, success) do
    if is_binary(body) and byte_size(body) > Indexer.max_response_bytes(),
      do: {:error, :too_large},
      else: read_ladder(status, headers, body, now, success)
  end

  defp read_ladder(status, headers, body, now, success) do
    document = document(body)

    case status_class(status, document, headers, now) ||
           body_class(status, document, headers, now, success) do
      {:success, value} -> {:ok, value}
      class -> {:error, class}
    end
  end

  defp document(body) when is_binary(body) do
    case XML.parse(body) do
      {:ok, element} -> element
      {:error, :bad_response} -> nil
    end
  end

  defp document(_body), do: nil

  defp status_class(401, _document, _headers, _now),
    do: {:rejected_credentials, {:http_status, 401}}

  defp status_class(429, document, headers, now) do
    description = with {_code, text} <- error_element(document), do: text

    if is_binary(description) and String.starts_with?(description, @disabled_till),
      do: {:disabled_till, wait(headers, description, now)},
      else: {:limit, wait(headers, description, now)}
  end

  defp status_class(status, _document, _headers, _now) when status in [410, 404],
    do: {:http_status, status}

  defp status_class(_status, _document, _headers, _now), do: nil

  defp body_class(status, document, headers, now, success) do
    case error_element(document) do
      {code, description} -> error_class(code, description, headers, now)
      nil -> success_class(status, document, success)
    end
  end

  defp success_class(status, document, success) when status in 200..299 do
    case success.(document) do
      {:ok, value} -> {:success, value}
      :error -> :bad_response
    end
  end

  defp success_class(status, _document, _success), do: {:http_status, status}

  defp error_class(code, _description, _headers, _now) when code in 100..102 or code == 910,
    do: {:rejected_credentials, {:code, code}}

  defp error_class(code, description, headers, now) when code in [500, 501] do
    if description != nil and String.contains?(String.downcase(description), "limit"),
      do: {:limit, wait(headers, description, now)},
      else: {:indexer_error, code}
  end

  defp error_class(code, _description, _headers, _now) when code in 200..203 or code == 300,
    do: {:query_error, code}

  defp error_class(code, _description, _headers, _now), do: {:indexer_error, code}

  # `{code, description}` of a root `<error>` element with a non-negative integer code, else nil.
  defp error_element({"error", _attributes, _children} = element) do
    case XML.integer(XML.attribute(element, "code")) do
      nil -> nil
      code -> {code, XML.attribute(element, "description")}
    end
  end

  defp error_element(_document), do: nil

  # --- the success readers ---

  defp items({"rss", _attributes, _children} = rss) do
    case XML.child(rss, "channel") do
      nil -> :error
      channel -> {:ok, for({"item", _, _} = item <- XML.elements(channel), do: item)}
    end
  end

  defp items(_document), do: :error

  defp caps_root({"caps", _attributes, _children} = caps), do: {:ok, caps}
  defp caps_root(_document), do: :error

  # --- the stated wait ---

  defp wait(headers, description, now),
    do: retry_after(headers, now) || retry_in(description, now)

  defp retry_after(headers, now) do
    case Map.get(headers, "retry-after", []) do
      [value | _rest] when is_binary(value) -> retry_after_value(String.trim(value), now)
      _none -> nil
    end
  end

  defp retry_after_value(value, now) do
    if value =~ ~r/\A\d+\z/ do
      after_seconds(now, wait_number(value))
    else
      case http_date(value, now) do
        %DateTime{} = date -> capped(date, now)
        nil -> nil
      end
    end
  end

  defp retry_in(description, now) when is_binary(description) do
    case Regex.run(~r/retry in (\d+) minute/i, description) do
      [_match, minutes] -> after_seconds(now, wait_number(minutes) * 60)
      nil -> nil
    end
  end

  defp retry_in(_description, _now), do: nil

  # A run of more digits than any wait under the cap needs reads as the cap, so no digit run is
  # converted whole: past the BEAM's integer limit `String.to_integer/1` raises.
  defp wait_number(digits) when byte_size(digits) > @max_wait_digits, do: @max_wait_s
  defp wait_number(digits), do: String.to_integer(digits)

  defp after_seconds(now, seconds), do: DateTime.add(now, min(seconds, @max_wait_s), :second)

  # RFC 9110 section 5.6.7: the IMF-fixdate (`Req.Utils.parse_http_date/1`), else the obsolete
  # RFC 850 and asctime forms, which a recipient must read too.
  defp http_date(value, now) do
    case Req.Utils.parse_http_date(value) do
      {:ok, %DateTime{} = date} -> date
      _invalid -> obsolete_http_date(value, now)
    end
  end

  defp obsolete_http_date(value, now) do
    cond do
      fields = Regex.run(@rfc850, value, capture: :all_but_first) ->
        [day, month, year, hour, minute, second] = fields
        utc(two_digit_year(year, now), month, day, {hour, minute, second})

      fields = Regex.run(@asctime, value, capture: :all_but_first) ->
        [month, day, hour, minute, second, year] = fields
        utc(String.to_integer(year), month, String.trim(day), {hour, minute, second})

      true ->
        nil
    end
  end

  # A two-digit year more than 50 years ahead of `now` is the century before (RFC 9110).
  defp two_digit_year(digits, now) do
    year = div(now.year, 100) * 100 + String.to_integer(digits)
    if year > now.year + 50, do: year - 100, else: year
  end

  defp utc(year, month_name, day, {hour, minute, second}) do
    with month when is_integer(month) <- Enum.find_index(@months, &(&1 == month_name)),
         {:ok, date} <- Date.new(year, month + 1, String.to_integer(day)),
         {:ok, time} <- Time.new(int(hour), int(minute), int(second)) do
      DateTime.new!(date, time, "Etc/UTC")
    else
      _invalid -> nil
    end
  end

  defp int(digits), do: String.to_integer(digits)

  defp capped(date, now) do
    cap = DateTime.add(now, @max_wait_s, :second)
    if DateTime.compare(date, cap) == :gt, do: cap, else: date
  end
end
