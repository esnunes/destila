defmodule Destila.Repo do
  use Ecto.Repo,
    otp_app: :destila,
    adapter: Ecto.Adapters.SQLite3

  @impl true
  def init(_type, config) do
    {:ok,
     Keyword.merge(config,
       journal_mode: :wal,
       busy_timeout: 5000,
       cache_size: -64000
     )}
  end
end
