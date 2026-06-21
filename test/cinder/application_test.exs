defmodule Cinder.ApplicationTest do
  use Cinder.DataCase, async: false

  test "warns when no users and no basic auth" do
    System.delete_env("CINDER_BASIC_AUTH_USER")
    System.delete_env("CINDER_BASIC_AUTH_PASSWORD")
    assert Cinder.Application.unprotected_fresh_instance?() == true
  end

  test "does not warn once a user exists" do
    Cinder.AccountsFixtures.user_fixture()
    assert Cinder.Application.unprotected_fresh_instance?() == false
  end
end
