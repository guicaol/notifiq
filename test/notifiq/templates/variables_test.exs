defmodule Notifiq.Templates.VariablesTest do
  # Spec 011: what a template may use. Not async: one test narrows the registered sources.
  use Notifiq.DataCase, async: false

  import Notifiq.Test.MensageriaHelpers

  alias Notifiq.Templates
  alias Notifiq.Templates.MessageTemplate

  describe "available_variables/0 (AC-9)" do
    test "starts with the recipient's name, then what each source declares, once each" do
      names = Enum.map(Templates.available_variables(), & &1.name)

      assert hd(names) == "recipient_name"
      assert names == Enum.uniq(names)

      # The fake sources and the real adapter all declare `numero_pedido`; one entry wins.
      assert Enum.count(names, &(&1 == "numero_pedido")) == 1
      assert "nome_cliente" in names
      assert "codigo_rastreio" in names
    end

    test "the first declaration of a repeated name wins" do
      %{label: label, example: example} =
        Enum.find(Templates.available_variables(), &(&1.name == "numero_pedido"))

      # Sources are read in key order: "bling" comes before "fake" and "other_fake".
      assert label == "Número do pedido"
      assert example == "4321"
    end

    test "every variable has a label and an example" do
      for variable <- Templates.available_variables() do
        assert %{name: _, label: label, example: example} = variable
        assert String.trim(label) != "" and String.trim(example) != ""
      end
    end

    test "with no source registered only the recipient's name is left" do
      original = Application.get_env(:notifiq, :integration_sources)
      Application.put_env(:notifiq, :integration_sources, %{})
      on_exit(fn -> Application.put_env(:notifiq, :integration_sources, original) end)

      assert [%{name: "recipient_name"}] = Templates.available_variables()
    end
  end

  describe "unknown_variables/1 (AC-4)" do
    test "lists the variables nobody provides, without repeats" do
      assert {:ok, ["nome", "cidade"]} =
               Templates.unknown_variables("{{nome}} de {{cidade}}, {{nome}} de novo")
    end

    test "known variables, with or without a default, are fine" do
      assert {:ok, []} =
               Templates.unknown_variables(
                 "{{recipient_name}} {{numero_pedido}} {{nome_cliente|cliente}}"
               )
    end

    test "a default doesn't excuse an unknown name" do
      assert {:ok, ["apelido"]} = Templates.unknown_variables("Oi {{apelido|cliente}}")
    end

    test "plain text has none, and bad syntax is reported as such" do
      assert {:ok, []} = Templates.unknown_variables("Seu pedido saiu.")
      assert {:error, :invalid_syntax} = Templates.unknown_variables("Olá {{nome")
    end
  end

  describe "preview/1 (AC-8)" do
    test "fills the template with the sources' examples" do
      assert {:ok, "Olá Maria Silva, pedido 4321."} =
               Templates.preview("Olá {{recipient_name}}, pedido {{numero_pedido}}.")
    end

    test "uses a default only when the variable is not known" do
      assert {:ok, "Oi cliente."} = Templates.preview("Oi {{apelido|cliente}}.")
    end

    test "fails like a real render would" do
      assert {:error, {:missing_variable, "nome"}} = Templates.preview("Oi {{nome}}")
      assert {:error, :invalid_syntax} = Templates.preview("Oi {{nome")
    end

    test "uses no stored event: another tenant's customers never appear" do
      tenant = tenant!()

      event!(
        tenant,
        "evt",
        canonical_payload(%{
          "recipient" => %{"name" => "Cliente Real", "phone" => "+5511999990000"}
        })
      )

      assert {:ok, text} = Templates.preview("{{recipient_name}}")
      refute text =~ "Cliente Real"
    end
  end

  describe "change_template/2" do
    test "validates like the domain does and never touches the tenant" do
      template = %MessageTemplate{tenant_id: Ecto.UUID.generate()}
      changeset = Templates.change_template(template, %{"body" => "", "tenant_id" => "forged"})

      refute changeset.valid?
      assert changeset.data.tenant_id == template.tenant_id
      refute Map.has_key?(changeset.changes, :tenant_id)
    end
  end
end
