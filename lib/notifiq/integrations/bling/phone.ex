defmodule Notifiq.Integrations.Bling.Phone do
  @moduledoc """
  Normalises Brazilian phone numbers as written in Bling to E.164 (Spec 003, FR-7/FR-8).

    * `"+5511999998888"` — already international, kept (only validated)
    * `"5511999998888"` — 12/13 digits starting with `55` — DDI already present
    * `"(11) 99999-8888"` / `"1133334444"` — 10/11 digits (DDD + number) — `+55` added

  Numbers without a DDD (e.g. 8 digits) are rejected: they can't be dialled.
  """

  @country_code "55"
  @e164 ~r/^\+[1-9][0-9]{7,14}$/

  @spec normalize(term()) :: {:ok, String.t()} | {:error, :invalid_phone}
  def normalize(value) when is_binary(value) do
    trimmed = String.trim(value)
    digits = String.replace(trimmed, ~r/\D/, "")

    if String.starts_with?(trimmed, "+") do
      validate("+" <> digits)
    else
      normalize_local(String.replace_leading(digits, "0", ""))
    end
  end

  def normalize(value) when is_integer(value), do: value |> Integer.to_string() |> normalize()
  def normalize(_other), do: {:error, :invalid_phone}

  defp normalize_local(digits) do
    size = byte_size(digits)

    cond do
      String.starts_with?(digits, @country_code) and size in 12..13 -> validate("+" <> digits)
      size in 10..11 -> validate("+" <> @country_code <> digits)
      true -> {:error, :invalid_phone}
    end
  end

  defp validate(candidate) do
    if candidate =~ @e164, do: {:ok, candidate}, else: {:error, :invalid_phone}
  end
end
