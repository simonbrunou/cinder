defmodule Cinder.Accounts.UserNotifierTest do
  # async: false — swaps the adapter in Cinder.Mailer's Application env.
  use Cinder.DataCase, async: false

  import ExUnit.CaptureLog

  alias Cinder.Accounts.UserNotifier
  alias Cinder.Test.ClosedPort

  @password "smtp-password-sentinel-1535"

  # The relay sits on a closed port: the SMTP adapter refuses `-bad.com` while it renders the To
  # header, before any connection, and `no_mx_lookups` keeps gen_smtp off DNS either way.
  defp configure_smtp!(overrides) do
    Cinder.ConfigCase.put_config(
      Cinder.Mailer,
      Keyword.merge(
        [adapter: Swoosh.Adapters.SMTP, password: @password, no_mx_lookups: true, retries: 0],
        overrides
      )
    )
  end

  defp warnings(log), do: Regex.scan(~r/\[warning\]/, log) |> length()

  # Reports to the test process whether the email-change token row exists at the moment the
  # mailer delivers, then fails the delivery.
  defmodule TokenProbeAdapter do
    use Swoosh.Adapter

    @impl true
    def deliver(_email, config) do
      user_id = Keyword.fetch!(config, :probe_user_id)
      context = Keyword.fetch!(config, :probe_context)
      present? = Cinder.Repo.get_by(Cinder.Accounts.UserToken, user_id: user_id, context: context)
      send(self(), {:token_at_delivery, present? != nil})
      {:error, :probe}
    end
  end

  describe "deliver_update_email_instructions/2 with no SMTP host in prod" do
    # Prod keeps Swoosh.Adapters.Local and sets `config :swoosh, local: false`, so its mailbox
    # (`Swoosh.Adapters.Local.Storage.Memory`) never starts and `Memory.push/1`'s
    # `GenServer.call({:global, Memory}, {:push, email})` exits with `:noproc`. The test env starts
    # that mailbox, so `Cinder.Test.UnstartedMailbox` makes the same call to a name nobody holds.
    test "the mailbox's :noproc exit returns an error and logs its tag, never the email" do
      Cinder.ConfigCase.put_config(Cinder.Mailer,
        adapter: Swoosh.Adapters.Local,
        storage_driver: Cinder.Test.UnstartedMailbox
      )

      {result, log} =
        with_log(fn ->
          UserNotifier.deliver_update_email_instructions(
            %{email: "someone@example.com"},
            "http://cinder/users/settings/confirm-email/token-sentinel-1535"
          )
        end)

      assert {:error, {:exit, {:noproc, _}}} = result
      assert log =~ "update email delivery exit: :noproc"
      assert warnings(log) == 1, log
      refute log =~ "token-sentinel-1535"
      refute log =~ "someone@"
    end
  end

  # Exits or throws with the value its config names.
  defmodule FailingAdapter do
    use Swoosh.Adapter

    @impl true
    def deliver(_email, config) do
      case Keyword.fetch!(config, :fail_with) do
        {:exit, value} -> exit(value)
        {:throw, value} -> throw(value)
      end
    end
  end

  describe "the warning for other exits and throws" do
    test "names a bare atom reason, and no part of a reason without an atom tag" do
      for {failure, expected} <- [
            {{:exit, :shutdown}, "update email delivery exit: :shutdown"},
            {{:throw, "someone@example.com"}, "update email delivery throw: (no tag)"}
          ] do
        Cinder.ConfigCase.put_config(Cinder.Mailer, adapter: FailingAdapter, fail_with: failure)

        {result, log} =
          with_log(fn ->
            UserNotifier.deliver_update_email_instructions(%{email: "a@example.com"}, "u")
          end)

        assert {:error, ^failure} = result
        assert log =~ expected, log
        assert warnings(log) == 1, log
        refute log =~ "someone@"
      end
    end
  end

  describe "Accounts.deliver_user_update_email_instructions/3" do
    test "inserts the change token before the mailer delivers, and returns the failed delivery" do
      user = Cinder.AccountsFixtures.user_fixture()
      context = "change:#{user.email}"

      Cinder.ConfigCase.put_config(Cinder.Mailer,
        adapter: TokenProbeAdapter,
        probe_user_id: user.id,
        probe_context: context
      )

      assert {:error, :probe} =
               Cinder.Accounts.deliver_user_update_email_instructions(
                 %{user | email: "new@example.com"},
                 user.email,
                 &"http://x/#{&1}"
               )

      assert_received {:token_at_delivery, true}
    end
  end

  describe "deliver_update_email_instructions/2 under the SMTP adapter" do
    test "a domain idna refuses returns an error and logs one warning naming its tag only" do
      configure_smtp!(relay: "127.0.0.1", port: ClosedPort.number())

      {result, log} =
        with_log(fn ->
          UserNotifier.deliver_update_email_instructions(%{email: "x@-bad.com"}, "http://x/t")
        end)

      assert {:error, {:exit, {:bad_label, _}}} = result
      assert log =~ "update email delivery exit: :bad_label"
      assert warnings(log) == 1, log
      refute log =~ "-bad"
    end

    # Swoosh.Adapter.validate_config/2 raises an ArgumentError whose message inspects the whole
    # config, so the log names the exception and never its message.
    test "a raising adapter returns an error and logs one warning, without the password" do
      configure_smtp!([])

      {result, log} =
        with_log(fn ->
          UserNotifier.deliver_update_email_instructions(
            %{email: "x@example.com"},
            "http://x/t"
          )
        end)

      assert {:error, %ArgumentError{}} = result
      assert log =~ "update email delivery raised ArgumentError"
      assert warnings(log) == 1, log
      refute log =~ @password
    end
  end
end
