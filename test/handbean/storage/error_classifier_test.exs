defmodule Handbean.Storage.ErrorClassifierTest do
  use ExUnit.Case, async: true

  alias Handbean.Storage.ErrorClassifier

  test "classifies actionable SQLite failures without depending on exception type" do
    assert ErrorClassifier.classify(%Exqlite.Error{message: "database is locked"}) == :busy
    assert ErrorClassifier.classify("database or disk is full") == :full
    assert ErrorClassifier.classify("disk I/O error") == :ioerr
    assert ErrorClassifier.classify("database disk image is malformed") == :corrupt
    assert ErrorClassifier.classify("file is not a database") == :corrupt
    assert ErrorClassifier.classify("FOREIGN KEY constraint failed") == :constraint
    assert ErrorClassifier.classify(:other) == :unknown
  end
end
