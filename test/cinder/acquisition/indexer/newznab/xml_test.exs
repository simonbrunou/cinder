defmodule Cinder.Acquisition.Indexer.Newznab.XMLTest do
  # The XML reader of every Newznab and Torznab answer (#1652): a document type declaration is
  # refused before Saxy reads the body, since Saxy itself skips one and parses on.
  use ExUnit.Case, async: true

  alias Cinder.Acquisition.Indexer.Newznab.XML

  @body ~s(<?xml version="1.0" encoding="UTF-8"?>\n<caps><server title="Indexer &amp; co"/></caps>)

  defp with_prolog(declaration),
    do: String.replace(@body, "<caps>", declaration <> "\n<caps>", global: false)

  test "a plain body parses, its predefined entities expanded" do
    assert {:ok, {"caps", [], [{"server", [{"title", "Indexer & co"}], []}]}} = XML.parse(@body)
  end

  for {name, declaration} <- [
        {"a document type declaration", "<!DOCTYPE caps>"},
        {"an internal entity and a reference to it", ~s(<!DOCTYPE caps [<!ENTITY boom "boom">]>)},
        {"an external SYSTEM entity",
         ~s(<!DOCTYPE caps [<!ENTITY ext SYSTEM "file:///etc/passwd">]>)}
      ] do
    @declaration declaration

    test "#{name} is refused, where Saxy alone parses the body" do
      body = with_prolog(@declaration)
      body = if @declaration =~ "boom", do: String.replace(body, "co\"", "&boom;\""), else: body

      # The control: without the refusal, Saxy skips the declaration and reads the caps.
      assert {:ok, {"caps", _attributes, _children}} = Saxy.SimpleForm.parse_string(body)
      assert XML.parse(body) == {:error, :bad_response}
    end
  end

  # Saxy's own refusals, which the scan leaves to it.
  test "a lowercase declaration, or an entity declaration outside one, is refused" do
    for body <- [with_prolog("<!doctype caps>"), ~s(<caps><!ENTITY boom "boom"></caps>)] do
      assert {:error, _parse_error} = Saxy.SimpleForm.parse_string(body)
      assert XML.parse(body) == {:error, :bad_response}
    end
  end

  test "an undeclared entity reference stays as its text" do
    assert {:ok, {"caps", [{"title", "a &boom; b"}], []}} =
             XML.parse(~s(<caps title="a &boom; b"/>))
  end

  test "a body that is not XML, or not a binary, reads as a bad response" do
    for body <- ["", "not xml", "<caps>", "{\"caps\": 1}", <<0xFF, 0xFE, 0x00>>, %{}, nil] do
      assert XML.parse(body) == {:error, :bad_response}, inspect(body)
    end
  end
end
