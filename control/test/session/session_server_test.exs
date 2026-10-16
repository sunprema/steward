defmodule StewardWeb.Plane.ServerTest do
  @moduledoc """
  The real `Session.Connect` listener (doc 07 §3.1, doc 10 §5) with the E13 fake
  data plane dialing it over HTTP/2, so framing, identity, supersession, limits
  and the whole path from a heartbeat to the branch coordinator and back are
  exercised together. Identity is by the development header here; certificates
  are `server_mtls_test.exs`.
  """
  use Steward.CoordinatorCase

  alias Steward.Coordinator.Plane
  alias Steward.Core.Audit.AuditLog
  alias Steward.Core.Targets.DataPlane
  alias Steward.FakeDataPlane
  alias Steward.Plane.V1

  setup_all do
    port = free_port()

    start_supervised!(
      Supervisor.child_spec(
        {GRPC.Server.Supervisor, StewardWeb.Plane.supervisor_opts(port: port)},
        shutdown: 500
      )
    )

    %{address: "127.0.0.1:#{port}"}
  end

  setup %{address: address} do
    org = org()
    owner = principal(org, :agent)
    dp = data_plane(org)
    target = target(org, principal(org, :human), data_plane_id: dp.id)
    %{org: org, owner: owner, dp: dp, target: target, address: address}
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp start_fake(ctx, opts \\ []) do
    id = Keyword.get(opts, :id, ctx.dp.id)
    transport = {:grpc, ctx.address, Keyword.take(opts, [:identity_header])}
    {:ok, fake} = FakeDataPlane.start_link(data_plane_id: id, transport: transport)
    on_exit(fn -> if Process.alive?(fake), do: GenServer.stop(fake) end)
    fake
  end

  defp connected(ctx, fake) do
    eventually(fn -> FakeDataPlane.connected?(fake) and Plane.connected?(ctx.dp.id) end)
  end

  # The create flow of doc 13 §6.1 over the real stream: the control plane asks the
  # data plane for an overlay, then writes the row with the ids it was given.
  defp open_branch(ctx, fake) do
    branch_id = Ecto.UUID.generate()

    instruction = %V1.Instruction{
      body:
        {:initialise_overlay,
         %V1.InitialiseOverlay{branch_id: branch_id, target_id: ctx.target.id}}
    }

    {:ok, %{ok: true, body: {:overlay_initialised, %{overlay_id: overlay_id}}}} =
      Plane.send_instruction(ctx.org.id, ctx.dp.id, instruction)

    assert FakeDataPlane.overlay(fake, branch_id).overlay_id == overlay_id
    branch = branch(ctx.org, ctx.target, ctx.owner, id: branch_id, overlay_id: overlay_id)

    # Step 7 of the create flow: the routing entry, so the proxy can resolve the branch.
    route = %V1.RoutingUpsert{branch_id: branch_id, overlay_id: overlay_id, state: :AUTH_OPEN}

    {:ok, %{ok: true}} =
      Plane.send_instruction(ctx.org.id, ctx.dp.id, %V1.Instruction{
        body: {:routing_upsert, route}
      })

    branch
  end

  test "a data plane that dials in is recorded as connected", ctx do
    fake = start_fake(ctx)
    connected(ctx, fake)

    eventually(fn ->
      Ash.get!(DataPlane, ctx.dp.id, tenant: ctx.org.id, authorize?: false).last_session_at
    end)
  end

  test "an instruction goes down the stream and its result comes back to the caller", ctx do
    fake = start_fake(ctx)
    connected(ctx, fake)

    branch = open_branch(ctx, fake)
    assert %{believed: :open} = FakeDataPlane.overlay(fake, branch.id)

    assert [
             %V1.Instruction{body: {:initialise_overlay, _}},
             %V1.Instruction{body: {:routing_upsert, _}}
           ] =
             FakeDataPlane.received(fake)
  end

  test "a heartbeat reaches the branch coordinator and the reply reaches the data plane's matrix",
       ctx do
    fake = start_fake(ctx)
    connected(ctx, fake)
    branch = open_branch(ctx, fake)

    {:ok, _} = BranchProcess.transition(ctx.org.id, branch.id, :propose)
    assert FakeDataPlane.heartbeat(fake) == 1

    # proposed in the control plane, open in the data plane: the reply freezes it (doc 13 §6.8).
    eventually(fn -> FakeDataPlane.overlay(fake, branch.id).frozen end)
    assert %{believed: :proposed, freeze_marker: true} = FakeDataPlane.overlay(fake, branch.id)
    assert {:error, :branch_frozen} = FakeDataPlane.write(fake, branch.id)

    assert [%{authoritative: :proposed, new_believed: :proposed}] = FakeDataPlane.reactions(fake)
  end

  test "an orphan overlay is told UNKNOWN over the wire and garbage-collected", ctx do
    fake = start_fake(ctx)
    connected(ctx, fake)

    orphan = Ecto.UUID.generate()

    Plane.send_instruction(ctx.org.id, ctx.dp.id, %V1.Instruction{
      body:
        {:initialise_overlay, %V1.InitialiseOverlay{branch_id: orphan, target_id: ctx.target.id}}
    })

    # No branch row was ever written for it.

    FakeDataPlane.heartbeat(fake)
    eventually(fn -> FakeDataPlane.overlay(fake, orphan) == nil end)
  end

  test "a lost base snapshot reported over the stream abandons the branch (doc 13 §6.2 f3)",
       ctx do
    fake = start_fake(ctx)
    connected(ctx, fake)
    branch = open_branch(ctx, fake)

    FakeDataPlane.lose_base_snapshot(fake, branch.id)
    FakeDataPlane.heartbeat(fake)

    eventually(fn ->
      Ash.get!(Branch, branch.id, tenant: ctx.org.id, authorize?: false).state == :abandoned
    end)

    assert Ash.get!(Branch, branch.id, tenant: ctx.org.id, authorize?: false).reason ==
             :snapshot_lost

    eventually(fn -> FakeDataPlane.overlay(fake, branch.id).terminal == :abandoned end)
  end

  describe "the stream goes down" do
    test "an instruction sent meanwhile waits, and is delivered once the data plane reconnects",
         ctx do
      fake = start_fake(ctx)
      connected(ctx, fake)

      FakeDataPlane.disconnect(fake)
      eventually(fn -> not Plane.connected?(ctx.dp.id) end)

      branch_id = Ecto.UUID.generate()

      instruction = %V1.Instruction{
        body:
          {:initialise_overlay,
           %V1.InitialiseOverlay{branch_id: branch_id, target_id: ctx.target.id}}
      }

      task =
        Task.async(fn ->
          Plane.send_instruction(ctx.org.id, ctx.dp.id, instruction, deadline_ms: 10_000)
        end)

      eventually(fn -> Plane.pending(ctx.dp.id) != [] end)

      FakeDataPlane.reconnect(fake)
      assert {:ok, %{ok: true, body: {:overlay_initialised, _}}} = Task.await(task, 10_000)
      assert FakeDataPlane.overlay(fake, branch_id)
    end

    test "a re-sent instruction carries the original id", ctx do
      fake = start_fake(ctx)
      connected(ctx, fake)
      FakeDataPlane.script(fake, :initialise_overlay, :drop)

      instruction = %V1.Instruction{
        instruction_id: "fixed-id",
        body:
          {:initialise_overlay, %V1.InitialiseOverlay{branch_id: "b1", target_id: ctx.target.id}}
      }

      {:ok, "fixed-id"} =
        Plane.send_async(ctx.org.id, ctx.dp.id, instruction, deadline_ms: 10_000)

      eventually(fn -> length(FakeDataPlane.received(fake)) == 1 end)

      # The data plane lost it; after a reconnect the control plane sends the same one again.
      FakeDataPlane.disconnect(fake)
      eventually(fn -> not Plane.connected?(ctx.dp.id) end)
      FakeDataPlane.reconnect(fake)

      assert_receive {:instruction_result, "fixed-id", {:ok, %{ok: true}}}, 5_000

      assert Enum.map(FakeDataPlane.received(fake), & &1.instruction_id) == [
               "fixed-id",
               "fixed-id"
             ]
    end

    test "an instruction nobody answers times out at its deadline", ctx do
      fake = start_fake(ctx)
      connected(ctx, fake)
      FakeDataPlane.script(fake, :freeze_writes, :drop)

      instruction = %V1.Instruction{
        body: {:freeze_writes, %V1.FreezeWrites{branch_id: "b1", overlay_id: "o1"}}
      }

      assert {:error, :timeout} =
               Plane.send_instruction(ctx.org.id, ctx.dp.id, instruction, deadline_ms: 100)
    end
  end

  describe "who may connect" do
    test "an unknown data plane is refused", ctx do
      fake = start_fake(ctx, id: Ecto.UUID.generate())
      Process.sleep(200)
      FakeDataPlane.heartbeat(fake)
      eventually(fn -> not FakeDataPlane.connected?(fake) end)
    end

    test "a second stream for the same identity supersedes the first", ctx do
      first = start_fake(ctx)
      connected(ctx, first)

      second = start_fake(ctx)
      eventually(fn -> not FakeDataPlane.connected?(first) end)
      eventually(fn -> FakeDataPlane.connected?(second) and Plane.connected?(ctx.dp.id) end)

      # Instructions now go to the second.
      branch_id = Ecto.UUID.generate()

      instruction = %V1.Instruction{
        body:
          {:initialise_overlay,
           %V1.InitialiseOverlay{branch_id: branch_id, target_id: ctx.target.id}}
      }

      assert {:ok, %{ok: true}} = Plane.send_instruction(ctx.org.id, ctx.dp.id, instruction)
      assert FakeDataPlane.overlay(second, branch_id)
      assert FakeDataPlane.overlay(first, branch_id) == nil
    end

    test "a message naming another data plane closes the stream (doc 10 §5)", ctx do
      other = data_plane(ctx.org)
      # Dialled as `other` (the header), but its messages say `ctx.dp.id`.
      fake = start_fake(ctx, identity_header: other.id)
      eventually(fn -> Plane.connected?(other.id) end)

      FakeDataPlane.inject(
        fake,
        {:heartbeat,
         %V1.Heartbeat{
           branch_id: Ecto.UUID.generate(),
           overlay_id: Ecto.UUID.generate(),
           believed_state: :OPEN
         }}
      )

      eventually(fn -> not FakeDataPlane.connected?(fake) end)
      eventually(fn -> not Plane.connected?(other.id) end)
    end
  end

  describe "limits" do
    test "a message over 1 MiB closes the stream and is counted (doc 10 §5)", ctx do
      handler = {__MODULE__, make_ref()}
      parent = self()

      :telemetry.attach(
        handler,
        [:steward, :plane, :oversize],
        fn _, m, _, _ -> send(parent, {:oversize, m.bytes}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      fake = start_fake(ctx)
      connected(ctx, fake)

      big = %V1.ChangesetReport{
        changeset_id: "c1",
        evidence_tables_read: [String.duplicate("x", 1_100_000)]
      }

      FakeDataPlane.inject(fake, {:changeset_report, big})

      assert_receive {:oversize, bytes}, 5_000
      assert bytes > 1_048_576
      eventually(fn -> not FakeDataPlane.connected?(fake) end)
    end

    test "a message just under the limit is accepted", ctx do
      fake = start_fake(ctx)
      connected(ctx, fake)

      fine = %V1.ChangesetReport{
        changeset_id: "c1",
        evidence_tables_read: [String.duplicate("x", 1_000_000)]
      }

      FakeDataPlane.inject(fake, {:changeset_report, fine})
      Process.sleep(200)
      assert FakeDataPlane.connected?(fake)
    end
  end

  test "an audit event sent over the stream is written to audit_log", ctx do
    fake = start_fake(ctx)
    connected(ctx, fake)

    event = %V1.DataPlaneAuditEvent{
      merge_id: Ecto.UUID.generate(),
      changeset_id: Ecto.UUID.generate(),
      action: "row_delta.read",
      principal_id: principal(ctx.org, :human).id,
      at: Steward.FakeDataPlane.Fixtures.timestamp()
    }

    FakeDataPlane.inject(fake, {:audit_event, event})

    rows =
      eventually(fn ->
        (r = Ash.read!(AuditLog, tenant: ctx.org.id, actor: System.new(:api, ctx.org.id))) != [] &&
          r
      end)

    assert [%{action: "row_delta.read", data_plane_id: dp_id}] = rows
    assert dp_id == ctx.dp.id
  end
end
