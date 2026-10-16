defmodule StewardWeb.Plane do
  @moduledoc """
  Starts the gRPC listener for `steward.plane.v1.Session` (doc 07 §3.1): port
  50051, separate from Phoenix so they share supervision and config but not a
  socket.

  Configuration (`config :steward, StewardWeb.Plane`):

    * `:start_server` — whether the application starts the listener (false in
      tests, which start their own on a free port).
    * `:port` — default 50051.
    * `:identity` — `:cert` (the stream's client certificate names the data plane)
      or `:header` (development only; see `StewardWeb.Plane.Identity`).
    * `:tls` — `[certfile:, keyfile:, cacertfile:]` for the server certificate and
      the CA that issued data-plane identities. With it the listener requires and
      verifies a client certificate (mTLS). Without it the listener is plaintext
      HTTP/2, which `config/runtime.exs` refuses in production.
  """

  @doc "Child specs for `Steward.Application`; empty when the listener is disabled."
  def child_specs do
    config = Application.get_env(:steward, __MODULE__, [])

    if Keyword.get(config, :start_server, false) do
      [{GRPC.Server.Supervisor, supervisor_opts(config)}]
    else
      []
    end
  end

  @doc false
  def supervisor_opts(config) do
    [
      endpoint: StewardWeb.Plane.Endpoint,
      port: Keyword.get(config, :port, 50051),
      start_server: true
    ] ++
      case Keyword.get(config, :tls) do
        nil -> []
        tls -> [adapter_opts: [cred: credential(tls)]]
      end
  end

  @doc false
  def credential(tls) do
    GRPC.Credential.new(
      ssl: [
        certfile: Keyword.fetch!(tls, :certfile),
        keyfile: Keyword.fetch!(tls, :keyfile),
        cacertfile: Keyword.fetch!(tls, :cacertfile),
        verify: :verify_peer,
        fail_if_no_peer_cert: true
      ]
    )
  end
end
