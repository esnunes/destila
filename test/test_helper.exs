ExUnit.start()
Supervisor.start_link([ClaudeCode.Test], strategy: :one_for_one)
