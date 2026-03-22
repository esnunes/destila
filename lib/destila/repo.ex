defmodule Destila.Repo do
  use Ecto.Repo,
    otp_app: :destila,
    adapter: Ecto.Adapters.SQLite3
end
