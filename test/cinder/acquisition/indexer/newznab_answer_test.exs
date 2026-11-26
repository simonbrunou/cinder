defmodule Cinder.Acquisition.Indexer.NewznabAnswerTest do
  # The answer classes of a Newznab or Torznab answer (#1653, #1619 point 1 as #1636 point 2
  # amends it), read straight through the public parser. The same cases run through each adapter
  # in `newznab_search_test.exs`, which also asserts the report reason.
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.Indexer.NewznabAnswer

  @now ~U[2026-11-26 12:00:00Z]

  defp rss(items \\ ""),
    do:
      ~s(<?xml version="1.0"?><rss version="2.0"><channel><title>t</title>#{items}</channel></rss>)

  defp error(code, description),
    do: ~s(<?xml version="1.0"?><error code="#{code}" description="#{description}"/>)

  defp classify(status, body, headers \\ %{}),
    do: NewznabAnswer.classify(status, headers, body, @now)

  describe "classify/4" do
    test "a 2xx RSS answer is a success with its items, an empty channel included" do
      assert {:ok, [{"item", [], _children}, {"item", [], _}]} =
               classify(200, rss("<item><title>a</title></item><item><title>b</title></item>"))

      assert classify(200, rss()) == {:ok, []}
      assert {:ok, [_item]} = classify(206, rss("<item/>"))
    end

    test "HTTP 401 is rejected credentials, before a limit body or any <error> element" do
      assert classify(401, "") == {:error, :rejected_credentials}
      assert classify(401, error(500, "Request limit reached")) == {:error, :rejected_credentials}
      assert classify(401, rss()) == {:error, :rejected_credentials}
    end

    test "HTTP 429 with 'Indexer is disabled till' is a failure that carries its stated wait" do
      body = error(429, "Indexer is disabled till 11/26/2026 13:00:00 due to recent failures.")

      assert classify(429, body, %{"retry-after" => ["600"]}) ==
               {:error, {:disabled_till, ~U[2026-11-26 12:10:00Z]}}

      assert classify(429, body) == {:error, {:disabled_till, nil}}
    end

    test "HTTP 429 is a limit with the wait it states" do
      assert classify(429, "", %{"retry-after" => ["120"]}) ==
               {:error, {:limit, ~U[2026-11-26 12:02:00Z]}}

      assert classify(429, "", %{"retry-after" => ["Thu, 26 Nov 2026 15:30:00 GMT"]}) ==
               {:error, {:limit, ~U[2026-11-26 15:30:00Z]}}

      assert classify(429, error(500, "Request limit reached. Retry in 7 minutes.")) ==
               {:error, {:limit, ~U[2026-11-26 12:07:00Z]}}

      assert classify(429, "") == {:error, {:limit, nil}}
      assert classify(429, "<html><body>slow down</body></html>") == {:error, {:limit, nil}}
    end

    test "Retry-After wins over the description's 'Retry in N minutes'" do
      assert classify(429, error(500, "Request limit reached. Retry in 7 minutes."), %{
               "retry-after" => ["60"]
             }) == {:error, {:limit, ~U[2026-11-26 12:01:00Z]}}
    end

    test "a Retry-After that reads as neither seconds nor a date falls through to the description" do
      body = error(500, "Request limit reached. Retry in 2 minutes.")
      expected = {:error, {:limit, ~U[2026-11-26 12:02:00Z]}}

      for value <- ["-5", "+5", "1.5", "soon", "", "Thu, 26 Nov 2026 15:30:00 +0100"] do
        assert {value, classify(429, body, %{"retry-after" => [value]})} == {value, expected}
      end
    end

    test "a stated wait is at most 366 days, so a huge number reads as that cap" do
      cap = ~U[2027-11-27 12:00:00Z]

      assert classify(429, "", %{"retry-after" => [String.duplicate("9", 30)]}) ==
               {:error, {:limit, cap}}

      assert classify(429, error(500, "limit. Retry in #{String.duplicate("9", 30)} minutes")) ==
               {:error, {:limit, cap}}

      assert classify(429, "", %{"retry-after" => ["31622400"]}) == {:error, {:limit, cap}}

      assert classify(429, "", %{"retry-after" => ["31622399"]}) ==
               {:error, {:limit, ~U[2027-11-27 11:59:59Z]}}
    end

    test "Retry-After reads the RFC 850 and asctime date forms too (RFC 9110 5.6.7)" do
      cap = ~U[2027-11-27 12:00:00Z]

      for {value, wait} <- [
            {"Thursday, 26-Nov-26 15:30:00 GMT", ~U[2026-11-26 15:30:00Z]},
            {"Thu Nov 26 15:30:00 2026", ~U[2026-11-26 15:30:00Z]},
            {"Fri Nov  6 15:30:00 2026", ~U[2026-11-06 15:30:00Z]},
            # A two-digit year more than 50 years ahead is the century before.
            {"Saturday, 06-Nov-77 08:49:37 GMT", ~U[1977-11-06 08:49:37Z]},
            {"Friday, 06-Nov-76 08:49:37 GMT", cap},
            {"Thursday, 31-Feb-26 15:30:00 GMT", nil},
            {"Thu Foo 26 15:30:00 2026", nil},
            {"Thu Nov 26 15:30:00 2026 GMT", nil}
          ] do
        assert {value, classify(429, "", %{"retry-after" => [value]})} ==
                 {value, {:error, {:limit, wait}}}
      end
    end

    test "a number of more than 18 digits is none, and a longer stated wait reads as the cap" do
      cap = ~U[2027-11-27 12:00:00Z]
      huge = String.duplicate("9", 2_000_000)

      assert classify(200, error(huge, "x")) == {:error, :bad_response}
      assert classify(200, error(String.duplicate("1", 19), "x")) == {:error, :bad_response}

      eighteen = String.duplicate("1", 18)

      assert classify(200, error(eighteen, "x")) ==
               {:error, {:indexer_error, String.to_integer(eighteen)}}

      assert classify(429, "", %{"retry-after" => [huge]}) == {:error, {:limit, cap}}

      assert classify(429, error(500, "limit. Retry in #{huge} minutes")) ==
               {:error, {:limit, cap}}
    end

    test "HTTP 410 and 404 are their status, before any <error> element" do
      assert classify(410, error(410, "Indexer is disabled")) == {:error, {:http_status, 410}}

      assert classify(410, error(100, "Incorrect user credentials")) ==
               {:error, {:http_status, 410}}

      assert classify(404, "") == {:error, {:http_status, 404}}

      assert classify(404, error(100, "Incorrect user credentials")) ==
               {:error, {:http_status, 404}}
    end

    test "the <error> codes of rule 6, on a 2xx answer" do
      for {code, description, class} <- [
            {100, "Incorrect user credentials", :rejected_credentials},
            {101, "Account suspended", :rejected_credentials},
            {102, "Insufficient privileges", :rejected_credentials},
            {910, "API disabled", :rejected_credentials},
            {500, "Request limit reached", {:limit, nil}},
            {501, "Daily LIMIT reached", {:limit, nil}},
            {500, "Internal error", {:indexer_error, 500}},
            {501, "Not implemented", {:indexer_error, 501}},
            {200, "Missing parameter", {:query_error, 200}},
            {201, "Incorrect parameter", {:query_error, 201}},
            {202, "No such function", {:query_error, 202}},
            {203, "Function not available", {:query_error, 203}},
            {300, "No such item", {:query_error, 300}},
            {103, "Unknown", {:indexer_error, 103}},
            {204, "Unknown", {:indexer_error, 204}},
            {900, "Unknown error", {:indexer_error, 900}}
          ] do
        assert {code, classify(200, error(code, description))} == {code, {:error, class}}
      end
    end

    test "an <error> element is read on a status outside 2xx too" do
      assert classify(400, error(201, "Incorrect parameter (imdbid)")) ==
               {:error, {:query_error, 201}}

      assert classify(403, error(100, "Incorrect user credentials")) ==
               {:error, :rejected_credentials}

      assert classify(503, error(900, "Unknown")) == {:error, {:indexer_error, 900}}
      assert classify(302, error(101, "Account suspended")) == {:error, :rejected_credentials}

      assert classify(500, error(500, "Request limit reached. Retry in 3 minutes.")) ==
               {:error, {:limit, ~U[2026-11-26 12:03:00Z]}}
    end

    test "an <error> element with no integer code is no <error> answer" do
      assert classify(200, ~s(<error code="abc" description="x"/>)) == {:error, :bad_response}
      assert classify(200, ~s(<error description="x"/>)) == {:error, :bad_response}
      assert classify(503, ~s(<error code="-1"/>)) == {:error, {:http_status, 503}}
    end

    test "an <error> element below the root is not an <error> answer" do
      assert classify(200, rss(~s(<error code="100"/>))) == {:ok, []}
    end

    test "any other answer is an indexer failure with its status" do
      for status <- [500, 502, 503, 408, 403, 400, 418, 301, 302, 304, 100] do
        assert {status, classify(status, "down")} == {status, {:error, {:http_status, status}}}
      end

      assert classify(503, rss()) == {:error, {:http_status, 503}}
    end

    test "a 2xx body that is no RSS document is a bad response" do
      for body <- [
            "",
            "oops",
            "<html><body><form>Login</form></body></html>",
            "<!DOCTYPE html><html><body>Login</body></html>",
            ~s(<rss version="2.0"/>),
            ~s(<rss version="2.0"><item/></rss>),
            ~s(<caps><searching/></caps>),
            %{"rss" => true},
            nil
          ] do
        assert {body, classify(200, body)} == {body, {:error, :bad_response}}
      end
    end

    test "a body over 4 MiB is too large, whatever its status; one of exactly 4 MiB is read" do
      padding = fn bytes -> String.duplicate(" ", bytes - byte_size(rss())) end
      exact = rss() <> padding.(4 * 1024 * 1024)

      assert byte_size(exact) == 4_194_304
      assert classify(200, exact) == {:ok, []}
      assert classify(200, exact <> " ") == {:error, :too_large}
      assert classify(401, exact <> " ") == {:error, :too_large}
    end
  end

  describe "classify_caps/4" do
    test "reads a 2xx caps root as a success and anything else by the same ladder" do
      caps = ~s(<caps><searching/><categories/></caps>)

      assert {:ok, {"caps", [], _children}} = NewznabAnswer.classify_caps(200, %{}, caps, @now)

      assert NewznabAnswer.classify_caps(200, %{}, rss(), @now) == {:error, :bad_response}

      assert NewznabAnswer.classify_caps(200, %{}, error(100, "x"), @now) ==
               {:error, :rejected_credentials}

      assert NewznabAnswer.classify_caps(429, %{"retry-after" => ["60"]}, "", @now) ==
               {:error, {:limit, ~U[2026-11-26 12:01:00Z]}}

      assert NewznabAnswer.classify_caps(503, %{}, caps, @now) == {:error, {:http_status, 503}}
    end
  end

  describe "read/2 and read_caps/2" do
    test "classify a response and pass each transport tag through" do
      response = %Req.Response{status: 200, headers: %{}, body: rss("<item/>")}
      assert {:ok, [_item]} = NewznabAnswer.read({:ok, response}, @now)

      for tag <- [:timeout, :deadline, :dns, :connection_refused, :connection_failed, :too_large] do
        assert NewznabAnswer.read({:error, tag}, @now) == {:error, tag}
        assert NewznabAnswer.read_caps({:error, tag}, @now) == {:error, tag}
      end

      limited = %Req.Response{status: 429, headers: %{"retry-after" => ["60"]}, body: ""}

      assert NewznabAnswer.read_caps({:ok, limited}, @now) ==
               {:error, {:limit, ~U[2026-11-26 12:01:00Z]}}
    end
  end

  describe "reason/1" do
    test "maps each class to the report's failure reason" do
      wait = ~U[2026-11-26 12:10:00Z]

      for {class, reason} <- [
            {:rejected_credentials, :rejected_credentials},
            {{:disabled_till, wait}, {:http_status, 429}},
            {{:disabled_till, nil}, {:http_status, 429}},
            {{:limit, wait}, {:limit, wait}},
            {{:limit, nil}, {:limit, nil}},
            {{:http_status, 410}, {:http_status, 410}},
            {{:query_error, 201}, {:indexer_error, 201}},
            {{:indexer_error, 900}, {:indexer_error, 900}},
            {:bad_response, :bad_response},
            {:too_large, :too_large},
            {:timeout, :timeout},
            {:dns, :dns},
            {:connection_refused, :connection_refused},
            {:connection_failed, :connection_failed},
            {:deadline, :deadline}
          ] do
        assert {class, NewznabAnswer.reason(class)} == {class, reason}
      end
    end
  end
end
