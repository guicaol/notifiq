defmodule Notifiq.Mensageria.PagingTest do
  # Spec 011, AC-15: the pages behind the history and the statement.
  use Notifiq.DataCase, async: true

  import Ecto.Query
  import Notifiq.Test.MensageriaHelpers

  alias Notifiq.Mensageria
  alias Notifiq.Mensageria.MessageLog
  alias Notifiq.Repo
  alias Notifiq.Tenants.Tenant

  defp ids(logs), do: Enum.map(logs, & &1.id)

  # Walks every page and returns what each one held, in order.
  defp pages(fun, opts \\ []) do
    Stream.unfold({:first, nil}, fn
      :done ->
        nil

      {_state, cursor} ->
        {rows, next} = fun.(Keyword.put(opts, :cursor, cursor))
        {rows, if(next, do: {:more, next}, else: :done)}
    end)
    |> Enum.to_list()
  end

  defp stamp!(log, datetime) do
    Repo.update_all(from(l in MessageLog, where: l.id == ^log.id), set: [inserted_at: datetime])
  end

  describe "page_message_logs/2" do
    test "lists only the tenant's logs, newest first, with no cursor when everything fits" do
      tenant = tenant!(10)
      other = tenant!(10)
      old = reserve!(tenant)
      new = reserve!(tenant)
      stamp!(old, ~U[2026-10-01 10:00:00.000000Z])
      stamp!(new, ~U[2026-10-02 10:00:00.000000Z])
      reserve!(other)

      assert {logs, nil} = Mensageria.page_message_logs(tenant.id)
      assert ids(logs) == [new.id, old.id]
    end

    test "walks the pages without repeating or skipping anything" do
      tenant = tenant!(20)
      logs = for _ <- 1..7, do: reserve!(tenant)

      logs
      |> Enum.with_index()
      |> Enum.each(fn {log, index} ->
        stamp!(log, DateTime.add(~U[2026-10-01 00:00:00.000000Z], index * 60))
      end)

      walked = pages(&Mensageria.page_message_logs(tenant.id, [limit: 3] ++ &1))

      assert Enum.map(walked, &length/1) == [3, 3, 1]
      assert walked |> List.flatten() |> ids() == logs |> Enum.reverse() |> ids()
    end

    test "logs that share a timestamp are neither repeated nor lost across a page edge" do
      tenant = tenant!(20)
      logs = for _ <- 1..5, do: reserve!(tenant)
      Enum.each(logs, &stamp!(&1, ~U[2026-10-01 12:00:00.000000Z]))

      walked =
        pages(&Mensageria.page_message_logs(tenant.id, [limit: 2] ++ &1))
        |> List.flatten()
        |> ids()

      assert length(walked) == 5
      assert Enum.sort(walked) == Enum.sort(ids(logs))
    end

    test "a log that arrives while paging doesn't shift the older pages" do
      tenant = tenant!(20)
      logs = for _ <- 1..4, do: reserve!(tenant)

      logs
      |> Enum.with_index()
      |> Enum.each(fn {log, index} ->
        stamp!(log, DateTime.add(~U[2026-10-01 00:00:00.000000Z], index * 60))
      end)

      {first, cursor} = Mensageria.page_message_logs(tenant.id, limit: 2)
      newest = reserve!(tenant)
      {second, nil} = Mensageria.page_message_logs(tenant.id, limit: 2, cursor: cursor)

      assert ids(first) ++ ids(second) == logs |> Enum.reverse() |> ids()
      refute newest.id in (ids(first) ++ ids(second))
    end

    test "filters by status" do
      tenant = tenant!(10)
      sent = reserve!(tenant)
      failed = reserve!(tenant)
      pending = reserve!(tenant)

      Repo.update_all(from(l in MessageLog, where: l.id == ^sent.id), set: [status: "sent"])
      Repo.update_all(from(l in MessageLog, where: l.id == ^failed.id), set: [status: "failed"])

      assert {[only], nil} = Mensageria.page_message_logs(tenant.id, statuses: ["sent"])
      assert only.id == sent.id

      {both, nil} = Mensageria.page_message_logs(tenant.id, statuses: ["failed", "pending"])
      assert Enum.sort(ids(both)) == Enum.sort([failed.id, pending.id])

      assert {[], nil} = Mensageria.page_message_logs(tenant.id, statuses: ["unconfirmed"])
    end

    test "the tenant filter holds with a cursor too" do
      mine = tenant!(10)
      theirs = tenant!(10)
      mine_log = reserve!(mine)
      reserve!(theirs)

      cursor = {DateTime.add(DateTime.utc_now(), 3_600), Ecto.UUID.generate()}
      {logs, nil} = Mensageria.page_message_logs(mine.id, cursor: cursor)

      assert ids(logs) == [mine_log.id]
    end

    test "the limit is at least 1 and at most 100" do
      tenant = tenant!(150)
      for _ <- 1..101, do: reserve!(tenant)

      assert {[_one], cursor} = Mensageria.page_message_logs(tenant.id, limit: 0)
      assert cursor
      assert {hundred, cursor} = Mensageria.page_message_logs(tenant.id, limit: 10_000)
      assert length(hundred) == 100
      assert cursor
    end
  end

  describe "page_credit_transactions/2" do
    test "the newest entry's balance is the tenant's balance and every row follows the next" do
      tenant = tenant!(10)
      log = reserve!(tenant)
      {:ok, _failed} = Mensageria.give_up(log, :stale)
      reserve!(tenant)
      {:ok, _balance} = Mensageria.add_credits(tenant.id, 5, "purchase")

      {entries, nil} = Mensageria.page_credit_transactions(tenant.id)

      assert hd(entries).balance_after == Mensageria.credit_balance(tenant.id)

      entries
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [above, below] ->
        assert above.balance_after - above.transaction.amount == below.balance_after
      end)

      # Everything the ledger holds, newest first.
      assert Enum.map(entries, & &1.transaction.seq) ==
               entries |> Enum.map(& &1.transaction.seq) |> Enum.sort(:desc)
    end

    test "pages carry the same balances as one big page" do
      tenant = tenant!(30)
      for _ <- 1..6, do: reserve!(tenant)

      {all, nil} = Mensageria.page_credit_transactions(tenant.id, limit: 100)
      walked = pages(&Mensageria.page_credit_transactions(tenant.id, [limit: 4] ++ &1))

      assert Enum.map(walked, &length/1) == [4, 3]
      assert List.flatten(walked) == all
      assert length(all) == 7
    end

    test "a balance set up without a ledger entry still closes with the current balance" do
      tenant = tenant!(0)
      Repo.update_all(from(t in Tenant, where: t.id == ^tenant.id), set: [credit_balance: 50])
      reserve!(tenant)

      {[entry], nil} = Mensageria.page_credit_transactions(tenant.id)

      assert entry.balance_after == 49
      assert entry.transaction.amount == -1
      assert Mensageria.credit_balance(tenant.id) == 49
    end

    test "only the tenant's own entries, and none for a tenant without any" do
      mine = tenant!(5)
      theirs = tenant!(99)
      reserve!(theirs)

      {entries, nil} = Mensageria.page_credit_transactions(mine.id)
      assert Enum.all?(entries, &(&1.transaction.tenant_id == mine.id))
      assert Enum.map(entries, & &1.balance_after) == [5]

      assert {[], nil} = Mensageria.page_credit_transactions(tenant!(0).id)
    end

    test "later pages stay inside the tenant too" do
      theirs = tenant!(50)
      for _ <- 1..3, do: reserve!(theirs)
      mine = tenant!(50)
      for _ <- 1..3, do: reserve!(mine)

      {first, cursor} = Mensageria.page_credit_transactions(mine.id, limit: 2)
      {second, nil} = Mensageria.page_credit_transactions(mine.id, limit: 2, cursor: cursor)

      assert length(first) + length(second) == 4
      assert Enum.all?(first ++ second, &(&1.transaction.tenant_id == mine.id))
    end

    test "the limit is clamped" do
      tenant = tenant!(5)
      reserve!(tenant)

      assert {[_one], cursor} = Mensageria.page_credit_transactions(tenant.id, limit: -4)
      assert cursor
    end
  end

  describe "list_credit_transactions_for_log/2" do
    test "gives the debit and the refund of the log, oldest first, and nothing else" do
      tenant = tenant!(10)
      log = reserve!(tenant)
      other_log = reserve!(tenant)
      {:ok, _} = Mensageria.give_up(log, :stale)

      assert [debit, refund] = Mensageria.list_credit_transactions_for_log(tenant.id, log.id)
      assert {debit.reason, debit.amount} == {"dispatch", -1}
      assert {refund.reason, refund.amount} == {"refund", 1}

      assert [%{message_log_id: id}] =
               Mensageria.list_credit_transactions_for_log(tenant.id, other_log.id)

      assert id == other_log.id
    end

    test "never another tenant's entries" do
      mine = tenant!(10)
      theirs = tenant!(10)
      log = reserve!(theirs)

      assert Mensageria.list_credit_transactions_for_log(mine.id, log.id) == []
    end
  end
end
