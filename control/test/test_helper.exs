ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Steward.Repo, :manual)

# One plaintext Session listener for every server-based test (see Steward.SessionHarness).
Steward.SessionHarness.start_shared()
