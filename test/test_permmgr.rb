require 'minitest/autorun'
require_relative '../permmgr'

class PermManagerTest < Minitest::Test

  def setup
  end

  def teardown
  end

  def test_create_permmgr
    inst = PermManager.new('plain:user')
    assert_equal('plain:user', inst.grantor)
    assert_equal('plain:user', inst.owner)
    assert_equal({}, inst.perms)
  end

  def test_owner_is_shared
    inst = PermManager.new('plain:user')
    inst2 = PermManager.new('plain:user2')

    assert_equal('plain:user', inst.grantor)
    assert_equal('plain:user', inst.owner)
    assert_equal('plain:user2', inst2.grantor)
    assert_equal('plain:user', inst2.owner)
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
end
