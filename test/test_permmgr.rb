require 'minitest/autorun'
require 'json'
require_relative '../permmgr'

class PermManagerTest < Minitest::Test

  def setup
    @hostname = 'ruby-worker'
    @workerpool = '_throwaway-500'
  end

  def teardown
  end

  def test_create_permmgr
    inst = PermManager.new('plain:user')
    assert_equal('plain:user', inst.granting_user)
    assert_equal('plain:user', inst.admin)
    assert('plain:user', inst.perms[:root].owner)
  end

  def test_admin_is_shared
    inst = PermManager.new('plain:user')
    inst2 = PermManager.new('plain:user2')

    assert_equal('plain:user', inst.granting_user)
    assert_equal('plain:user', inst.admin)
    assert_equal('plain:user2', inst2.granting_user)
    assert_equal('plain:user', inst2.admin)
    assert_equal(inst.admin, inst2.admin)
  end

  def test_set_logger
    require 'logger'

    inst = PermManager.new('plain:user')

    newlogger = Logger.new(STDOUT)
    inst.set_logger(newlogger)

    ex = assert_raises(TypeError) { inst.set_logger({}) }
    assert_equal('PermManager requires a kind_of logger instance', ex.message)
  end

  def test_log_forker
    inst = PermManager.new('plain:user')

    require 'securerandom'
    inst.fork_log(:warn, "this is a warning!", "abcdef1234567890")
    item = inst.logs.first
    assert(item)
    assert_equal(:warn, item[:level])
    assert_equal("this is a warning!", item[:message])
    assert_equal("abcdef1234567890", item[:uuid])
  end

  def test_only_admin_can_grant_at_start
    inst = PermManager.new('plain:user')
    inst2 = PermManager.new('plain:follower')

    assert(inst.perms[:root].grantor?('plain:user'))
    assert(!inst.perms[:root].grantor?('plain:follower'))
  end

  def test_incremental_granting_of_root_permissions
    user = 'plain:user'
    inst = PermManager.new(user)

    assert(inst.perms[:root].grantor?(user))
    assert(!inst.perms[:root].test_permission(user, 'mkgrantor'))
    assert(!inst.perms[:root].test_permission(user, 'rmgrantor'))
    assert(!inst.perms[:root].test_permission(user, 'grantall'))
    assert(!inst.perms[:root].test_permission(user, 'revokeall'))
    # plain:user is owner and grantor? but not granted everything
    # can self-grant, though, because owner can do that.

    assert(!inst.perms[:root].test_permission(user, 'mkgrantor'))
    assert(!inst.perms[:root].test_permission(user, 'rmgrantor'))
    assert(!inst.perms[:root].test_permission(user, 'grantall'))
    assert(!inst.perms[:root].test_permission(user, 'revokeall'))

    assert(!inst.perms[:root].test_permission(user, 'mkpool'))
    assert(!inst.perms[:root].test_permission(user, 'rmpool'))
    assert(!inst.perms[:root].test_permission(user, 'spawnpool'))
    assert(!inst.perms[:root].test_permission(user, 'despawnpool'))
    
    cmd = { hostname: @hostname,
            workerpool: @workerpool,
            root_cmd: 'mkpool' }.to_json

    inst.root_command(JSON.parse cmd)
    assert_equal("PERMS: mkpool by #{user}@#{@workerpool}: FAIL", inst.logs.pop.message)

    inst.root_perms('grantall', user)
    inst.root_command(JSON.parse(cmd)) { |amqp_data, rk|
      assert_equal(@workerpool, amqp_data[:MKPOOL][:workerpool])
      assert_equal("managers.#{@hostname}", rk)
    }

    assert_equal("PERMS: #{user} granting `root`:all to #{user}", inst.logs.shift.message)
    assert_equal("PERMS: (:all) mkpool, rmpool, spawn, despawn", inst.logs.shift.message)
    assert_equal("PERMS: CREATED PERMSCREEN `#{@workerpool} => managers.#{@hostname}`", inst.logs.shift.message)
    assert_equal("MANAGER: MKPOOL `#{@workerpool} => managers.#{@hostname}`", inst.logs.shift.message)
  end
end
