defmodule Notifiq.Channels.ProviderContractCase do
  @moduledoc """
  Shared contract suite for `Notifiq.Channels.Provider` implementations (Spec 004, AC-6).

  Every provider, including the real ones, must run it:

      defmodule Notifiq.Channels.MyProviderContractTest do
        use Notifiq.Channels.ProviderContractCase,
          provider: Notifiq.Channels.My,
          valid_message: %Notifiq.Channels.OutboundMessage{...},
          credentials: %{api_key: "test"},
          error_message: %Notifiq.Channels.OutboundMessage{...}
      end

  `error_message` is optional: a message that makes the provider fail (against a stub of
  the provider's API), used to check the error is classified. `credentials` defaults to
  `%{}`. Real providers must never reach the network: pass `setup: {Module, :function}`
  to install the stub (e.g. `Req.Test.stub/2`) in each test process before it runs.
  """

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      use ExUnit.Case, async: true

      alias Notifiq.Channels.OutboundMessage
      alias Notifiq.Channels.Provider
      alias Notifiq.Channels.SendReceipt

      @provider Keyword.fetch!(opts, :provider)
      @valid_message Keyword.fetch!(opts, :valid_message)
      @error_message Keyword.get(opts, :error_message)
      @credentials Keyword.get(opts, :credentials, %{})
      @setup_hook Keyword.get(opts, :setup)

      setup do
        case @setup_hook do
          {module, function} -> apply(module, function, [])
          nil -> :ok
        end

        :ok
      end

      test "declares the Provider behaviour and implements all callbacks" do
        assert Code.ensure_loaded?(@provider)
        assert Provider in Keyword.get(@provider.module_info(:attributes), :behaviour, [])

        for {fun, arity} <- [provider_key: 0, supported_channels: 0, send_message: 2] do
          assert function_exported?(@provider, fun, arity), "missing #{fun}/#{arity}"
        end
      end

      test "provider_key/0 is a snake_case atom" do
        key = @provider.provider_key()
        assert is_atom(key)
        assert Atom.to_string(key) =~ ~r/^[a-z][a-z0-9_]*$/
      end

      test "supported_channels/0 is a non-empty subset of the known channels" do
        channels = @provider.supported_channels()
        assert is_list(channels) and channels != []
        assert channels -- OutboundMessage.channels() == []
      end

      test "the valid message uses a channel the provider supports" do
        assert @valid_message.channel in @provider.supported_channels()
        assert :ok = OutboundMessage.validate(@valid_message)
      end

      test "send_message/2 returns a well-formed receipt" do
        assert {:ok, %SendReceipt{} = receipt} =
                 @provider.send_message(@valid_message, @credentials)

        assert receipt.provider == Atom.to_string(@provider.provider_key())
        assert is_binary(receipt.provider_message_id) and receipt.provider_message_id != ""
        assert receipt.status in SendReceipt.statuses()
        assert is_map(receipt.raw)
      end

      if @error_message do
        test "send_message/2 classifies failures as {class, atom_reason}" do
          assert {:error, {class, reason}} = @provider.send_message(@error_message, @credentials)
          assert class in [:retryable, :permanent, :uncertain]
          assert is_atom(reason)
        end
      end
    end
  end
end
