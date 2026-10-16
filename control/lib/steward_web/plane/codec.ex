defmodule StewardWeb.Plane.Codec do
  @moduledoc """
  The protobuf codec with the 1 MiB receive limit of doc 10 §5: a
  `DataPlaneMessage` over the limit is refused with `RESOURCE_EXHAUSTED`, counted
  in `[:steward, :plane, :oversize]` (`steward_plane_oversize_total`), and never
  partially accepted. The check is on the framed bytes, before they are decoded.

  Only the server's receive side decodes requests, so the limit applies to
  upstream messages only; the 4 MiB allowance for `ComputeChangeset` is on the
  downstream message, which this codec only encodes.
  """
  @behaviour GRPC.Codec

  @max_receive_bytes 1_048_576

  def max_receive_bytes, do: @max_receive_bytes

  @impl true
  def name, do: "proto"

  @impl true
  def encode(struct, opts \\ []), do: GRPC.Codec.Proto.encode(struct, opts)

  @impl true
  def decode(binary, _module) when byte_size(binary) > @max_receive_bytes do
    :telemetry.execute([:steward, :plane, :oversize], %{bytes: byte_size(binary)}, %{})

    raise GRPC.RPCError,
      status: GRPC.Status.resource_exhausted(),
      message:
        "message of #{byte_size(binary)} bytes exceeds the #{@max_receive_bytes} byte limit"
  end

  def decode(binary, module), do: GRPC.Codec.Proto.decode(binary, module)
end
