defmodule Cinder.Library.BookImportersTest do
  @moduledoc """
  What the book family's importers share with the download phase. A completion with no usable path
  has one name, whichever phase sees it: `Cinder.Download.Watch` turns it into
  `{:failed, :no_content_path}`, and the importers refuse a grab that reached them without one by
  the same name, so a held book reads the same either way.
  """
  use ExUnit.Case, async: true

  alias Cinder.Books.BookGrab
  alias Cinder.Library.{AudiobookImport, EbookImport}

  for importer <- [EbookImport, AudiobookImport], path <- [nil, ""] do
    @importer importer
    @path path

    test "#{inspect(importer)} refuses a grab with content path #{inspect(path)}" do
      assert @importer.import_grab(%BookGrab{content_path: @path}) == {:error, :no_content_path}
    end
  end
end
