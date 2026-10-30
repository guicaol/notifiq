defmodule Notifiq.Mensageria.Backoff do
  @moduledoc """
  Wait between dispatch attempts (Spec 007, FR-6): exponential, capped, with jitter.

      delay(1) == base            delay(2) == 2 * base         delay(3) == 4 * base ...

  Jitter spreads retries of messages that failed together (e.g. a provider outage), so
  they don't all come back at the same instant.
  """

  alias Notifiq.Mensageria.DispatchSettings

  @doc """
  Seconds to wait before attempt `attempt + 1`, i.e. after `attempt` failed.

  Options (default to `DispatchSettings`): `:base`, `:cap`, `:jitter`.
  """
  @spec delay(pos_integer(), keyword()) :: pos_integer()
  def delay(attempt, opts \\ []) when is_integer(attempt) and attempt >= 1 do
    base = Keyword.get_lazy(opts, :base, fn -> DispatchSettings.get(:backoff_base) end)
    cap = Keyword.get_lazy(opts, :cap, fn -> DispatchSettings.get(:backoff_cap) end)
    jitter = Keyword.get_lazy(opts, :jitter, fn -> DispatchSettings.get(:backoff_jitter) end)

    # Capped before multiplying so a huge attempt number can't build a giant integer.
    exponent = min(attempt - 1, 30)
    raw = min(base * Integer.pow(2, exponent), cap)
    spread = trunc(raw * jitter)

    max(1, raw + random_offset(spread))
  end

  defp random_offset(0), do: 0
  defp random_offset(spread), do: :rand.uniform(2 * spread + 1) - spread - 1
end
