require 'minitest/autorun'
require './auth'

class AuthTest < Minitest::Test

  def setup
    @inst = Auth.new
  end

  def test_simple_constant_pws
    assert(@inst.login('mc', 'password'))
    assert(!@inst.login('mc', 'notthepassword'))
  end

  def test_mojang_authserver
    assert_equal('hexparrot@me.com', @inst.login_mojang('hexparrot@me.com', 'thisistherealpassword'))
    assert_nil(@inst.login_mojang('hexparrot@me.com', 'fakepassword'))
  end

end

