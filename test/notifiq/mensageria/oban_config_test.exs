defmodule Notifiq.Mensageria.ObanConfigTest do
  # Spec 007, AC-13. The test environment turns queues and plugins off, so this reads the
  # real (dev) configuration straight from config/config.exs instead of the running one.
  use ExUnit.Case, async: true

  @config_path Path.expand("../../../config/config.exs", __DIR__)

  defp oban_config do
    @config_path
    |> Config.Reader.read!(env: :dev, target: :host)
    |> Keyword.fetch!(:notifiq)
    |> Keyword.fetch!(Oban)
  end

  test "declares a dispatch queue apart from ingestion, and a maintenance queue" do
    queues = oban_config()[:queues]

    assert Keyword.has_key?(queues, :ingestion)
    assert Keyword.has_key?(queues, :dispatch)
    assert Keyword.has_key?(queues, :maintenance)
  end

  test "runs the Lifeline and Pruner plugins and schedules the sweeper" do
    plugins = oban_config()[:plugins]

    modules =
      Enum.map(plugins, fn plugin -> if is_tuple(plugin), do: elem(plugin, 0), else: plugin end)

    assert Oban.Plugins.Lifeline in modules
    assert Oban.Plugins.Pruner in modules

    {Oban.Plugins.Cron, cron_opts} = Enum.find(plugins, &match?({Oban.Plugins.Cron, _}, &1))

    assert {_schedule, Notifiq.Mensageria.Sweeper} =
             Enum.find(cron_opts[:crontab], &match?({_, Notifiq.Mensageria.Sweeper}, &1))
  end

  test "the cron schedule is a valid expression" do
    {Oban.Plugins.Cron, cron_opts} =
      Enum.find(oban_config()[:plugins], &match?({Oban.Plugins.Cron, _}, &1))

    for {expression, _worker} <- cron_opts[:crontab] do
      assert {:ok, _parsed} = Oban.Cron.Expression.parse(expression)
    end
  end

  test "the running test environment doesn't start queues or plugins" do
    config = Application.fetch_env!(:notifiq, Oban)

    assert config[:queues] == false
    assert config[:plugins] == false
    assert config[:testing] == :manual
  end
end
