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

  def test_executing_with_pool_perms
    #folding both into this one, since only two perms within
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

    assert(inst2.perms[pool_fqdn].test_permission(creator, 'create'))
    assert(inst2.perms[pool_fqdn].test_permission(creator, 'delete'))
    assert(!inst3.perms[pool_fqdn].test_permission(user, 'create'))
    assert(!inst3.perms[pool_fqdn].test_permission(user, 'delete'))

    assert(inst2.cast_pool_perm!('grantall', creator, pool_fqdn))
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

    cmd = { hostname: @hostname,
            workerpool: @workerpool,
            server_name: servername,
            pool_cmd: 'delete' }.to_json

    #delete from user (not creator) should fail
    success = inst3.pool_exec_cmd!(JSON.parse(cmd)) {}
    assert(!success)
    assert_equal("POOL: {#{user}} delete_server(#{@hostname}.#{@workerpool}.#{servername}): FAIL", inst3.logs.shift.message)

    success = inst2.pool_exec_cmd!(JSON.parse(cmd)) { |amqp_data, rk|
      assert_equal(servername, amqp_data["server_name"])
      assert_equal("workers.#{@hostname}.#{@workerpool}", rk)
    }
    assert_equal("POOL: {#{creator}} delete_server(#{@hostname}.#{@workerpool}.#{servername}): OK", inst2.logs.shift.message)
    assert(success)

    success = inst2.pool_exec_cmd!(JSON.parse(cmd)) {}
    assert(!success)
    assert_equal("POOL: {#{creator}} delete_server(#{@hostname}.#{@workerpool}.#{servername}): FAIL", inst2.logs.shift.message)
    assert_equal("POOL: [NOOP:server doesn't exist] delete_server(#{@hostname}.#{@workerpool}.#{servername})", inst2.logs.shift.message)
  end

  def test_executing_with_server_perms
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

    inst2.root_exec_cmd!(JSON.parse(cmd)) {}
    pool_fqdn = "#{@hostname}.#{@workerpool}"

    servername = 'testx'
    cmd = { hostname: @hostname, workerpool: @workerpool, server_name: servername }

    # user, pre-making server
    ['start', 'stop', 'kill', 'accept_eula'].each { |action|
      cmd[:server_cmd] = action

      jsoned = cmd.to_json
      success = inst3.server_exec_cmd!(JSON.parse jsoned) {}
      assert(!success)

      assert_equal("SERVER: {#{user}} #{action}(#{@hostname}.#{@workerpool}.#{servername}): FAIL", inst3.logs.shift.message)
      assert_equal("SERVER: [NOOP:server doesn't exist] #{action}(#{@hostname}.#{@workerpool}.#{servername})", inst3.logs.shift.message)
    }

    # creator, making server
    cmd = { hostname: @hostname,
            workerpool: @workerpool,
            server_name: servername,
            pool_cmd: 'create' }.to_json

    success = inst2.pool_exec_cmd!(JSON.parse(cmd)) {|amqp_data, rk|
      assert_equal(servername, amqp_data["server_name"])
      assert_equal("workers.#{@hostname}.#{@workerpool}", rk)
    }
    assert(success)
    inst2.logs.clear

    # creator, testing server abilities
    cmd = { hostname: @hostname,
            workerpool: @workerpool,
            server_name: servername }
    server_fqdn = "#{@hostname}.#{@workerpool}.#{servername}"

    ['start', 'stop', 'kill', 'accept_eula'].each { |action|
      cmd[:server_cmd] = action

      jsoned = cmd.to_json
      success = inst2.server_exec_cmd!(JSON.parse(jsoned)) { |amqp_data, rk|
        assert_equal(servername, amqp_data["server_name"])
        assert_equal(action, amqp_data["cmd"])
        assert_equal("workers.#{@hostname}.#{@workerpool}", rk)
      }
      assert(success)

      assert_equal("SERVER: {#{creator}} #{action}(#{server_fqdn}): OK", inst2.logs.shift.message)
    }

    # user, doing things it can't
    cmd = { hostname: @hostname,
            workerpool: @workerpool,
            server_name: servername }

    ['start', 'stop', 'kill', 'accept_eula'].each { |action|
      cmd[:server_cmd] = action

      jsoned = cmd.to_json
      success = inst3.server_exec_cmd!(JSON.parse(jsoned)) { |amqp_data, rk|
        assert_equal(servername, amqp_data["server_name"])
        assert_equal(action, amqp_data["cmd"])
        assert_equal("workers.#{@hostname}.#{@workerpool}", rk)
      }
      assert(!success)

      assert_equal("SERVER: {#{user}} #{action}(#{server_fqdn}): FAIL", inst3.logs.shift.message)
    }

    # ensure all 3 inst perform as expected
    assert(!inst.perms[server_fqdn].test_permission(owner, 'accept_eula'))
    assert(inst.perms[server_fqdn].test_permission(creator, 'accept_eula'))
    assert(!inst.perms[server_fqdn].test_permission(user, 'accept_eula'))

    assert(!inst2.perms[server_fqdn].test_permission(owner, 'accept_eula'))
    assert(inst2.perms[server_fqdn].test_permission(creator, 'accept_eula'))
    assert(!inst2.perms[server_fqdn].test_permission(user, 'accept_eula'))

    assert(!inst3.perms[server_fqdn].test_permission(owner, 'accept_eula'))
    assert(inst3.perms[server_fqdn].test_permission(creator, 'accept_eula'))
    assert(!inst3.perms[server_fqdn].test_permission(user, 'accept_eula'))

    # grant to user (1,3,2)
    assert(!inst.cast_server_perm!('grantall', user, server_fqdn))
    assert(!inst3.cast_server_perm!('grantall', user, server_fqdn))
    assert(inst2.cast_server_perm!('grantall', user, server_fqdn))

    assert(!inst.perms[server_fqdn].test_permission(owner, 'accept_eula'))
    assert(inst.perms[server_fqdn].test_permission(creator, 'accept_eula'))
    assert(inst.perms[server_fqdn].test_permission(user, 'accept_eula'))

    # (3,1,2)
    assert(!inst3.cast_server_perm!('mkgrantor', user, server_fqdn))
    assert(!inst.cast_server_perm!('mkgrantor', user, server_fqdn))
    assert(inst2.cast_server_perm!('mkgrantor', user, server_fqdn))

    # newly granted user mkgrantor, give to owner
    assert(inst3.cast_server_perm!('grantall', owner, server_fqdn))
    assert(inst.perms[server_fqdn].test_permission(owner, 'accept_eula'))
  end

  def test_alt_cmd_bad_regex
    owner = 'plain:owner'
    inst = PermManager.new(owner)

    # create a server with bad workerpool regex
    servername = 'testx'
    cmd = { hostname: @hostname,
            workerpool: @workerpool,
            server_name: servername,
            alt_cmd: 'create',
            server_cmd: 'create' }.to_json
    server_fqdn = "#{@hostname}.#{@workerpool}.#{servername}"

    success = inst.server_exec_cmd!(JSON.parse(cmd)) {}
    assert_equal("SERVER: {#{owner}} create(#{server_fqdn}): FAIL", inst.logs.shift.message)
    assert_equal("SERVER: [NOOP:poolname may not match secured-server regex] create(#{@hostname}.#{@workerpool}.#{servername})", inst.logs.shift.message)
    assert(!success)
  end

  def test_alt_cmd_mismatching_cmds
    owner = 'plain:owner'
    inst = PermManager.new(owner)

    # create a server with mismatching cmds
    servername = 'testx'
    cmd = { hostname: @hostname,
            workerpool: 'user',
            server_name: servername,
            alt_cmd: 'delete',
            server_cmd: 'create' }.to_json
    server_fqdn = "#{@hostname}.user.#{servername}"

    success = inst.server_exec_cmd!(JSON.parse(cmd)) {}
    assert_equal("SERVER: {#{owner}} create(#{server_fqdn}): FAIL", inst.logs.shift.message)
    assert_equal("SERVER: [NOOP:server_ and alt_ cmd mismatch] create(#{@hostname}.user.#{servername})", inst.logs.shift.message)
    assert(!success)
  end

  def test_alt_cmd_delete_nonexistent_server
    owner = 'plain:owner'
    inst = PermManager.new(owner)

    # delete a non-existent server
    servername = 'testx'
    cmd = { hostname: @hostname,
            workerpool: 'user',
            server_name: servername,
            alt_cmd: 'delete',
            server_cmd: 'delete' }.to_json
    server_fqdn = "#{@hostname}.user.#{servername}"

    success = inst.server_exec_cmd!(JSON.parse(cmd)) {}
    assert_equal("SERVER: {#{owner}} delete(#{server_fqdn}): FAIL", inst.logs.shift.message)
    assert_equal("SERVER: [NOOP:server doesn't exist] delete(#{@hostname}.user.#{servername})", inst.logs.shift.message)
    assert(!success)
  end

  def test_alt_cmd_create_existing_server
    owner = 'plain:owner'
    inst = PermManager.new(owner)

    # create an existing server
    servername = 'testx'
    cmd = { hostname: @hostname,
            workerpool: 'user',
            server_name: servername,
            alt_cmd: 'create',
            server_cmd: 'create' }.to_json
    server_fqdn = "#{@hostname}.user.#{servername}"

    success = inst.server_exec_cmd!(JSON.parse(cmd)) {|amqp_data, rk|
      assert_equal(servername, amqp_data["server_name"])
      assert_equal('create', amqp_data["cmd"])
      assert_equal("workers.#{@hostname}.user", rk)
    }
    assert_equal("SERVER: {#{owner}} alt_cmd_create(#{server_fqdn}): OK", inst.logs.shift.message)
    assert_equal("SERVER: {#{owner}} create(#{server_fqdn}): OK", inst.logs.shift.message)
    assert(success)
puts inst.logs

    success = inst.server_exec_cmd!(JSON.parse(cmd)) {}
    assert_equal("SERVER: {#{owner}} create(#{server_fqdn}): FAIL", inst.logs.shift.message)
    assert_equal("SERVER: [NOOP:server already exists] create(#{@hostname}.user.#{servername})", inst.logs.shift.message)
    assert(!success)
  end
end

