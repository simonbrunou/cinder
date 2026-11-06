defmodule CinderWeb.SignInRefusalHelpers do
  @moduledoc """
  Assertions on the `<provider>_signin refused` warning lines that `CinderWeb.SignInRefusal`
  writes.
  """

  import ExUnit.Assertions

  @doc "The lines of a captured log that hold `<prefix> refused`, `prefix` being `plex_signin`..."
  def refusal_lines(log, prefix) do
    log
    |> String.split("\n")
    |> Enum.filter(&String.contains?(&1, prefix <> " refused"))
  end

  @doc """
  Asserts the captured `log` holds exactly one refusal line for the prefix `message` starts
  with, written at warning level, whose message is exactly `message`. Returns the line.
  """
  def assert_one_refusal(log, message) do
    [prefix | _rest] = String.split(message, " ", parts: 2)

    lines = refusal_lines(log, prefix)

    assert match?([_line], lines),
           "expected exactly one #{prefix} refusal line, the captured log was:\n#{log}"

    [line] = lines

    assert String.ends_with?(line, "[warning] " <> message),
           "expected the line to end in #{inspect("[warning] " <> message)}, got:\n#{line}"

    line
  end

  @doc """
  Asserts `log` holds at least one refusal line for `prefix` and none of `secrets`, so the
  refutes cannot pass on an empty capture. `label` names the case in a failure.
  """
  def refute_secrets(log, prefix, secrets, label) do
    assert refusal_lines(log, prefix) != [],
           "#{label}: no #{prefix} refusal line, the captured log was:\n#{log}"

    for secret <- secrets do
      refute log =~ secret, "#{label}: the log holds #{inspect(secret)}:\n#{log}"
    end
  end
end
