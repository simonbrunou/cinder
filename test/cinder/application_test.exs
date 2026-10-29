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

  # At boot the user count queued behind Cinder.Supervisor's Sandbox ownership until the pool
  # dropped it at 2 x queue_target, so a test-env boot waited 60 to 90 s (#1018). This test pins
  # the config; it does not time the boot. config/test.exs says why the gate is off.
  test "the test env skips the boot-time unprotected-instance check" do
    assert Application.get_env(:cinder, :warn_unprotected_at_boot) == false
  end
end
