defmodule Cinder.Repo do
  use Ecto.Repo,
    otp_app: :cinder,
    adapter: Ecto.Adapters.SQLite3
end
