defmodule Cinder.Accounts.UserNotifier do
  @moduledoc false

  import Swoosh.Email

  require Logger

  alias Cinder.Mailer

  # Delivers the email using the application mailer. A raise, exit or throw inside the adapter
  # comes back as `{:error, reason}` with one warning, so a caller such as the settings LiveView
  # stays up (#1535). Two such exits:
  #
  #   * under Swoosh.Adapters.SMTP, `:idna` exits on a domain it refuses (`x@-bad.com`) while
  #     it renders the To header;
  #   * with no SMTP host, prod keeps Swoosh.Adapters.Local while `config :swoosh, local: false`
  #     leaves its mailbox process unstarted, so `Memory.push/1` exits with `:noproc`.
  #
  # A plain `{:error, reason}` from the mailer, such as a refused SMTP relay's
  # `{:retries_exceeded, _}`, comes back as it is, with one warning too (#1543).
  #
  # The warning names the exception module or the reason's atom tag, else `(no tag)`
  # (`Mailer.reason_tag/1`), never the value itself: `Swoosh.Adapter.validate_config/2` raises a
  # message that inspects the whole mailer config, SMTP password included, and the `:noproc` exit
  # holds the email, confirm-link token included.
  defp deliver(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from(Mailer.from())
      |> subject(subject)
      |> text_body(body)

    case Mailer.deliver(email) do
      {:ok, _metadata} ->
        {:ok, email}

      {:error, reason} = error ->
        Logger.warning("update email delivery failed: #{Mailer.reason_tag(reason)}")
        error
    end
  rescue
    e ->
      Logger.warning("update email delivery raised #{Mailer.reason_tag(e)}")
      {:error, e}
  catch
    kind, value ->
      Logger.warning("update email delivery #{kind}: #{Mailer.reason_tag(value)}")
      {:error, {kind, value}}
  end

  @doc """
  Deliver instructions to update a user email.
  """
  def deliver_update_email_instructions(user, url) do
    deliver(user.email, "Update email instructions", """

    ==============================

    Hi #{user.email},

    You can change your email by visiting the URL below:

    #{url}

    If you didn't request this change, please ignore this.

    ==============================
    """)
  end
end
