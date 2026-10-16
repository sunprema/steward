defmodule Steward.FakeDataPlane.SessionTransportTest do
  @moduledoc """
  The fake dials a real gRPC `Session.Connect` stream (doc 10 §5) and speaks the
  generated protobuf messages end to end, against `Steward.FakeSessionServer`.
  """
  use ExUnit.Case, async: false

  alias Steward.FakeDataPlane
  alias Steward.FakeSessionServer
  alias Steward.Plane.V1

  setup_all do
    {:ok, server} = FakeSessionServer.start_link(self())
    %{server: server}
  end

  setup %{server: server} do
    FakeSessionServer.attach(self())

    {:ok, dp} =
      FakeDataPlane.start_link(data_plane_id: "dp-grpc", transport: {:grpc, server.address})

    on_exit(fn -> if Process.alive?(dp), do: GenServer.stop(dp) end)
    assert_receive {:session_open, handler}, 5_000
    %{dp: dp, handler: handler}
  end

  defp instruction(id, body), do: %V1.Instruction{instruction_id: id, body: body}

  test "an instruction pushed on the stream is answered on the stream", %{
    dp: dp,
    handler: handler
  } do
    init = %V1.InitialiseOverlay{branch_id: "b1", target_id: "t1"}
    FakeSessionServer.push(handler, instruction("i-1", {:initialise_overlay, init}))

    assert_receive {:session_up,
                    %V1.DataPlaneMessage{
                      data_plane_id: "dp-grpc",
                      body: {:instruction_result, result}
                    }},
                   5_000

    assert result.instruction_id == "i-1"
    assert result.ok
    assert {:overlay_initialised, %V1.OverlayInitialised{overlay_id: overlay_id}} = result.body
    assert %{overlay_id: ^overlay_id} = FakeDataPlane.overlay(dp, "b1")
  end

  test "heartbeats and the reconciliation matrix work over the stream", %{
    dp: dp,
    handler: handler
  } do
    FakeSessionServer.push(
      handler,
      instruction(
        "i-1",
        {:initialise_overlay, %V1.InitialiseOverlay{branch_id: "b1", target_id: "t1"}}
      )
    )

    assert_receive {:session_up,
                    %V1.DataPlaneMessage{
                      body: {:instruction_result, %{body: {:overlay_initialised, init}}}
                    }},
                   5_000

    assert FakeDataPlane.heartbeat(dp) == 1
    assert_receive {:session_up, %V1.DataPlaneMessage{body: {:heartbeat, hb}}}, 5_000
    assert %{branch_id: "b1", overlay_id: overlay_id, believed_state: :OPEN} = hb
    assert overlay_id == init.overlay_id

    FakeSessionServer.push(handler, %V1.HeartbeatReply{
      branch_id: "b1",
      overlay_id: overlay_id,
      authoritative_state: :AUTH_PROPOSED
    })

    assert eventually(fn -> FakeDataPlane.overlay(dp, "b1").frozen end)
    assert FakeDataPlane.overlay(dp, "b1").believed == :proposed
  end

  test "a lost stream is a disconnect; reconnect dials again", %{dp: dp, handler: handler} do
    FakeSessionServer.close(handler)
    assert eventually(fn -> not FakeDataPlane.connected?(dp) end)

    FakeDataPlane.reconnect(dp)
    assert_receive {:session_open, _new_handler}, 5_000
    assert FakeDataPlane.connected?(dp)
  end

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(50) && eventually(fun, tries - 1)
    end
  end
end
