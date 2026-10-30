defmodule Notifiq.Test.NoMetadataSource do
  @moduledoc "An adapter with every callback of the contract except `metadata/0` (Spec 010, AC-13)."

  def source_key, do: :no_metadata
  def verify_authenticity(_conn, _credentials), do: :ok
  def extract_event_id(_payload), do: "1"
  def extract_account_id(_payload), do: :error
  def parse(_payload), do: {:ok, :ignore}
end
