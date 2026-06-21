defmodule Cinder.ApplicationTest do
  use Cinder.DataCase, async: false

  setup do
    System.delete_env("CINDER_BASIC_AUTH_USER")
    System.delete_env("CINDER_BASIC_AUTH_PASSWORD")

    on_exit(fn ->
      System.delete_env("CINDER_BASIC_AUTH_USER")
      System.delete_env("CINDER_BASIC_AUTH_PASSWORD")
    end)
  end

  test "warns when no users and no basic auth" do
    assert Cinder.Application.unprotected_fresh_instance?() == true
  end

  test "blank CINDER_BASIC_AUTH_USER still counts as unprotected" do
    System.put_env("CINDER_BASIC_AUTH_USER", "")
    System.put_env("CINDER_BASIC_AUTH_PASSWORD", "")
    assert Cinder.Application.unprotected_fresh_instance?() == true
  end

  test "whitespace-only CINDER_BASIC_AUTH_USER still counts as unprotected" do
    System.put_env("CINDER_BASIC_AUTH_USER", "   ")
    System.put_env("CINDER_BASIC_AUTH_PASSWORD", "   ")
    assert Cinder.Application.unprotected_fresh_instance?() == true
  end

  test "does not warn once a user exists" do
    Cinder.AccountsFixtures.user_fixture()
    assert Cinder.Application.unprotected_fresh_instance?() == false
  end
end
