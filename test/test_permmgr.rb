require 'minitest/autorun'
require_relative '../permmgr'

class PermManagerTest < Minitest::Test

  def setup
  end

  def teardown
  end

  def test_create_permmgr
    inst = PermManager.new('plain:user')
    assert_equal('plain:user', inst.granting_user)
    assert_equal('plain:user', inst.owner)
    assert('plain:user', inst.perms[:root].owner)
  end

  def test_owner_is_shared
    inst = PermManager.new('plain:user')
    inst2 = PermManager.new('plain:user2')

    assert_equal('plain:user', inst.granting_user)
    assert_equal('plain:user', inst.owner)
    assert_equal('plain:user2', inst2.granting_user)
    assert_equal('plain:user', inst2.owner)
    assert_equal(inst.owner, inst2.owner)
  end

  def test_set_logger
    require 'logger'

    inst = PermManager.new('plain:user')
    assert(inst.logger.is_a?(Logger))

    newlogger = Logger.new(STDOUT)
    inst.set_logger(newlogger)
    assert(inst.logger.is_a?(Logger))

    ex = assert_raises(TypeError) { inst.set_logger({}) }
    assert_equal('PermManager requires a kind_of logger instance', ex.message)
  end

  def test_only_owner_can_grant_at_start
    inst = PermManager.new('plain:user')
    inst2 = PermManager.new('plain:follower')

    assert(inst.perms[:root].grantor?('plain:user'))
    assert(!inst.perms[:root].grantor?('plain:follower'))
  end
end
