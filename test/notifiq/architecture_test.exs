defmodule Notifiq.ArchitectureTest do
  # Spec 004, AC-13: Constitution principles 1 and 2 as tests. The core must not name a
  # specific source (Bling) or channel provider (Twilio) outside their own namespaces.
  use ExUnit.Case, async: true

  @lib Path.expand("../../lib", __DIR__)

  defp lib_files do
    @lib
    |> Path.join("**/*.{ex,heex}")
    |> Path.wildcard()
    |> Enum.map(&{Path.relative_to(&1, @lib), &1})
  end

  defp mentions_outside(pattern, allowed_dir) do
    for {relative, path} <- lib_files(),
        not String.starts_with?(relative, allowed_dir),
        File.read!(path) =~ pattern,
        do: relative
  end

  test "only Notifiq.Integrations.* names a specific source (principle 1)" do
    assert mentions_outside(~r/bling/i, "notifiq/integrations/") == []
  end

  test "only Notifiq.Channels.* names a specific provider (principle 2)" do
    assert mentions_outside(~r/twilio/i, "notifiq/channels/") == []
  end

  test "the scan sees the source tree" do
    assert length(lib_files()) > 20
  end
end
