defmodule NotifiqWeb.Format do
  @moduledoc """
  Small display helpers for the panel (Spec 010). They show the least that is useful:
  phone numbers are masked, and times are relative so they don't depend on a time zone.
  """

  @doc """
  Masks a phone number, keeping the start (country) and the last four digits:
  `"+5511999998888"` becomes `"+55 ••••• 8888"`. Anything too short to mask safely is
  hidden completely.
  """
  @spec mask_phone(term()) :: String.t()
  def mask_phone(phone) when is_binary(phone) do
    if String.length(phone) >= 9 do
      String.slice(phone, 0, 3) <> " ••••• " <> String.slice(phone, -4, 4)
    else
      "•••••"
    end
  end

  def mask_phone(_phone), do: "•••••"

  @doc "How long ago `datetime` was, in Portuguese; falls back to the date after a week."
  @spec relative_time(DateTime.t(), DateTime.t()) :: String.t()
  def relative_time(%DateTime{} = datetime, %DateTime{} = now) do
    seconds = DateTime.diff(now, datetime, :second)

    cond do
      seconds < 45 -> "agora há pouco"
      seconds < 3_600 -> "há #{max(div(seconds, 60), 1)} min"
      seconds < 86_400 -> "há #{div(seconds, 3_600)} h"
      seconds < 7 * 86_400 -> "há #{div(seconds, 86_400)} d"
      true -> Calendar.strftime(datetime, "%d/%m/%Y")
    end
  end

  @doc """
  An absolute moment, always in UTC and said so (Spec 011): `"30/10/2026 14:05 UTC"`. There
  is no time zone per tenant yet, and a bare hour would be taken for local time.
  """
  @spec datetime(DateTime.t()) :: String.t()
  def datetime(%DateTime{} = datetime) do
    datetime |> DateTime.shift_zone!("Etc/UTC") |> Calendar.strftime("%d/%m/%Y %H:%M UTC")
  end

  @doc "A ledger amount with its sign: `3` is `\"+3\"`, `-1200` is `\"−1.200\"` (a real minus)."
  @spec signed(integer()) :: String.t()
  def signed(value) when is_integer(value) and value >= 0, do: "+" <> number(value)
  def signed(value) when is_integer(value), do: "−" <> number(-value)

  @doc "Thousands separated with dots, the Brazilian way: `12345` is `\"12.345\"`."
  @spec number(integer()) :: String.t()
  def number(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1.")
    |> String.reverse()
  end
end
