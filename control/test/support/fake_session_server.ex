defmodule Steward.FakeSessionServer do
  @moduledoc """
  A minimal `steward.plane.v1.Session` server for exercising
  `Steward.FakeDataPlane`'s gRPC transport before E3 (the real Session host,
  doc 07 §3.1) exists. It owns no state machine: it forwards what the data plane
  sends to the test and pushes down whatever the test hands it.

      {:ok, server} = Steward.FakeSessionServer.start_link(self())
      # ... the data plane dials server.address ...

  There is one listener per VM (its name comes from the endpoint module), so
  start it once per test module (`setup_all`) and call `attach/1` in each test.
      assert_receive {:session_up, %DataPlaneMessage{}}
      Steward.FakeSessionServer.push(server, %Instruction{...})

  It is not a stand-in for E3's behaviour (heartbeat decisions, token buckets,
  mTLS). E3's tests use the real host with this fake data plane.
  """
  use GRPC.Server, service: Steward.Plane.V1.Session.Service

  alias Steward.Plane.V1

  defmodule Endpoint do
    @moduledoc false
    use GRPC.Endpoint
    run Steward.FakeSessionServer
  end

  @doc """
  Starts the server on a free port, under the calling test's supervisor.
  Messages from the data plane arrive at `controller` as `{:session_up, message}`;
  `{:session_open, handler}` announces a new stream.
  """
  def start_link(controller) do
    port = free_port()
    attach(controller)

    {:ok, sup} =
      GRPC.Server.Supervisor.start_link(endpoint: Endpoint, port: port, start_server: true)

    {:ok, %{supervisor: sup, address: "127.0.0.1:#{port}", port: port}}
  end

  @doc "Routes upstream messages and new-stream notices to `controller` from now on."
  def attach(controller), do: :persistent_term.put({__MODULE__, :controller}, controller)

  @doc "Sends a downstream message (`Instruction`, `HeartbeatReply` or `ControlPlaneMessage`) on an open stream."
  def push(handler, message), do: send(handler, {:push, wrap(message)})

  @doc "Ends the stream from the server side."
  def close(handler), do: send(handler, :close)

  def connect(requests, stream) do
    controller = :persistent_term.get({__MODULE__, :controller})
    handler = self()

    reader =
      Task.async(fn ->
        Enum.each(requests, fn
          %V1.DataPlaneMessage{} = message -> send(controller, {:session_up, message})
          _other -> :ok
        end)

        send(handler, :close)
      end)

    send(controller, {:session_open, handler})
    loop(stream)
    Task.shutdown(reader, :brutal_kill)
    :ok
  end

  defp loop(stream) do
    receive do
      {:push, message} ->
        GRPC.Server.send_reply(stream, message)
        loop(stream)

      :close ->
        :ok
    end
  end

  defp wrap(%V1.ControlPlaneMessage{} = m), do: m
  defp wrap(%V1.Instruction{} = i), do: %V1.ControlPlaneMessage{body: {:instruction, i}}
  defp wrap(%V1.HeartbeatReply{} = r), do: %V1.ControlPlaneMessage{body: {:heartbeat_reply, r}}

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
