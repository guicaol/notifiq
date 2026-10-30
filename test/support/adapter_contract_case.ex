defmodule Notifiq.Integrations.AdapterContractCase do
  @moduledoc """
  Shared contract suite for `Notifiq.Integrations.Source` adapters (Spec 002, AC-6).

  Every adapter, including the real ones, must run it:

      defmodule Notifiq.Integrations.MyAdapterContractTest do
        use Notifiq.Integrations.AdapterContractCase,
          adapter: Notifiq.Integrations.My,
          valid_payload: %{...},
          valid_headers: [{"x-signature", "ok"}],
          invalid_headers: [{"x-signature", "bad"}],
          ignored_payload: %{...}
      end

  `invalid_headers` and `ignored_payload` are optional; their checks are skipped
  when omitted. `credentials` defaults to `%{}`.

  For adapters that need more than headers on the conn (e.g. a signature over
  `conn.assigns.raw_body`), pass `conn_builder: {Module, :function}`; it is called
  with `:valid` or `:invalid` and must return the conn to verify.
  """

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      use ExUnit.Case, async: true

      alias Notifiq.Integrations.Source
      alias Notifiq.Mensageria.CanonicalEvent

      @adapter Keyword.fetch!(opts, :adapter)
      @valid_payload Keyword.fetch!(opts, :valid_payload)
      @valid_headers Keyword.get(opts, :valid_headers, [])
      @invalid_headers Keyword.get(opts, :invalid_headers)
      @ignored_payload Keyword.get(opts, :ignored_payload)
      @credentials Keyword.get(opts, :credentials, %{})
      @conn_builder Keyword.get(opts, :conn_builder)

      defp build_conn_with(headers) do
        Enum.reduce(headers, Phoenix.ConnTest.build_conn(), fn {key, value}, conn ->
          Plug.Conn.put_req_header(conn, key, value)
        end)
      end

      defp conn_for(kind, headers) do
        case @conn_builder do
          {module, function} -> apply(module, function, [kind])
          nil -> build_conn_with(headers)
        end
      end

      test "declares the Source behaviour and implements all callbacks" do
        assert Code.ensure_loaded?(@adapter)
        assert Source in Keyword.get(@adapter.module_info(:attributes), :behaviour, [])

        for {fun, arity} <- [
              source_key: 0,
              verify_authenticity: 2,
              extract_event_id: 1,
              extract_account_id: 1,
              metadata: 0,
              parse: 1
            ] do
          assert function_exported?(@adapter, fun, arity), "missing #{fun}/#{arity}"
        end
      end

      test "metadata/0 names the source and its account field for the panel (Spec 010)" do
        assert %{name: name, account_label: label} = @adapter.metadata()
        assert is_binary(name) and String.trim(name) != ""
        assert is_binary(label) and String.trim(label) != ""
        assert @adapter.metadata() == @adapter.metadata()
      end

      test "source_key/0 is a snake_case atom" do
        key = @adapter.source_key()
        assert is_atom(key)
        assert Atom.to_string(key) =~ ~r/^[a-z][a-z0-9_]*$/
      end

      test "verify_authenticity/2 accepts a valid request" do
        conn = conn_for(:valid, @valid_headers)
        assert :ok = @adapter.verify_authenticity(conn, @credentials)
      end

      if @invalid_headers || @conn_builder do
        test "verify_authenticity/2 rejects an invalid request with an error atom" do
          conn = conn_for(:invalid, @invalid_headers)
          assert {:error, reason} = @adapter.verify_authenticity(conn, @credentials)
          assert is_atom(reason)
        end
      end

      test "extract_event_id/1 returns a stable string" do
        id = @adapter.extract_event_id(@valid_payload)
        assert is_binary(id) and id != ""
        assert id == @adapter.extract_event_id(@valid_payload)
      end

      test "extract_account_id/1 returns the source account, or :error without one" do
        assert {:ok, account} = @adapter.extract_account_id(@valid_payload)
        assert is_binary(account) and account != ""
        assert account == elem(@adapter.extract_account_id(@valid_payload), 1)

        assert :error = @adapter.extract_account_id(%{})
        assert :error = @adapter.extract_account_id(%{"unrelated" => 1})
      end

      test "parse/1 returns a well-formed canonical event" do
        assert {:ok, %CanonicalEvent{} = event} = @adapter.parse(@valid_payload)

        assert event.schema_version == CanonicalEvent.schema_version()
        assert event.source == Atom.to_string(@adapter.source_key())
        assert event.external_event_id == @adapter.extract_event_id(@valid_payload)
        assert is_binary(event.event_type) and event.event_type != ""
        assert event.recipient.phone =~ ~r/^\+[1-9][0-9]{7,14}$/
        assert is_map(event.context)
        assert is_map(event.raw)
      end

      if @ignored_payload do
        test "parse/1 returns {:ok, :ignore} for events that must not notify" do
          assert {:ok, :ignore} = @adapter.parse(@ignored_payload)
        end
      end
    end
  end
end
