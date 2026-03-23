ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Destila.Repo, :manual)
Supervisor.start_link([ClaudeCode.Test], strategy: :one_for_one)
