defmodule Notifiq.Templates.RendererTest do
  use ExUnit.Case, async: true

  alias Notifiq.Templates.Renderer

  defp render(body, values \\ %{}), do: Renderer.render(body, values)

  describe "substitution (AC-3)" do
    test "fills variables and keeps the text around them" do
      assert {:ok, "Olá Maria, pedido 1234 faturado."} =
               render("Olá {{nome}}, pedido {{numero}} faturado.", %{
                 "nome" => "Maria",
                 "numero" => "1234"
               })
    end

    test "a template without variables is returned as it is" do
      assert {:ok, "Seu pedido saiu."} = render("Seu pedido saiu.")
      assert {:ok, ""} = render("")
    end

    test "the same variable can appear more than once" do
      assert {:ok, "ana e ana"} = render("{{x}} e {{x}}", %{"x" => "ana"})
    end

    test "tolerates spaces inside the braces" do
      assert {:ok, "ana"} = render("{{ x }}", %{"x" => "ana"})
      assert {:ok, "ana"} = render("{{x }}", %{"x" => "ana"})
      assert {:ok, "ana"} = render("{{ x|fallback }}", %{"x" => "ana"})
    end

    test "numbers and booleans are written as text" do
      assert {:ok, "1234"} = render("{{n}}", %{"n" => 1234})
      assert {:ok, "259.9"} = render("{{n}}", %{"n" => 259.9})
      assert {:ok, "true"} = render("{{b}}", %{"b" => true})
    end

    test "text with accents, emoji and braces that aren't delimiters survives" do
      assert {:ok, "Olá, João! 🎉 {tudo} bem}?"} =
               render("Olá, {{n}}! 🎉 {tudo} bem}?", %{"n" => "João"})
    end
  end

  describe "defaults and missing values (AC-3)" do
    test "a missing variable uses its default" do
      assert {:ok, "Olá cliente"} = render("Olá {{nome|cliente}}", %{})
    end

    test "nil and blank values count as missing" do
      for value <- [nil, "", "   ", "\n\t "] do
        assert {:ok, "Olá cliente"} = render("Olá {{nome|cliente}}", %{"nome" => value}),
               inspect(value)
      end
    end

    test "the value wins over the default" do
      assert {:ok, "Olá Maria"} = render("Olá {{nome|cliente}}", %{"nome" => "Maria"})
    end

    test "an empty default makes the variable optional" do
      assert {:ok, "Olá "} = render("Olá {{nome|}}", %{})
    end

    test "the default may contain a pipe" do
      assert {:ok, "a|b"} = render("{{x|a|b}}", %{})
    end

    test "without a default, a missing variable fails the render" do
      assert {:error, {:missing_variable, "nome"}} = render("Olá {{nome}}", %{})
      assert {:error, {:missing_variable, "nome"}} = render("Olá {{nome}}", %{"nome" => nil})
      assert {:error, {:missing_variable, "nome"}} = render("Olá {{nome}}", %{"nome" => "  "})
    end

    test "a value that isn't text, number or boolean is refused" do
      for value <- [%{"a" => 1}, ["x"], {:tuple}, :atom] do
        assert {:error, {:unsupported_value, "x"}} = render("{{x}}", %{"x" => value}),
               inspect(value)
      end
    end
  end

  describe "values are untrusted (AC-3)" do
    test "a value that looks like a variable is inserted literally, not expanded" do
      assert {:ok, "Olá {{numero}}, pedido 1234"} =
               render("Olá {{nome}}, pedido {{numero}}", %{
                 "nome" => "{{numero}}",
                 "numero" => "1234"
               })
    end

    test "a value that looks like a default or a closing brace stays literal" do
      assert {:ok, "x}} y|z"} = render("{{v}}", %{"v" => "x}} y|z"})
    end

    test "line breaks, tabs and control characters become single spaces" do
      value = "Maria\r\nda\tSilva\u0000\u0007 Souza"

      assert {:ok, "Maria da Silva Souza"} = render("{{n}}", %{"n" => value})
    end

    test "zero-width and bidirectional control characters are removed" do
      # Built from code points on purpose: these characters are invisible in source files.
      zero_width_space = <<0x200B::utf8>>
      right_to_left_override = <<0x202E::utf8>>

      assert {:ok, "a b"} = render("{{n}}", %{"n" => "a" <> zero_width_space <> "b"})
      assert {:ok, "a b"} = render("{{n}}", %{"n" => "a" <> right_to_left_override <> " b"})
    end

    test "runs of spaces collapse and the ends are trimmed" do
      assert {:ok, "a b c"} = render("{{n}}", %{"n" => "   a    b \n  c  "})
    end

    test "a long value is cut to the limit" do
      {:ok, text} = render("{{n}}", %{"n" => String.duplicate("a", 500)})

      assert String.length(text) == Renderer.max_value_length()
      assert Renderer.max_value_length() == 200
    end

    test "a cut never leaves a trailing space" do
      value = String.duplicate("a", 199) <> " bbbbbb"

      assert {:ok, text} = render("{{n}}", %{"n" => value})
      assert text == String.duplicate("a", 199)
    end

    test "the template's own text is not sanitised" do
      assert {:ok, "linha 1\nlinha 2"} = render("linha 1\nlinha 2")
    end
  end

  describe "syntax (AC-2)" do
    @invalid [
      "Olá {{nome",
      "Olá nome}}",
      "Olá {{}}",
      "Olá {{ }}",
      "Olá {{1nome}}",
      "Olá {{Nome}}",
      "Olá {{no me}}",
      "Olá {{nome-x}}",
      "Olá {{nome.x}}",
      "{{a|{{b}}}}",
      "{{a|{b}}}",
      "{{|default}}",
      "{{{nome}}}",
      "a {{ b }} c }} d"
    ]

    test "malformed templates are rejected" do
      for body <- @invalid do
        assert {:error, :invalid_syntax} = Renderer.parse(body), inspect(body)
        assert {:error, :invalid_syntax} = Renderer.render(body, %{"nome" => "x"}), inspect(body)
      end
    end

    test "anything that isn't text is rejected" do
      assert {:error, :invalid_syntax} = Renderer.parse(nil)
      assert {:error, :invalid_syntax} = Renderer.parse(123)
    end

    test "parse/1 yields text and variable segments" do
      assert {:ok, [{:text, "Olá "}, {:var, "nome", "cliente"}, {:text, "!"}]} =
               Renderer.parse("Olá {{nome|cliente}}!")
    end
  end

  describe "variables/1" do
    test "lists the distinct names a template uses" do
      assert {:ok, ["a", "b"]} = Renderer.variables("{{a}} {{b|x}} {{a}}")
      assert {:ok, []} = Renderer.variables("sem variáveis")
      assert {:error, :invalid_syntax} = Renderer.variables("{{")
    end
  end
end
