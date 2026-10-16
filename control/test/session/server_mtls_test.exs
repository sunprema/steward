defmodule StewardWeb.Plane.ServerMtlsTest do
  @moduledoc """
  Identity by client certificate (doc 10 §3.4, doc 14 §3.1, doc 15 §4.2): the
  listener requires and verifies a client certificate; its SAN is the
  `data_plane_id`, and its serial must be the one recorded for that data plane.
  Certificates are generated in-process with `:public_key.pkix_test_data/1`.
  """
  use Steward.CoordinatorCase

  alias Steward.Coordinator.Plane
  alias Steward.FakeDataPlane
  alias StewardWeb.Plane.Identity

  @san_oid {2, 5, 29, 17}

  # The one data-plane identity the listener's CA has issued. Rows are rolled back
  # per test, so every test may insert this id.
  @dp_id "0a1b2c3d-0000-4000-8000-00000000d0d0"

  setup_all do
    dir =
      Path.join(
        Elixir.System.tmp_dir!(),
        "steward-mtls-#{Elixir.System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)

    pair = pair(@dp_id)

    files = [
      certfile:
        write_pem(dir, "server.pem", [{:Certificate, pair.server_config[:cert], :not_encrypted}]),
      keyfile: write_pem(dir, "server.key", [key_entry(pair.server_config[:key])]),
      # What the listener trusts to have issued data-plane identities.
      cacertfile:
        write_pem(
          dir,
          "ca.pem",
          for(c <- pair.server_config[:cacerts], do: {:Certificate, c, :not_encrypted})
        )
    ]

    port = free_port()
    previous = Application.get_env(:steward, StewardWeb.Plane, [])
    Application.put_env(:steward, StewardWeb.Plane, Keyword.put(previous, :identity, :cert))
    on_exit(fn -> Application.put_env(:steward, StewardWeb.Plane, previous) end)

    start_supervised!(
      {GRPC.Server.Supervisor, StewardWeb.Plane.supervisor_opts(port: port, tls: files)}
    )

    client = pair.client_config
    {:ok, @dp_id, serial} = Identity.parse(client[:cert])

    %{
      address: "127.0.0.1:#{port}",
      trusted: %{cert: client[:cert], key: client[:key], serial: serial}
    }
  end

  setup do
    %{org: org()}
  end

  # RSA: the default EC test keys are not acceptable to the TLS 1.3 handshake here.
  @rsa [key: {:rsa, 2048, 17}]

  # A server chain and a client chain whose peer certificate carries `san`.
  defp pair(san), do: pair_with([{:dNSName, String.to_charlist(san)}])

  defp pair_with(san_entries) do
    ext = {:Extension, @san_oid, false, san_entries}

    :public_key.pkix_test_data(%{
      server_chain: %{root: @rsa, peer: @rsa},
      client_chain: %{root: @rsa, peer: [{:extensions, [ext]} | @rsa]}
    })
  end

  defp dial(ctx, id, identity) do
    cred =
      GRPC.Credential.new(ssl: [cert: identity.cert, key: identity.key, verify: :verify_none])

    {:ok, fake} =
      FakeDataPlane.start_link(data_plane_id: id, transport: {:grpc, ctx.address, cred: cred})

    on_exit(fn -> if Process.alive?(fake), do: GenServer.stop(fake) end)
    fake
  end

  defp hex(serial), do: serial |> Integer.to_string(16) |> String.downcase()

  test "a certificate whose SAN is a data plane with a matching serial opens the stream", ctx do
    data_plane(ctx.org, id: @dp_id, cert_serial: hex(ctx.trusted.serial))

    fake = dial(ctx, @dp_id, ctx.trusted)
    eventually(fn -> FakeDataPlane.connected?(fake) and Plane.connected?(@dp_id) end)
  end

  test "the serial may be recorded in decimal", ctx do
    data_plane(ctx.org, id: @dp_id, cert_serial: Integer.to_string(ctx.trusted.serial))

    fake = dial(ctx, @dp_id, ctx.trusted)
    eventually(fn -> Plane.connected?(@dp_id) end)
    assert FakeDataPlane.connected?(fake)
  end

  test "a valid certificate whose serial is not the recorded one is refused (a revoked or rotated identity)",
       ctx do
    data_plane(ctx.org, id: @dp_id, cert_serial: "0badc0de")

    fake = dial(ctx, @dp_id, ctx.trusted)
    Process.sleep(300)
    refute Plane.connected?(@dp_id)
    FakeDataPlane.heartbeat(fake)
    eventually(fn -> not FakeDataPlane.connected?(fake) end)
  end

  test "a certificate for a data plane that does not exist is refused", ctx do
    fake = dial(ctx, @dp_id, ctx.trusted)
    Process.sleep(300)
    refute Plane.connected?(@dp_id)
    eventually(fn -> not FakeDataPlane.connected?(fake) end)
  end

  test "a certificate from a CA the listener does not trust cannot connect", ctx do
    stranger = pair(@dp_id).client_config
    {:ok, _, serial} = Identity.parse(stranger[:cert])
    data_plane(ctx.org, id: @dp_id, cert_serial: hex(serial))

    fake = dial(ctx, @dp_id, %{cert: stranger[:cert], key: stranger[:key]})
    Process.sleep(300)
    refute Plane.connected?(@dp_id)
    refute FakeDataPlane.connected?(fake)
  end

  test "no client certificate at all cannot connect", ctx do
    data_plane(ctx.org, id: @dp_id, cert_serial: hex(ctx.trusted.serial))

    {:ok, fake} =
      FakeDataPlane.start_link(
        data_plane_id: @dp_id,
        transport: {:grpc, ctx.address, cred: GRPC.Credential.new(ssl: [verify: :verify_none])}
      )

    on_exit(fn -> if Process.alive?(fake), do: GenServer.stop(fake) end)
    Process.sleep(300)
    refute Plane.connected?(@dp_id)
  end

  test "the header is not an identity when certificates are required", ctx do
    other = data_plane(ctx.org)
    data_plane(ctx.org, id: @dp_id, cert_serial: hex(ctx.trusted.serial))

    # The certificate names @dp_id; the header claiming `other` must not change who this is.
    {:ok, fake} =
      FakeDataPlane.start_link(
        data_plane_id: @dp_id,
        transport:
          {:grpc, ctx.address,
           identity_header: other.id,
           cred:
             GRPC.Credential.new(
               ssl: [cert: ctx.trusted.cert, key: ctx.trusted.key, verify: :verify_none]
             )}
      )

    on_exit(fn -> if Process.alive?(fake), do: GenServer.stop(fake) end)
    eventually(fn -> Plane.connected?(@dp_id) end)
    refute Plane.connected?(other.id)
  end

  describe "Identity.parse/1" do
    test "reads the UUID SAN and the serial", ctx do
      assert {:ok, @dp_id, serial} = Identity.parse(ctx.trusted.cert)
      assert serial == ctx.trusted.serial
    end

    test "a URI SAN carrying the id as its last segment is accepted too" do
      dp_id = Ecto.UUID.generate()

      ext =
        {:Extension, @san_oid, false,
         [{:uniformResourceIdentifier, String.to_charlist("steward://data-plane/#{dp_id}")}]}

      client =
        :public_key.pkix_test_data(%{
          server_chain: %{root: [], peer: []},
          client_chain: %{root: [], peer: [extensions: [ext]]}
        }).client_config

      assert {:ok, ^dp_id, _} = Identity.parse(client[:cert])
    end

    test "a certificate without a UUID SAN is not an identity" do
      client =
        :public_key.pkix_test_data(%{
          server_chain: %{root: [], peer: []},
          client_chain: %{root: [], peer: []}
        }).client_config

      assert :error = Identity.parse(client[:cert])
    end

    test "garbage is not an identity" do
      assert :error = Identity.parse("not a certificate")
    end
  end

  # --- certificate plumbing ----------------------------------------------------

  defp key_entry({type, der}), do: {type, der, :not_encrypted}

  defp write_pem(dir, name, entries) do
    path = Path.join(dir, name)
    File.write!(path, :public_key.pem_encode(entries))
    path
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
