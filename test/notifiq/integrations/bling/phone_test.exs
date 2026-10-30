defmodule Notifiq.Integrations.Bling.PhoneTest do
  use ExUnit.Case, async: true

  alias Notifiq.Integrations.Bling.Phone

  describe "normalize/1" do
    test "AC-3: adds +55 to a mobile number with DDD" do
      assert {:ok, "+5511999998888"} = Phone.normalize("11999998888")
    end

    test "accepts landlines (10 digits) as well as mobiles (11 digits)" do
      assert {:ok, "+551133334444"} = Phone.normalize("1133334444")
      assert {:ok, "+5511999998888"} = Phone.normalize("11999998888")
    end

    test "ignores formatting characters" do
      assert {:ok, "+5511999998888"} = Phone.normalize("(11) 99999-8888")
      assert {:ok, "+551133334444"} = Phone.normalize(" 11 3333.4444 ")
    end

    test "does not duplicate the DDI when already present" do
      assert {:ok, "+5511999998888"} = Phone.normalize("+5511999998888")
      assert {:ok, "+5511999998888"} = Phone.normalize("5511999998888")
      assert {:ok, "+551133334444"} = Phone.normalize("551133334444")
    end

    test "a DDD of 55 is not mistaken for the country code" do
      assert {:ok, "+5555999998888"} = Phone.normalize("55999998888")
      assert {:ok, "+555533334444"} = Phone.normalize("5533334444")
    end

    test "drops the national trunk zero" do
      assert {:ok, "+5511999998888"} = Phone.normalize("011999998888")
    end

    test "keeps other international numbers when written with +" do
      assert {:ok, "+14155552671"} = Phone.normalize("+1 (415) 555-2671")
    end

    test "AC-4: rejects numbers with too few digits" do
      assert {:error, :invalid_phone} = Phone.normalize("123")
      assert {:error, :invalid_phone} = Phone.normalize("99998888")
    end

    test "rejects blank, non-numeric and non-string input" do
      assert {:error, :invalid_phone} = Phone.normalize("")
      assert {:error, :invalid_phone} = Phone.normalize("   ")
      assert {:error, :invalid_phone} = Phone.normalize("sem telefone")
      assert {:error, :invalid_phone} = Phone.normalize(nil)
      assert {:error, :invalid_phone} = Phone.normalize(%{})
    end

    test "rejects numbers that are too long" do
      assert {:error, :invalid_phone} = Phone.normalize("1199999888877")
      assert {:error, :invalid_phone} = Phone.normalize("+1234567890123456")
    end
  end
end
