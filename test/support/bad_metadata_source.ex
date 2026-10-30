defmodule Notifiq.Test.BadMetadataSource do
  @moduledoc """
  An adapter whose `metadata/0` returns whatever the test put in
  `Application.get_env(:notifiq, :bad_metadata)` (Spec 011): the boot check must refuse
  a source the panel could not describe.
  """

  def source_key, do: :bad_metadata
  def metadata, do: Application.get_env(:notifiq, :bad_metadata)
  def verify_authenticity(_conn, _credentials), do: :ok
  def extract_event_id(_payload), do: "1"
  def extract_account_id(_payload), do: :error
  def parse(_payload), do: {:ok, :ignore}
end
