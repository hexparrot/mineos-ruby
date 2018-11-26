require 'minitest/autorun'
require './auth'

class AuthTest < Minitest::Test

  def setup
    @inst = Auth.new
  end

  def test_plain_auth
    retval = @inst.login_plain('mc', 'password')
    assert_instance_of(Login, retval)
    assert_equal(:plain, retval[:authtype])
    assert_equal('mc', retval[:id])

    assert_nil(@inst.login_plain('mc', 'notthepassword'))

    retval = @inst.login_plain('will', 'something')
    assert_equal('will', retval[:id])
  end

  #def test_mojang_authserver
  #  retval = @inst.login_mojang('hexparrot@me.com', 'REALPASSWORDGOESHERE')
  #  assert_instance_of(Login, retval)
  #  assert_equal(:mojang, retval[:authtype])
  #  assert_equal('hexparrot@me.com', retval[:id])
  #  assert_nil(@inst.login_mojang('hexparrot@me.com', 'fakepassword'))
  #end

  def test_pam
    retval = @inst.login_pam('mc', 'password')
    assert_instance_of(Login, retval)
    assert_equal(:pam, retval[:authtype])
    assert_equal('mc', retval[:id])
    assert_nil(@inst.login_mojang('mc', 'fakepassword'))
  end

end

