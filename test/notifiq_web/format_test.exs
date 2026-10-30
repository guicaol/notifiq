defmodule NotifiqWeb.FormatTest do
  use ExUnit.Case, async: true

  alias NotifiqWeb.Format

  describe "mask_phone/1" do
    test "keeps the country start and the last four digits" do
      assert Format.mask_phone("+5511999998888") == "+55 ••••• 8888"
      refute Format.mask_phone("+5511999998888") =~ "99999"
    end

    test "hides anything too short or not text" do
      assert Format.mask_phone("123") == "•••••"
      assert Format.mask_phone("") == "•••••"
      assert Format.mask_phone(nil) == "•••••"
      assert Format.mask_phone(5_511_999_998_888) == "•••••"
    end
  end

  describe "relative_time/2" do
    @now ~U[2026-10-30 12:00:00Z]

    test "speaks in minutes, hours and days" do
      assert Format.relative_time(DateTime.add(@now, -10), @now) == "agora há pouco"
      assert Format.relative_time(DateTime.add(@now, -5 * 60), @now) == "há 5 min"
      assert Format.relative_time(DateTime.add(@now, -3 * 3_600), @now) == "há 3 h"
      assert Format.relative_time(DateTime.add(@now, -2 * 86_400), @now) == "há 2 d"
    end

    test "falls back to the date after a week" do
      assert Format.relative_time(~U[2026-10-01 08:00:00Z], @now) == "01/10/2026"
    end

    test "a time slightly in the future doesn't break" do
      assert Format.relative_time(DateTime.add(@now, 30), @now) == "agora há pouco"
    end
  end

  describe "datetime/1 (Spec 011)" do
    test "writes an absolute moment in UTC and says so" do
      assert Format.datetime(~U[2026-10-30 14:05:09.123456Z]) == "30/10/2026 14:05 UTC"
      assert Format.datetime(~U[2026-01-02 00:00:00Z]) == "02/01/2026 00:00 UTC"
    end
  end

  describe "signed/1 (Spec 011)" do
    test "puts a sign on every amount, with a real minus" do
      assert Format.signed(3) == "+3"
      assert Format.signed(0) == "+0"
      assert Format.signed(-1) == "−1"
      assert Format.signed(-1_200) == "−1.200"
      assert Format.signed(1_234_567) == "+1.234.567"
    end
  end

  test "number/1 groups thousands with dots" do
    assert Format.number(0) == "0"
    assert Format.number(999) == "999"
    assert Format.number(1_000) == "1.000"
    assert Format.number(1_234_567) == "1.234.567"
    assert Format.number(-12_345) == "-12.345"
  end
end
