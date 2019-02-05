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

  def test_incremental_granting_of_root_permissions_for_non_owner
    user = 'plain:user'
    inst = PermManager.new(user)
    user2 = 'plain:user2'
    inst2 = PermManager.new(user2)

    assert(!inst.perms[:root].grantor?(user2))
    assert(!inst.perms[:root].test_permission(user2, 'mkgrantor'))
    assert(!inst.perms[:root].test_permission(user2, 'rmgrantor'))
    assert(!inst.perms[:root].test_permission(user2, 'grantall'))
    assert(!inst.perms[:root].test_permission(user2, 'revokeall'))

    assert(!inst.perms[:root].test_permission(user2, 'mkpool'))
    assert(!inst.perms[:root].test_permission(user2, 'rmpool'))
    assert(!inst.perms[:root].test_permission(user2, 'spawnpool'))
    assert(!inst.perms[:root].test_permission(user2, 'despawnpool'))
    
    cmd = { hostname: @hostname,
            workerpool: @workerpool,
            root_cmd: 'mkpool' }.to_json

    inst2.root_command(JSON.parse cmd)
    assert_equal("PERMS: mkpool by #{user2}@#{@workerpool}: FAIL", inst2.logs.pop.message)

    inst.root_perms('grantall', user2)
    inst2.root_command(JSON.parse(cmd)) { |amqp_data, rk|
      assert_equal(@workerpool, amqp_data[:MKPOOL][:workerpool])
      assert_equal("managers.#{@hostname}", rk)
    }

    assert_equal("PERMS: #{user} granting `root`:all to #{user2}", inst.logs.shift.message)
    assert_equal("PERMS: (:all) mkpool, rmpool, spawn, despawn", inst.logs.shift.message)
    assert_equal("PERMS: CREATED PERMSCREEN `#{@workerpool} => managers.#{@hostname}`", inst2.logs.shift.message)
    assert_equal("MANAGER: MKPOOL `#{@workerpool} => managers.#{@hostname}`", inst2.logs.shift.message)
  end

  def test_incremental_granting_of_pool_permissions
    user = 'plain:user'
    inst = PermManager.new(user)

    cmd = { hostname: @hostname,
            workerpool: @workerpool,
            root_cmd: 'mkpool' }.to_json

    inst.root_perms('grantall', user)
    inst.root_command(JSON.parse(cmd)) { |amqp_data, rk|
      assert_equal(@workerpool, amqp_data[:MKPOOL][:workerpool])
      assert_equal("managers.#{@hostname}", rk)
    }

    inst.logs.clear # from root_command, not needing to be tested here
    pool_fqdn = "#{@hostname}.#{@workerpool}"

    assert(inst.perms[pool_fqdn].grantor?(user))
    assert(inst.perms[pool_fqdn].test_permission(user, 'create'))
    assert(inst.perms[pool_fqdn].test_permission(user, 'delete'))
    # plain:user is owner and grantor? of pool_fqdn
    # can self-grant, though, because owner can do that.

    inst.pool_perms('grantall', user, pool_fqdn)
    assert_equal("PERMS: #{user} granting #{user} `#{pool_fqdn}`:all", inst.logs.shift.message)
    assert_equal("PERMS: (:all) create, delete", inst.logs.shift.message)

    servername = 'testx'
    cmd = { hostname: @hostname,
            workerpool: @workerpool,
            server_name: servername,
            pool_cmd: 'create' }.to_json

    inst.pool_command(JSON.parse(cmd)) { |amqp_data, rk|
      assert_equal(servername, amqp_data["server_name"])
      assert_equal("workers.#{@hostname}.#{@workerpool}", rk)
    }

    assert_equal("PERMS: create by #{user}@#{@hostname}.#{@workerpool}: OK", inst.logs.shift.message)
    assert_equal("POOL: CREATE SERVER `#{servername} => workers.#{@hostname}.#{@workerpool}`", inst.logs.shift.message)
  end

  def test_incremental_granting_of_pool_permissions_for_non_owner
    user = 'plain:user'
    inst = PermManager.new(user)
    user2 = 'plain:user2'
    inst2 = PermManager.new(user2)

    cmd = { hostname: @hostname,
            workerpool: @workerpool,
            root_cmd: 'mkpool' }.to_json

    # user will make the pool so user--not user2--retains ownership
    inst.root_perms('grantall', user)
    inst.root_command(JSON.parse(cmd)) { |amqp_data, rk|
      assert_equal(@workerpool, amqp_data[:MKPOOL][:workerpool])
      assert_equal("managers.#{@hostname}", rk)
    }

    inst.logs.clear # from root_command, not needing to be tested here
    pool_fqdn = "#{@hostname}.#{@workerpool}"

    # user is doing the granting here of :all, but not grantor? status
    inst.pool_perms('grantall', user2, pool_fqdn)
    assert_equal("PERMS: #{user} granting #{user2} `#{pool_fqdn}`:all", inst.logs.shift.message)
    assert_equal("PERMS: (:all) create, delete", inst.logs.shift.message)

    # not a grantor, but can still create and delete
    assert(!inst2.perms[pool_fqdn].grantor?(user2))
    assert(inst2.perms[pool_fqdn].test_permission(user2, 'create'))
    assert(inst2.perms[pool_fqdn].test_permission(user2, 'delete'))

    servername = 'testx'
    cmd = { hostname: @hostname,
            workerpool: @workerpool,
            server_name: servername,
            pool_cmd: 'create' }.to_json

    inst2.pool_command(JSON.parse(cmd)) { |amqp_data, rk|
      assert_equal(servername, amqp_data["server_name"])
      assert_equal("workers.#{@hostname}.#{@workerpool}", rk)
    }

    assert_equal("PERMS: create by #{user2}@#{@hostname}.#{@workerpool}: OK", inst2.logs.shift.message)
    assert_equal("POOL: CREATE SERVER `#{servername} => workers.#{@hostname}.#{@workerpool}`", inst2.logs.shift.message)
  end
end

