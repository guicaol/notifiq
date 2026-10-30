defmodule Notifiq.Mensageria.BackoffTest do
  use ExUnit.Case, async: true

  alias Notifiq.Mensageria.Backoff

  @exact [base: 30, cap: 3_600, jitter: 0]

  describe "delay/2 without jitter (AC-8)" do
    test "the first wait is the base and each one doubles it" do
      assert Enum.map(1..6, &Backoff.delay(&1, @exact)) == [30, 60, 120, 240, 480, 960]
    end

    test "never exceeds the cap" do
      assert Backoff.delay(8, @exact) == 3_600
      assert Backoff.delay(50, @exact) == 3_600
      assert Backoff.delay(10_000, @exact) == 3_600
    end

    test "the cap is applied even when the base alone is above it" do
      assert Backoff.delay(1, base: 5_000, cap: 100, jitter: 0) == 100
    end

    test "is always at least one second" do
      assert Backoff.delay(1, base: 0, cap: 10, jitter: 0) == 1
    end
  end

  describe "delay/2 with jitter (AC-8)" do
    test "stays within the jitter fraction of the exponential value" do
      for attempt <- 1..8 do
        raw = min(30 * Integer.pow(2, attempt - 1), 3_600)
        spread = trunc(raw * 0.2)

        for _sample <- 1..200 do
          delay = Backoff.delay(attempt, base: 30, cap: 3_600, jitter: 0.2)
          assert delay >= raw - spread and delay <= raw + spread
        end
      end
    end

    test "actually varies, so retries of simultaneous failures spread out" do
      delays =
        for _sample <- 1..200,
            into: MapSet.new(),
            do: Backoff.delay(5, base: 30, cap: 3_600, jitter: 0.2)

      assert MapSet.size(delays) > 5
    end

    test "uses the configured settings by default" do
      delay = Backoff.delay(1)
      assert delay >= 24 and delay <= 36
    end
  end

  test "rejects an attempt number below 1" do
    assert_raise FunctionClauseError, fn -> Backoff.delay(0) end
  end
end
