defmodule Notifiq.Mensageria.DispatchSettings do
  @moduledoc """
  Tunables of the dispatch worker (Spec 007), read from `config :notifiq, :dispatch`.

  The defaults are reasonable guesses, not measured values: revisit them with the real
  rate of provider throttling and uncertain outcomes.

    * `:backoff_base` — seconds before the second attempt (default 30)
    * `:backoff_cap` — longest wait between attempts, in seconds (default 3600)
    * `:backoff_jitter` — fraction of the wait added or removed at random (default 0.2)
    * `:uncertain_resends` — times an `uncertain` message may be sent again (default 0:
      never, because resending may duplicate the SMS)
    * `:stale_after` — seconds a log may sit unfinished with no active job before the
      sweeper closes it (default 3600)
  """

  @defaults [
    backoff_base: 30,
    backoff_cap: 3_600,
    backoff_jitter: 0.2,
    uncertain_resends: 0,
    stale_after: 3_600
  ]

  @spec get(atom()) :: term()
  def get(key) do
    :notifiq
    |> Application.get_env(:dispatch, [])
    |> Keyword.get_lazy(key, fn -> Keyword.fetch!(@defaults, key) end)
  end
end
