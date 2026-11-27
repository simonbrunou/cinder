defmodule Cinder.MailerSmtpLogTest do
  # async: false: lowers the node's primary log level to :debug and swaps Cinder.Mailer's adapter.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  require Logger

  alias Cinder.ConfigCase
  alias Cinder.Test.ClosedPort

  @sentinel "sentinel-1548"

  setup do
    primary = Logger.level()
    mimemail = :logger.get_module_level(:mimemail)

    on_exit(fn ->
      Logger.configure(level: primary)

      case mimemail do
        [{:mimemail, level}] -> :logger.set_module_level(:mimemail, level)
        [] -> :logger.unset_module_level(:mimemail)
      end
    end)

    :ok
  end

  # gen_smtp's `mimemail` logs the mail's headers, To included, at :debug while it encodes the
  # mail, before any connection: a relay on a closed port is enough (#1548). The test leaves the
  # delivery's result alone, since the encoding logs whether or not the relay answers.
  test "an SMTP delivery attempt at the :debug level logs no recipient address" do
    ConfigCase.put_config(Cinder.Mailer,
      adapter: Swoosh.Adapters.SMTP,
      relay: "127.0.0.1",
      port: ClosedPort.number(),
      no_mx_lookups: true,
      retries: 0
    )

    Logger.configure(level: :debug)

    email =
      Swoosh.Email.new(
        to: "#{@sentinel}@example.com",
        from: Cinder.Mailer.from(),
        subject: "s",
        text_body: "t"
      )

    log =
      capture_log(fn ->
        Logger.debug("debug-marker-1548")
        Cinder.Mailer.deliver(email)
      end)

    assert log =~ "debug-marker-1548"
    refute log =~ @sentinel
  end

  # OTP's ssl sets `ssl_logger`'s own level when it starts (`ssl_app:start/2`), and
  # `Cinder.CaptureServerGuard.install/0`, which test/test_helper.exs calls, sets
  # `logger_backend`'s to `:debug`.
  test "boot sets a module level on gen_smtp's :mimemail alone, at :info" do
    levels =
      Enum.reject(
        :logger.get_module_level(),
        &(match?({:ssl_logger, _}, &1) or &1 == {:logger_backend, :debug})
      )

    assert levels == [{:mimemail, :info}]
  end
end
