defmodule Notifiq.Templates.Renderer do
  @moduledoc """
  Fills a message template with the values of an event (Spec 009).

  The language is deliberately tiny: plain text, `{{name}}` and `{{name|default}}`. There
  are no conditions, loops or expressions, because the template is written by a tenant and
  the values come from third parties (a customer's name): the less this can do, the less
  there is to abuse.

    * Substitution happens in **one pass**: a value that itself looks like `{{other}}` is
      inserted literally, never expanded again.
    * Values are **sanitised**: control characters and line breaks become spaces, runs of
      spaces collapse, the ends are trimmed, and at most 200 characters are kept.
    * A variable that is missing, `nil` or blank uses its default; with no default the
      render **fails** — an incomplete message is never produced.
  """

  @max_value_length 200
  @name ~r/^[a-z][a-z0-9_]*$/

  @type segment :: {:text, String.t()} | {:var, String.t(), String.t() | nil}
  @type error ::
          :invalid_syntax | {:missing_variable, String.t()} | {:unsupported_value, String.t()}

  @doc "Maximum characters kept from each substituted value."
  @spec max_value_length() :: pos_integer()
  def max_value_length, do: @max_value_length

  @doc """
  Splits a template into text and variable segments, or reports `:invalid_syntax`
  (unclosed `{{`, stray `}}`, an empty or ill-named variable). Used to reject a bad
  template when it is saved, and by `render/2`.
  """
  @spec parse(term()) :: {:ok, [segment()]} | {:error, :invalid_syntax}
  def parse(body) when is_binary(body) do
    body
    |> split()
    |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, acc} ->
      case segment(chunk) do
        {:ok, segment} -> {:cont, {:ok, [segment | acc]}}
        :error -> {:halt, {:error, :invalid_syntax}}
      end
    end)
    |> case do
      {:ok, segments} -> {:ok, Enum.reverse(segments)}
      error -> error
    end
  end

  def parse(_other), do: {:error, :invalid_syntax}

  @doc "The names of the variables a template uses, without repeats."
  @spec variables(String.t()) :: {:ok, [String.t()]} | {:error, :invalid_syntax}
  def variables(body) do
    with {:ok, segments} <- parse(body) do
      {:ok, segments |> Enum.flat_map(&variable_name/1) |> Enum.uniq()}
    end
  end

  @doc """
  Renders `body` with `values`, a map keyed by variable name (string keys).
  """
  @spec render(String.t(), map()) :: {:ok, String.t()} | {:error, error()}
  def render(body, values) when is_map(values) do
    with {:ok, segments} <- parse(body) do
      segments
      |> Enum.reduce_while({:ok, []}, fn segment, {:ok, acc} ->
        case fill(segment, values) do
          {:ok, text} -> {:cont, {:ok, [text | acc]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, parts} -> {:ok, parts |> Enum.reverse() |> IO.iodata_to_binary()}
        error -> error
      end
    end
  end

  # `{{ ... }}` blocks are kept as chunks of their own, the text between them too.
  defp split(body), do: Regex.split(~r/\{\{.*?\}\}/s, body, include_captures: true)

  defp segment("{{" <> rest = chunk) do
    if String.ends_with?(chunk, "}}") do
      rest |> String.slice(0, String.length(rest) - 2) |> variable()
    else
      :error
    end
  end

  defp segment(text) do
    # Any `{{` or `}}` left in plain text is an unclosed or stray delimiter.
    if String.contains?(text, ["{{", "}}"]), do: :error, else: {:ok, {:text, text}}
  end

  defp variable(content) do
    case String.split(content, "|", parts: 2) do
      [name] -> named(String.trim(name), nil)
      [name, default] -> named(String.trim(name), String.trim(default))
    end
  end

  defp named(name, default) do
    cond do
      not Regex.match?(@name, name) -> :error
      is_binary(default) and String.contains?(default, ["{", "}"]) -> :error
      true -> {:ok, {:var, name, default}}
    end
  end

  defp variable_name({:var, name, _default}), do: [name]
  defp variable_name({:text, _text}), do: []

  defp fill({:text, text}, _values), do: {:ok, text}

  defp fill({:var, name, default}, values) do
    case sanitize(Map.get(values, name)) do
      {:ok, ""} -> fallback(name, default)
      {:ok, text} -> {:ok, text}
      :unsupported -> {:error, {:unsupported_value, name}}
    end
  end

  defp fallback(_name, default) when is_binary(default), do: {:ok, default}
  defp fallback(name, nil), do: {:error, {:missing_variable, name}}

  defp sanitize(nil), do: {:ok, ""}
  defp sanitize(value) when is_binary(value), do: {:ok, clean(value)}

  defp sanitize(value) when is_number(value) or is_boolean(value),
    do: {:ok, clean(to_string(value))}

  defp sanitize(_other), do: :unsupported

  defp clean(text) do
    text
    |> String.replace(~r/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]+/u, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.slice(0, @max_value_length)
    |> String.trim()
  end
end
