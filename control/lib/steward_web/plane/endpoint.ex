defmodule StewardWeb.Plane.Endpoint do
  @moduledoc "The gRPC endpoint (doc 07 §3.1): the `Session` service on its own port, separate from Phoenix."
  use GRPC.Endpoint

  run StewardWeb.Plane.Server
end
