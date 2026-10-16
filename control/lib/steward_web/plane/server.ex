defmodule StewardWeb.Plane.Server do
  @moduledoc """
  The `steward.plane.v1.Session` gRPC service (doc 07 §3.1, doc 10 §5): the
  bidirectional stream a data plane opens to the control plane. This module is
  framing and lifecycle only; what each message means is
  `Steward.Coordinator.Plane.Upstream`, and who is waiting for what is
  `Steward.Coordinator.Plane`.

  One process runs the stream (this one, which writes downstream messages) and a
  task reads it (decoding, rate limiting and handling upstream messages). Either
  ends the stream with a gRPC status:

    * `UNAUTHENTICATED` / `PERMISSION_DENIED`: no usable identity (`Identity`).
    * `PERMISSION_DENIED`: a message named a `data_plane_id` other than the
      stream's, "a mismatch closes the stream" (doc 10 §5).
    * `ABORTED`: a newer stream for the same identity superseded this one; the
      data plane keeps exactly one open.
    * `RESOURCE_EXHAUSTED`: a message over 1 MiB (`StewardWeb.Plane.Codec`).
  """
  use GRPC.Server,
    service: Steward.Plane.V1.Session.Service,
    codecs: [StewardWeb.Plane.Codec]

  require Logger

  alias Steward.Coordinator.Plane
  alias Steward.Coordinator.Plane.{Directory, Upstream}
  alias StewardWeb.Plane.Identity

  def connect(requests, stream) do
    %{data_plane_id: dp_id, org_id: org_id} = identity!(stream)
    handler = self()

    case Plane.attach(org_id, dp_id, handler) do
      :ok -> :ok
      {:error, :wrong_org} -> deny!(:permission_denied, "data plane belongs to another org")
    end

    # Best effort, and off the stream's path: a failed write must not end a stream.
    Task.start(fn ->
      try do
        Directory.touch(org_id, dp_id)
      catch
        _, _ -> :ok
      end
    end)

    :telemetry.execute([:steward, :plane, :stream_opened], %{count: 1}, %{data_plane_id: dp_id})

    state = Upstream.new(org_id, dp_id, non_terminal: Directory.non_terminal_count(org_id, dp_id))
    reader = Task.async(fn -> read(requests, state, handler) end)

    try do
      loop(stream)
    after
      Task.shutdown(reader, :brutal_kill)
      :telemetry.execute([:steward, :plane, :stream_closed], %{count: 1}, %{data_plane_id: dp_id})
    end
  end

  # --- downstream: this process owns the writes ---------------------------------

  defp loop(stream) do
    receive do
      {:push, message} ->
        GRPC.Server.send_reply(stream, message)
        loop(stream)

      :superseded ->
        deny!(:aborted, "superseded by a newer stream for this data plane")

      {:fatal, %GRPC.RPCError{} = error} ->
        raise error

      :close ->
        :ok
    end
  end

  # --- upstream: one task per stream, so the limiter needs no sharing -----------

  defp read(requests, state, handler) do
    final =
      Enum.reduce_while(requests, state, fn message, state ->
        state = if Upstream.stale_capacity?(state), do: refresh(state), else: state

        case Upstream.handle(state, message) do
          {:error, :identity_mismatch} ->
            send(
              handler,
              {:fatal,
               rpc_error(:permission_denied, "data_plane_id does not match the stream's identity")}
            )

            {:halt, state}

          {state, replies} ->
            Enum.each(replies, &send(handler, {:push, &1}))
            {:cont, state}
        end
      end)

    send(handler, :close)
    final
  rescue
    error in GRPC.RPCError ->
      send(handler, {:fatal, error})

    error ->
      Logger.error("session reader crashed: #{Exception.message(error)}")
      send(handler, {:fatal, rpc_error(:internal, "internal error")})
  end

  defp refresh(%Upstream{} = state),
    do: Upstream.retune(state, Directory.non_terminal_count(state.org_id, state.data_plane_id))

  # --- identity ---------------------------------------------------------------------

  defp identity!(stream) do
    case Identity.resolve(stream, mode()) do
      {:ok, identity} ->
        identity

      {:error, :unauthenticated} ->
        deny!(:unauthenticated, "no valid data-plane identity")

      {:error, :permission_denied} ->
        deny!(:permission_denied, "unknown data plane or certificate")
    end
  end

  defp mode,
    do: Application.get_env(:steward, StewardWeb.Plane, []) |> Keyword.get(:identity, :cert)

  defp deny!(status, message), do: raise(rpc_error(status, message))

  defp rpc_error(status, message),
    do: GRPC.RPCError.exception(status: apply(GRPC.Status, status, []), message: message)
end
