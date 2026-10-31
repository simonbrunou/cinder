defmodule Cinder.CodeHealth.CiBrowserWaitTest do
  # #1030: LiveView falls back to long-poll when the WebSocket misses `longPollFallbackMs` on a
  # loaded runner, and a connected long-poll client keeps a poll request open. A Playwright wait
  # on "networkidle" in a CI browser script then does not end, and the `container` job fails after
  # 30 s. The scripts wait for the default "load" event, then for `wait_for_liveview(page)`.
  use ExUnit.Case, async: true

  # One Python token per match, scanned left to right: a comment, a string (triple-quoted first,
  # each with its optional prefix), a name, or one punctuation character. Whitespace is skipped,
  # so a call split across lines reads the same as one on a single line.
  @python_token ~r/
    \#[^\n]*
    | [rbfuRBFU]{0,2} (?: """[\s\S]*?""" | '''[\s\S]*?''' | "(?:\\.|[^"\\\n])*" | '(?:\\.|[^'\\\n])*' )
    | \w+
    | [^\s\w]
  /x

  test "no CI browser script waits for networkidle" do
    paths = Path.wildcard(".github/scripts/**/*.py")

    offenders =
      for path <- paths,
          line <- path |> File.read!() |> networkidle_wait_lines(),
          do: "#{path}:#{line}"

    assert paths != []

    assert offenders == [],
           "keep Playwright's default \"load\" wait, then call wait_for_liveview(page), instead " <>
             "of waiting for networkidle (#1030):\n  " <> Enum.join(offenders, "\n  ")
  end

  test "the scan finds each form of networkidle wait" do
    source = ~S'''
    page.goto(url, wait_until="networkidle")
    page.wait_for_load_state("networkidle")
    page.wait_for_load_state(state='networkidle')
    page.reload(wait_until = "networkidle")
    page.wait_for_load_state(
        "networkidle"
    )
    page.goto(
        f"{BASE_URL}/library",
        wait_until="networkidle",
    )
    '''

    assert networkidle_wait_lines(source) == [1, 2, 3, 4, 5, 10]
  end

  test "the scan skips comments, strings and other waits" do
    source = ~S'''
    """Docstring: page.goto(url, wait_until="networkidle") used to time out."""
    # page.goto(url, wait_until="networkidle")
    pass  # page.wait_for_load_state("networkidle")
    print('wait_until="networkidle" does not arrive under long-poll')
    print(f"no {state}=networkidle here")
    page.goto(url, wait_until="load")
    page.wait_for_load_state("domcontentloaded")
    '''

    assert networkidle_wait_lines(source) == []
  end

  defp networkidle_wait_lines(source) do
    @python_token
    |> Regex.scan(source, return: :index)
    |> Enum.map(fn [{offset, length}] -> {binary_part(source, offset, length), offset} end)
    |> Enum.reject(fn {token, _offset} -> String.starts_with?(token, "#") end)
    |> Enum.chunk_every(3, 1, :discard)
    |> Enum.filter(fn [{name, _offset}, {op, _}, {value, _}] ->
      {name, op} in [{"wait_until", "="}, {"state", "="}, {"wait_for_load_state", "("}] and
        string_value(value) == "networkidle"
    end)
    |> Enum.map(fn [{_name, offset} | _] ->
      source |> binary_part(0, offset) |> String.split("\n") |> length()
    end)
  end

  defp string_value(token) do
    case Regex.run(~r/\A[rbfuRBFU]{0,2}("""|'''|"|')([\s\S]*)\1\z/, token) do
      [_token, _quote, value] -> value
      nil -> nil
    end
  end
end
