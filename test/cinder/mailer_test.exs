defmodule Cinder.MailerTest do
  use ExUnit.Case, async: true

  alias Cinder.Mailer

  describe "reason_tag/1" do
    test "names an atom, a tuple's atom tag or an exception module, and nothing else" do
      for {reason, expected} <- [
            {:noproc, ":noproc"},
            {nil, "nil"},
            {{:bad_label, "x@-bad.com"}, ":bad_label"},
            {{:retries_exceeded, {:network_failure, ~c"127.0.0.1", {:error, :econnrefused}}},
             ":retries_exceeded"},
            {%ArgumentError{message: "password: secret-sentinel"}, "ArgumentError"},
            {"x@example.com", "(no tag)"},
            {[password: "secret-sentinel"], "(no tag)"},
            {{"x@example.com", :rejected}, "(no tag)"},
            {{}, "(no tag)"},
            {%{to: "x@example.com"}, "(no tag)"},
            {%{__exception__: true, __struct__: "x@example.com"}, "(no tag)"},
            {42, "(no tag)"}
          ] do
        assert Mailer.reason_tag(reason) == expected, inspect(reason)
      end
    end
  end
end
