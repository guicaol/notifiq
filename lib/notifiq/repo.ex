defmodule Notifiq.Repo do
  use Ecto.Repo,
    otp_app: :notifiq,
    adapter: Ecto.Adapters.Postgres
end
