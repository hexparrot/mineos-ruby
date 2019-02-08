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

  def test_create_root_perms
    owner = 'plain:owner'
    inst = PermManager.new(owner)
    user = 'plain:user2'
    inst2 = PermManager.new(user)
    
    assert(inst.perms[:root].grantor?(owner))
    assert(inst2.perms[:root].grantor?(owner))
    assert(!inst.perms[:root].grantor?(user))
    assert(!inst2.perms[:root].grantor?(user))
    # plain:user is owner and grantor? but not granted anything yet

    # test only the commands (not status-changers like 'mkgrantor')
    assert(!inst.perms[:root].test_permission(owner, 'mkpool'))
    assert(!inst.perms[:root].test_permission(owner, 'rmpool'))
    assert(!inst.perms[:root].test_permission(owner, 'spawnpool'))
    assert(!inst.perms[:root].test_permission(owner, 'despawnpool'))
    assert(!inst.perms[:root].test_permission(owner, 'fake'))
      
    # inst/inst2 are equivalent when testing :root
    assert(!inst.perms[:root].test_permission(user, 'mkpool'))
    assert(!inst.perms[:root].test_permission(user, 'rmpool'))
    assert(!inst.perms[:root].test_permission(user, 'spawnpool'))
    assert(!inst.perms[:root].test_permission(user, 'despawnpool'))
    assert(!inst.perms[:root].test_permission(user, 'fake'))

    assert(inst.cast_root_perm!('grantall', user))

    assert(!inst.perms[:root].test_permission(owner, 'mkpool'))
    assert(!inst.perms[:root].test_permission(owner, 'rmpool'))
    assert(!inst.perms[:root].test_permission(owner, 'spawnpool'))
    assert(!inst.perms[:root].test_permission(owner, 'despawnpool'))
    assert(!inst.perms[:root].test_permission(owner, 'fake'))

    assert(inst.perms[:root].test_permission(user, 'mkpool'))
    assert(inst.perms[:root].test_permission(user, 'rmpool'))
    assert(inst.perms[:root].test_permission(user, 'spawnpool'))
    assert(inst.perms[:root].test_permission(user, 'despawnpool'))
    assert(inst.perms[:root].test_permission(user, 'fake'))
  end

  def test_executing_with_root_permissions
    owner = 'plain:owner'
    inst = PermManager.new(owner)
    user = 'plain:user2'
    inst2 = PermManager.new(user)

    cmd = { hostname: @hostname,
            workerpool: @workerpool,
            root_cmd: 'mkpool' }.to_json

    success = inst2.root_exec_cmd!(JSON.parse cmd) { |amqp_data, rk| }
    assert_equal("PERMS: {#{user}} mkpool(#{@hostname}.#{@workerpool}): FAIL", inst2.logs.shift.message)
    assert(!success)

    assert(inst.cast_root_perm!('grantall', user))

    inst.cast_root_perm!('grantall', user)
    inst2.root_exec_cmd!(JSON.parse(cmd)) { |amqp_data, rk|
      assert_equal(@workerpool, amqp_data[:MKPOOL][:workerpool])
      assert_equal("managers.#{@hostname}", rk)
    }

    #inst.perms['managers.@hostname.@workerpool'] doesn't exist, so create permscreen
    assert_equal("PERMS: {#{user}} create_permscreen(#{@hostname}.#{@workerpool})", inst2.logs.shift.message)
    assert_equal("PERMS: {#{user}} granted :all on (#{@hostname}.#{@workerpool})", inst2.logs.shift.message)
    assert_equal("PERMS: (:all) mkpool, rmpool, spawn, despawn", inst2.logs.shift.message)
    assert_equal("POOL: {#{user}} mkpool(#{@hostname}.#{@workerpool}): OK", inst2.logs.shift.message)
 
    inst2.root_exec_cmd!(JSON.parse(cmd)) {}
    assert_equal("POOL: {#{user}} mkpool(#{@hostname}.#{@workerpool}): FAIL", inst2.logs.shift.message)
    assert_equal("POOL: [NOOP:pool already exists] mkpool(#{@hostname}.#{@workerpool})", inst2.logs.shift.message)

    cmd = { hostname: @hostname,
            workerpool: @workerpool,
            root_cmd: 'rmpool' }.to_json

    inst2.root_exec_cmd!(JSON.parse(cmd)) { |amqp_data, rk|
      assert_equal(@workerpool, amqp_data[:RMPOOL][:workerpool])
      assert_equal("managers.#{@hostname}", rk)
    }

    assert_equal("POOL: delete_permscreen(#{@hostname}.#{@workerpool}): OK", inst2.logs.shift.message)
    assert_equal("POOL: {#{user}} rmpool(#{@hostname}.#{@workerpool}): OK", inst2.logs.shift.message)

    # repeat on deleted
    inst2.root_exec_cmd!(JSON.parse(cmd)) {}
    assert_equal("POOL: {#{user}} rmpool(#{@hostname}.#{@workerpool}): FAIL", inst2.logs.shift.message)
    assert_equal("POOL: [NOOP:pool doesn't exist] rmpool(#{@hostname}.#{@workerpool})", inst2.logs.shift.message)
  end

  def test_create_pool_perms
    owner = 'plain:owner'
    inst = PermManager.new(owner)
    creator = 'plain:creator'
    inst2 = PermManager.new(creator)
    user = 'plain:user'
    inst3 = PermManager.new(user)
    
    assert(inst.cast_root_perm!('grantall', creator))

    cmd = { hostname: @hostname,
            workerpool: @workerpool,
            root_cmd: 'mkpool' }.to_json

    inst2.root_exec_cmd!(JSON.parse(cmd)) { |amqp_data, rk|
      assert_equal(@workerpool, amqp_data[:MKPOOL][:workerpool])
      assert_equal("managers.#{@hostname}", rk)
    }
    pool_fqdn = "#{@hostname}.#{@workerpool}"

    assert(inst.perms[pool_fqdn].grantor?(creator))
    assert(!inst.perms[pool_fqdn].grantor?(user))

    assert(inst.perms[pool_fqdn].test_permission(creator, 'create'))
    assert(inst.perms[pool_fqdn].test_permission(creator, 'delete'))
    assert(!inst.perms[pool_fqdn].test_permission(user, 'create'))
    assert(!inst.perms[pool_fqdn].test_permission(user, 'delete'))

    assert(inst2.cast_pool_perm!('grantall', user, pool_fqdn))
    inst2.logs.clear

    servername = 'testx'
    cmd = { hostname: @hostname,
            workerpool: @workerpool,
            server_name: servername,
            pool_cmd: 'create' }.to_json

    success = inst2.pool_exec_cmd!(JSON.parse(cmd)) { |amqp_data, rk|
      assert_equal(servername, amqp_data["server_name"])
      assert_equal("workers.#{@hostname}.#{@workerpool}", rk)
    }
    assert(success)
    server_fqdn = "#{@hostname}.#{@workerpool}.#{servername}"

    assert_equal("POOL: {#{creator}} create_server(#{@hostname}.#{@workerpool}.#{servername}): OK", inst2.logs.shift.message)

    assert(inst.perms[server_fqdn].test_permission(creator, 'accept_eula'))
    assert(inst.perms[server_fqdn].test_permission(creator, 'accept_eula'))
    assert(!inst.perms[server_fqdn].test_permission(user, 'accept_eula'))
    assert(!inst.perms[server_fqdn].test_permission(user, 'accept_eula'))

    success = inst2.pool_exec_cmd!(JSON.parse(cmd)) {}
    assert(!success)
    assert_equal("POOL: {#{creator}} create_server(#{@hostname}.#{@workerpool}.#{servername}): FAIL", inst2.logs.shift.message)
    assert_equal("POOL: [NOOP:server already exists] create_server(#{@hostname}.#{@workerpool}.#{servername})", inst2.logs.shift.message)
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
    assert_equal("PERMS: mkpool by #{user2}@#{@workerpool}: FAIL", inst2.logs.shift.message)

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

  def test_incremental_granting_of_server_permissions
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

    # not a grantor, but can still create and delete
    assert(inst.perms[pool_fqdn].grantor?(user))
    assert(inst.perms[pool_fqdn].test_permission(user, 'create'))
    assert(inst.perms[pool_fqdn].test_permission(user, 'delete'))

    inst.pool_perms('grantall', user, pool_fqdn)

    servername = 'testx'
    cmd = { hostname: @hostname,
            workerpool: @workerpool,
            server_name: servername,
            pool_cmd: 'create' }.to_json

    inst.pool_command(JSON.parse(cmd)) { |amqp_data, rk|
      assert_equal(servername, amqp_data["server_name"])
      assert_equal("workers.#{@hostname}.#{@workerpool}", rk)
    }

    inst.logs.clear # from pool_command, not needing to be tested here
    server_fqdn = "#{@hostname}.#{@workerpool}.#{servername}"
    inst.server_perms('grantall', user, server_fqdn)

    assert_equal("PERMS: #{user} granting #{user} on `#{@hostname}.#{@workerpool}.#{servername}`:all", inst.logs.shift.message)
    assert_equal("PERMS: (:all) start, stop, etc.", inst.logs.shift.message)

    cmd = { hostname: @hostname,
            workerpool: @workerpool,
            server_name: servername,
            server_cmd: "modify_sc",
            section: "java",
            attr: "java_xmx",
            value: 512 }.to_json

    inst.server_command(JSON.parse(cmd)) { |amqp_data, rk|
      assert_equal(servername, amqp_data["server_name"])
      assert_equal("workers.#{@hostname}.#{@workerpool}", rk)
    }

    worker_routing_key = "workers.#{@hostname}.#{@workerpool}"

    assert_equal("PERMS: modify_sc by #{user}@#{@hostname}.#{@workerpool}.#{servername}: OK", inst.logs.shift.message)
    assert_equal("HQ: Forwarded command `#{worker_routing_key}`", inst.logs.shift.message)
  end

  def test_incremental_granting_of_server_permissions_for_non_owner
    user = 'plain:user'
    inst = PermManager.new(user)
    user2 = 'plain:user2'
    inst2 = PermManager.new(user2)

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

    assert(!inst.perms[pool_fqdn].grantor?(user2))
    assert(!inst.perms[pool_fqdn].test_permission(user2, 'create'))
    assert(!inst.perms[pool_fqdn].test_permission(user2, 'delete'))

    inst.pool_perms('grantall', user, pool_fqdn)

    assert(!inst.perms[pool_fqdn].grantor?(user2))
    assert(!inst.perms[pool_fqdn].test_permission(user2, 'create'))
    assert(!inst.perms[pool_fqdn].test_permission(user2, 'delete'))

    servername = 'testx'
    cmd = { hostname: @hostname,
            workerpool: @workerpool,
            server_name: servername,
            pool_cmd: 'create' }.to_json

    inst.pool_command(JSON.parse(cmd)) { |amqp_data, rk|
      assert_equal(servername, amqp_data["server_name"])
      assert_equal("workers.#{@hostname}.#{@workerpool}", rk)
    }

    inst.logs.clear # from pool_command, not needing to be tested here

    #user2 not given any permissions until here, giving server-level
    server_fqdn = "#{@hostname}.#{@workerpool}.#{servername}"
    inst.server_perms('grantall', user2, server_fqdn)
    assert_equal("PERMS: #{user} granting #{user2} on `#{@hostname}.#{@workerpool}.#{servername}`:all", inst.logs.shift.message)
    assert_equal("PERMS: (:all) start, stop, etc.", inst.logs.shift.message)

    cmd = { hostname: @hostname,
            workerpool: @workerpool,
            server_name: servername,
            server_cmd: "modify_sc",
            section: "java",
            attr: "java_xmx",
            value: 512 }.to_json

    inst2.server_command(JSON.parse(cmd)) { |amqp_data, rk|
      assert_equal(servername, amqp_data["server_name"])
      assert_equal("workers.#{@hostname}.#{@workerpool}", rk)
    }

    worker_routing_key = "workers.#{@hostname}.#{@workerpool}"

    assert_equal("PERMS: modify_sc by #{user2}@#{@hostname}.#{@workerpool}.#{servername}: OK", inst2.logs.shift.message)
    assert_equal("HQ: Forwarded command `#{worker_routing_key}`", inst2.logs.shift.message)
  end

  def test_all_root_perms
    user = 'plain:user'
    inst = PermManager.new(user)
    user2 = 'plain:user2'
    inst2 = PermManager.new(user2)
    user3 = 'plain:user3'
    inst3 = PermManager.new(user3)

    # root is grantor, but otherwise shouldn't be able to do anything.
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

    cmd = { hostname: @hostname, workerpool: @workerpool }

    ['mkpool', 'rmpool', 'spawnpool', 'despawnpool'].each { |action|
      cmd[:root_cmd] = action

      jsoned = cmd.to_json
      assert(!inst.root_command(JSON.parse jsoned))
    }

    ['mkpool', 'rmpool', 'spawnpool', 'despawnpool'].each { |action|
      cmd[:root_cmd] = action

      jsoned = cmd.to_json
      assert(!inst2.root_command(JSON.parse jsoned))
    }

    assert(!inst2.perms[:root].grantor?(user2))
    assert(!inst2.perms[:root].test_permission(user2, 'mkgrantor'))
    assert(!inst2.perms[:root].test_permission(user2, 'rmgrantor'))
    assert(!inst2.perms[:root].test_permission(user2, 'grantall'))
    assert(!inst2.perms[:root].test_permission(user2, 'revokeall'))

    assert(!inst2.perms[:root].test_permission(user2, 'mkpool'))
    assert(!inst2.perms[:root].test_permission(user2, 'rmpool'))
    assert(!inst2.perms[:root].test_permission(user2, 'spawnpool'))
    assert(!inst2.perms[:root].test_permission(user2, 'despawnpool'))

    #grantall to user2 now from user@inst
    inst.root_perms('grantall', user2)
    assert(!inst2.perms[:root].grantor?(user2))

    # user2 has permissions that pass...because :all
    # however, grants aren't tested via test_permission, so
    # test_permission also will pass for 'madeup'
    assert(inst2.perms[:root].test_permission(user2, 'mkgrantor'))
    assert(inst2.perms[:root].test_permission(user2, 'rmgrantor'))
    assert(inst2.perms[:root].test_permission(user2, 'grantall'))
    assert(inst2.perms[:root].test_permission(user2, 'revokeall'))
    assert(inst2.perms[:root].test_permission(user2, 'madeup'))
    # and now to test the actual granting permissions...
    inst2.logs.clear

    ['mkgrantor', 'rmgrantor', 'grantall', 'revokeall'].each { |action|
      assert(!inst2.root_perms(action, user))
    }
    # end of that test

    assert(inst2.perms[:root].test_permission(user2, 'mkpool'))
    assert(inst2.perms[:root].test_permission(user2, 'rmpool'))
    assert(inst2.perms[:root].test_permission(user2, 'spawnpool'))
    assert(inst2.perms[:root].test_permission(user2, 'despawnpool'))

    # and again because of owner (but not grantor)
    assert(!inst.perms[:root].test_permission(user, 'mkpool'))
    assert(!inst.perms[:root].test_permission(user, 'rmpool'))
    assert(!inst.perms[:root].test_permission(user, 'spawnpool'))
    assert(!inst.perms[:root].test_permission(user, 'despawnpool'))

    # user giving mkpool/rmpool to user2
    inst.logs.clear
    assert(inst.root_perms('mkgrantor', user2))

    # user2 giving mkpool/rmpool to user3
    assert(inst2.root_perms('grantall', user3))

    assert(inst3.perms[:root].test_permission(user3, 'mkpool'))
    assert(inst3.perms[:root].test_permission(user3, 'rmpool'))
    assert(inst3.perms[:root].test_permission(user3, 'spawnpool'))
    assert(inst3.perms[:root].test_permission(user3, 'despawnpool'))
  end

  def test_chaining_all_root_perm_cmds
    user = 'plain:user'
    inst = PermManager.new(user)
    user2 = 'plain:user2'
    inst2 = PermManager.new(user2)
    user3 = 'plain:user3'
    inst3 = PermManager.new(user3)

    # user2 made grantor, user3 given :all from user2
    inst.root_perms('mkgrantor', user2)
    inst2.root_perms('grantall', user3)
    assert(inst.perms[:root].grantor?(user2))
    assert(!inst.perms[:root].grantor?(user3))
    assert(inst2.perms[:root].grantor?(user2))
    assert(!inst2.perms[:root].grantor?(user3))
    assert(inst3.perms[:root].grantor?(user2))
    assert(!inst3.perms[:root].grantor?(user3))
    # all three should report the same :root perms
   
    inst.logs.clear
    inst2.logs.clear
    inst3.logs.clear

    assert(inst3.perms[:root].test_permission(user3, 'mkpool'))
    assert(inst3.perms[:root].test_permission(user3, 'rmpool'))
    assert(inst3.perms[:root].test_permission(user3, 'spawnpool'))
    assert(inst3.perms[:root].test_permission(user3, 'despawnpool'))

    ['mkgrantor', 'rmgrantor', 'grantall', 'revokeall'].each { |action|
      assert(!inst3.root_perms(action, user2))
    }
    assert(!inst3.root_perms('madeup', user2))

    # and then user2 takes it away from user3
    inst2.root_perms('revokeall', user3)

    assert(!inst3.perms[:root].test_permission(user3, 'mkpool'))
    assert(!inst3.perms[:root].test_permission(user3, 'rmpool'))
    assert(!inst3.perms[:root].test_permission(user3, 'spawnpool'))
    assert(!inst3.perms[:root].test_permission(user3, 'despawnpool'))

    # user2 still good though!
    assert(!inst2.perms[:root].test_permission(user2, 'mkpool'))
    assert(!inst2.perms[:root].test_permission(user2, 'rmpool'))
    assert(!inst2.perms[:root].test_permission(user2, 'spawnpool'))
    assert(!inst2.perms[:root].test_permission(user2, 'despawnpool'))
  end

  def test_chaining_all_pool_perms
    user = 'plain:user'
    inst = PermManager.new(user)
    user2 = 'plain:user2'
    inst2 = PermManager.new(user2)

    # user 2 is a grantor/:all for :root
    inst.root_perms('mkgrantor', user2)
    inst.root_perms('grantall', user2)

    cmd = { hostname: @hostname, workerpool: @workerpool, root_cmd: 'mkpool' }
    jsoned = cmd.to_json
    assert(!inst.root_command(JSON.parse jsoned)) #inst

    inst2.root_command(JSON.parse jsoned) { |amqp_data, rk| }
    pool_fqdn = "#{@hostname}.#{@workerpool}"

    assert(inst.perms[pool_fqdn].grantor?(user2)) # is created and is grantor
    assert(inst.perms[pool_fqdn].test_permission(user2, 'create'))
    assert(inst.perms[pool_fqdn].test_permission(user2, 'delete'))

    servername = 'testx'
    cmd = { hostname: @hostname, workerpool: @workerpool,
            server_name: servername, pool_cmd: 'create' }
    jsoned = cmd.to_json
    inst2.pool_command(JSON.parse jsoned) { |amqp_data, rk| }
  end

  def test_server_perms
    user = 'plain:user'
    inst = PermManager.new(user)
    user2 = 'plain:user2'
    inst2 = PermManager.new(user2)

    # user 2 is a grantor/:all for :root
    inst.root_perms('mkgrantor', user2)
    inst.root_perms('grantall', user2)

    cmd = { hostname: @hostname, workerpool: @workerpool, root_cmd: 'mkpool' }
    jsoned = cmd.to_json

    inst2.root_command(JSON.parse jsoned) { |amqp_data, rk| }
    pool_fqdn = "#{@hostname}.#{@workerpool}"

    servername = 'testx'
    cmd = { hostname: @hostname, workerpool: @workerpool,
            server_name: servername, pool_cmd: 'create' }
    jsoned = cmd.to_json
    inst2.pool_command(JSON.parse jsoned) { |amqp_data, rk| }
    server_fqdn = "#{@hostname}.#{@workerpool}.#{servername}"

    assert(inst2.perms[server_fqdn].test_permission(user2, 'mkpool'))
    assert(inst2.perms[server_fqdn].test_permission(user2, 'rmpool'))
    assert(inst2.perms[server_fqdn].test_permission(user2, 'spawnpool'))
    assert(inst2.perms[server_fqdn].test_permission(user2, 'despawnpool'))

    cmd = { hostname: @hostname, workerpool: @workerpool, server_name: servername }
    
    ['start', 'stop', 'kill', 'accept_eula'].each { |action|
      cmd[:server_cmd] = action

      jsoned = cmd.to_json
      inst2.server_command(JSON.parse jsoned) { |a,b|
        assert_equal(a['cmd'], action)
        assert_equal(a['server_name'], servername)
      }
    }
  end
end

