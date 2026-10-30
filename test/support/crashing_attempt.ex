defmodule Notifiq.Test.CrashingAttempt do
  @moduledoc """
  Stands in for `Notifiq.Mensageria` as the worker's attempt module
  (`config :notifiq, :dispatch_attempt_module`) to make the attempt itself blow up, which
  the fake provider can't do: the dispatcher already contains provider exceptions.
  """

  def attempt_dispatch(_tenant_id, _message_log_id), do: raise("the database went away")
end
