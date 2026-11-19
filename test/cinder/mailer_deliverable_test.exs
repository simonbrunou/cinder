defmodule Cinder.MailerDeliverableTest do
  # Changes the Cinder.Mailer config and stops Swoosh's node-global local mailbox.
  use ExUnit.Case, async: false

  alias Cinder.ConfigCase
  alias Cinder.Mailer
  alias Cinder.Test.StoppedMailbox

  defp email,
    do: Swoosh.Email.new(to: "to@example.com", from: Mailer.from(), subject: "s", text_body: "t")

  describe "deliverable?/0" do
    test "is false under the Local adapter with its mailbox stopped, where deliver/1 exits" do
      ConfigCase.put_config(Mailer, adapter: Swoosh.Adapters.Local)
      StoppedMailbox.stop!()

      refute Mailer.deliverable?()
      assert catch_exit(Mailer.deliver(email())) |> elem(0) == :noproc
    end

    test "is true under the Local adapter with its mailbox running, as in dev" do
      ConfigCase.put_config(Mailer, adapter: Swoosh.Adapters.Local)

      assert Mailer.deliverable?()
      assert {:ok, _} = Mailer.deliver(email())
    end

    test "is true under SMTP and under Test, even with the local mailbox stopped" do
      StoppedMailbox.stop!()

      ConfigCase.put_config(Mailer, adapter: Swoosh.Adapters.SMTP, relay: "127.0.0.1")
      assert Mailer.deliverable?()

      ConfigCase.put_config(Mailer, adapter: Swoosh.Adapters.Test)
      assert Mailer.deliverable?()
    end
  end
end
