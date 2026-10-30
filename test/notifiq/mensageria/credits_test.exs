defmodule Notifiq.Mensageria.CreditsTest do
  use Notifiq.DataCase, async: true

  import Notifiq.Test.MensageriaHelpers

  alias Notifiq.Channels.SendReceipt
  alias Notifiq.Mensageria
  alias Notifiq.Mensageria.MessageLog

  describe "add_credits/3 (AC-14)" do
    test "adds to the balance and writes the ledger entry together" do
      tenant = tenant!(0)

      assert {:ok, 10} = Mensageria.add_credits(tenant.id, 10)
      assert {:ok, 15} = Mensageria.add_credits(tenant.id, 5, "adjustment")

      assert [adjustment, purchase] = Mensageria.list_credit_transactions(tenant.id)
      assert {purchase.amount, purchase.reason, purchase.message_log_id} == {10, "purchase", nil}
      assert {adjustment.amount, adjustment.reason} == {5, "adjustment"}
      assert_invariant!(tenant.id)
    end

    test "rejects amounts that are not positive integers" do
      tenant = tenant!(3)

      for amount <- [0, -5, 1.5, "10", nil] do
        assert {:error, :invalid_amount} = Mensageria.add_credits(tenant.id, amount)
      end

      assert balance(tenant) == 3
      assert ledger_count(tenant.id) == 1
    end

    test "rejects reasons reserved for dispatches" do
      tenant = tenant!(3)

      for reason <- ["dispatch", "refund", "free money"] do
        assert {:error, :invalid_reason} = Mensageria.add_credits(tenant.id, 5, reason)
      end

      assert balance(tenant) == 3
    end

    test "an unknown tenant gets nothing" do
      assert {:error, :unknown_tenant} = Mensageria.add_credits(Ecto.UUID.generate(), 5)
    end
  end

  describe "invariant over random operation sequences (AC-12)" do
    @operations 250

    test "balance never goes negative and always equals the ledger sum" do
      :rand.seed(:exsss, {101, 202, 303})

      tenant = tenant!(4)
      receipt = %SendReceipt{provider: "fake_sms", provider_message_id: "SM1", status: :queued}

      outcomes = [
        {:ok, receipt},
        {:error, {:retryable, :rate_limited}},
        {:error, {:uncertain, :timeout}},
        {:error, {:permanent, :invalid_number}}
      ]

      final =
        Enum.reduce(1..@operations, [], fn _step, logs ->
          logs =
            case :rand.uniform(5) do
              1 -> reserve_random(tenant, logs)
              2 -> reserve_random(tenant, logs)
              3 -> record_random(logs, Enum.random(outcomes))
              4 -> give_up_random(logs)
              5 -> top_up(tenant, logs)
            end

          assert_invariant!(tenant.id)
          logs
        end)

      assert length(final) > 10, "the run should have exercised many dispatches"
      assert balance(tenant) >= 0
    end

    defp reserve_random(tenant, logs) do
      cost = Enum.random([1, 1, 1, 2, 3])

      case Mensageria.reserve(reservation(tenant, event!(tenant), %{cost: cost})) do
        {:ok, log} -> [log | logs]
        {:error, :insufficient_credits} -> logs
      end
    end

    defp record_random([], _outcome), do: []

    defp record_random(logs, outcome) do
      index = :rand.uniform(length(logs)) - 1
      log = Enum.at(logs, index)

      case Mensageria.record_outcome(log, outcome) do
        {:ok, %MessageLog{} = updated} -> List.replace_at(logs, index, updated)
        {:error, :already_final} -> logs
      end
    end

    defp give_up_random([]), do: []

    defp give_up_random(logs) do
      index = :rand.uniform(length(logs)) - 1

      case Mensageria.give_up(Enum.at(logs, index), :random) do
        {:ok, %MessageLog{} = updated} -> List.replace_at(logs, index, updated)
        {:error, :already_final} -> logs
      end
    end

    defp top_up(tenant, logs) do
      {:ok, _balance} = Mensageria.add_credits(tenant.id, Enum.random([1, 2, 5]))
      logs
    end
  end
end
