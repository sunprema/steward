defmodule StewardWeb.Plane.Identity do
  @moduledoc """
  Who is on the other end of a `Session.Connect` stream (doc 10 §3.4, doc 14
  §3.1, doc 15 §4.2).

  **`:cert` (production).** The client certificate was verified against the
  enrolment CA by the TLS layer. Its SAN is the `data_plane_id`; the id must be a
  known `data_planes` row, and the certificate's serial must be the row's
  `cert_serial`, so rotating or revoking an identity is writing a new serial.
  The serial is compared as lower-case hex (the form `openssl x509 -serial`
  prints) or decimal.

  **`:header` (local development and tests only).** The id is read from the
  `x-steward-data-plane-id` request header and trusted, because
  `tools/stack` runs the control plane without a certificate authority. It still
  has to be a known data plane. Production configuration refuses this mode
  (`config/runtime.exs`).

  Either way the result carries the owning org, found from the data plane
  (`Steward.Coordinator.Plane.Directory`), so every later read is tenant-scoped.
  """
  alias Steward.Coordinator.Plane.Directory

  @header "x-steward-data-plane-id"

  @type result ::
          {:ok, %{data_plane_id: String.t(), org_id: String.t()}}
          | {:error, :unauthenticated | :permission_denied}

  @doc "Resolves the identity of a server stream. `mode` is `:cert` or `:header`."
  @spec resolve(GRPC.Server.Stream.t(), :cert | :header) :: result
  def resolve(stream, mode) do
    with {:ok, claimed, serial} <- claim(stream, mode),
         {:ok, %{org_id: org_id, cert_serial: row_serial}} <-
           Directory.lookup(claimed) |> or_denied(),
         :ok <- check_serial(mode, serial, row_serial) do
      {:ok, %{data_plane_id: claimed, org_id: org_id}}
    end
  end

  defp or_denied(:error), do: {:error, :permission_denied}
  defp or_denied(ok), do: ok

  defp claim(stream, :header) do
    case stream |> GRPC.Stream.get_headers() |> Map.get(@header) do
      nil -> {:error, :unauthenticated}
      id -> {:ok, id, nil}
    end
  end

  defp claim(stream, :cert) do
    with der when is_binary(der) <- stream.adapter.get_cert(stream.payload),
         {:ok, id, serial} <- parse(der) do
      {:ok, id, serial}
    else
      _ -> {:error, :unauthenticated}
    end
  end

  @doc false
  # The data-plane id (the SAN that is a UUID) and the serial of a DER certificate.
  def parse(der) do
    otp = :public_key.pkix_decode_cert(der, :otp)
    tbs = elem(otp, 1)
    serial = elem(tbs, 2)

    sans =
      for ext <- elem(tbs, 10) |> List.wrap(),
          elem(ext, 1) == {2, 5, 29, 17},
          {kind, value} <- elem(ext, 3),
          kind in [:dNSName, :uniformResourceIdentifier],
          do: List.to_string(value)

    case Enum.find_value(sans, &uuid/1) do
      nil -> :error
      id -> {:ok, id, serial}
    end
  rescue
    _ -> :error
  end

  defp uuid(value) do
    value = value |> String.split("/") |> List.last()

    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp check_serial(:header, _serial, _row), do: :ok

  defp check_serial(:cert, serial, row_serial) when is_integer(serial) do
    if String.downcase(row_serial) in [
         Integer.to_string(serial, 16) |> String.downcase(),
         Integer.to_string(serial)
       ],
       do: :ok,
       else: {:error, :permission_denied}
  end

  defp check_serial(:cert, _, _), do: {:error, :unauthenticated}
end
