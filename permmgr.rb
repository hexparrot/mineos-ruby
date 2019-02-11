require_relative 'perms'
require 'logger'

LogItem = Struct.new("LogItem", :level, :message, :uuid)

class PermManager
  attr_reader :granting_user, :logs

  def initialize(granting_user)
    # grantor different for all, @@permissions shared!
    @granting_user = granting_user
    @logger = Logger.new(STDOUT)
    @logs = []

    if !defined? @@admin then
      @@admin = granting_user
      @@permissions = { root: Permissions.new(granting_user) }
    end
  end

  def to_s
    require 'yaml'
    @@permissions.to_yaml
  end

  def admin
    @@admin
  end

  def perms
    @@permissions
  end

  def set_logger(new_logger)
    raise TypeError.new('PermManager requires a kind_of logger instance') if !new_logger.kind_of?(Logger)
    @logger = new_logger
  end

  def fork_log(level, message, uuid='')
    @logs.push(Struct::LogItem.new(level, message, uuid))
    #@logger.send(level, message) #temporarily suspend logging for testing
  end

  def cast_root_perm!(permission, affected_user)
    if !@@permissions[:root].grantor?(@granting_user) then
      fork_log :warn, "#{@granting_user} is not a root:grantor. #{permission} not granted to #{affected_user}"
      return false
    end

    case permission
    when 'mkgrantor'
      @@permissions[:root].make_grantor(affected_user)
      fork_log :info, "PERMS: #{@granting_user} promoting #{affected_user} to `root`:grantor"
      fork_log :info, "PERMS: (grantor) mkgrantor, rmgrantor (:all) grantall, revokeall"
      # effectively makes #affected_user as powerful as #user in regards to
      # full administration of the hq
    when 'rmgrantor'
      @@permissions[:root].unmake_grantor(affected_user)
      fork_log :info, "PERMS: #{@granting_user} revoking `root`:grantor from #{affected_user}"
      fork_log :info, "PERMS: (grantor) mkgrantor, rmgrantor (:all) grantall, revokeall"
    when 'grantall'
      @@permissions[:root].grant(affected_user, :all)
      fork_log :info, "PERMS: #{@granting_user} granting `root`:all to #{affected_user}"
      fork_log :info, "PERMS: (:all) mkpool, rmpool, spawn, despawn"
      # allows #affected_user to create and destroy pools (remote users on all hosts)
    when 'revokeall'
      @@permissions[:root].revoke(affected_user, :all)
      fork_log :info, "PERMS: #{@granting_user} revoking `root`:all from #{affected_user}" 
      fork_log :info, "PERMS: (:all) mkpool, rmpool, spawn, despawn"
    else
      return false
    end
    true
  end

  def cast_pool_perm!(permission, affected_user, fqdn)
    # Permissions within:
    # * create server
    # * delete server
    # * grantor: can grant create/delete to other users

    begin
      if !@@permissions.fetch(fqdn).grantor?(@granting_user) then
        fork_log :warn,  "PERMS: Insufficient permissions for #{@granting_user} to cast `#{fqdn}`:#{permission} on #{affected_user}"
        return #early exit if user is not a grantor!
      end
    rescue KeyError
      fork_log :warn, "PERMS: #{@granting_user} cannot perform #{permission} on non-existent pool `#{fqdn}`"
      return
    end

    # now, assuming @@@permissions[fqdn] exists
    case permission
    when 'mkgrantor'
      @@permissions[fqdn].make_grantor(affected_user)
      fork_log :info, "PERMS: #{@granting_user} promoting #{affected_user} to `#{fqdn}`:grantor"
      fork_log :info, "PERMS: (grantor) mkgrantor, rmgrantor (:all) create, delete"
      # allows #affected user to give ability to create/delete to others
    when 'rmgrantor'
      @@permissions[fqdn].unmake_grantor(affected_user)
      fork_log :info, "PERMS: #{@granting_user} revoking from #{affected_user} `#{fqdn}`:grantor"
      fork_log :info, "PERMS: (grantor) mkgrantor, rmgrantor (:all) create, delete"
    when 'grantall'
      @@permissions[fqdn].grant(affected_user, :all)
      fork_log :info, "PERMS: #{@granting_user} granting #{affected_user} `#{fqdn}`:all"
      fork_log :info, "PERMS: (:all) create, delete"
      # allows #affected_user to create and destroy servers
    when 'revokeall'
      @@permissions[fqdn].revoke(affected_user, :all)
      fork_log :info, "PERMS: #{@granting_user} revoking from #{affected_user} on `#{fqdn}`:all"
      fork_log :info, "PERMS: (:all) create, delete"
    else
      false
    end
    true
  end

  def cast_server_perm!(permission, affected_user, fqdn)
    # Permissions within:
    # * modify_sc, modify_sp, start, stop, eula, etc.
    # * grantor: can grant server-commands to users

    begin
      if !@@permissions.fetch(fqdn).grantor?(@granting_user) then
        fork_log :warn, "PERMS: Insufficient permissions for #{@granting_user} to cast `#{fqdn}`:#{permission} on #{affected_user}"
        return #early exit if user is not a grantor!
      end
    rescue KeyError
      fork_log :warn, "PERMS: #{@granting_user} cannot perform #{permission} on non-existent server `#{fqdn}`"
      return
    end

    # and assuming @@permission[fqdn] has a server
    case permission
    when 'mkgrantor'
      @@permissions[fqdn].make_grantor(affected_user)
      fork_log :info, "PERMS: #{@granting_user} promoting #{affected_user} to grantor `#{fqdn}`:grantor"
      fork_log :info, "PERMS: (grantor) mkgrantor, rmgrantor (:all) start, stop, etc."
      # allows #affected user to give ability to start/stop servers
    when 'rmgrantor'
      @@permissions[fqdn].unmake_grantor(affected_user)
      fork_log :info, "PERMS: #{@granting_user} revoking from #{affected_user} `#{fqdn}`:grantor"
      fork_log :info, "PERMS: (grantor) mkgrantor, rmgrantor (:all) create, delete"
    when 'grantall'
      @@permissions[fqdn].grant(affected_user, :all)
      fork_log :info, "PERMS: #{@granting_user} granting #{affected_user} on `#{fqdn}`:all"
      fork_log :info, "PERMS: (:all) start, stop, etc."
      # allows #affected_user to create and destroy servers
    when 'revokeall'
      @@permissions[fqdn].revoke(affected_user, :all)
      fork_log :info, "PERMS: #{@granting_user} revoking from #{affected_user} on `#{fqdn}`:all"
      fork_log :info, "PERMS: (:all) start, stop, etc."
    end
  end

  ### commands

  def server_exec_cmd!(params)
    hostname = params.delete('hostname')
    workerpool = params.delete('workerpool')
    worker_routing_key = "workers.#{hostname}.#{workerpool}"

    servername = params.fetch('server_name')
    fqdn = "#{hostname}.#{workerpool}.#{servername}"

    command = params['server_cmd']
    alt_cmd = params['alt_cmd']
    params.delete('alt_cmd') if alt_cmd

    if alt_cmd && alt_cmd != command then
      fork_log :error, "SERVER: {#{@granting_user}} #{command}(#{fqdn}): FAIL"
      fork_log :error, "SERVER: [NOOP:server_ and alt_ cmd mismatch] #{command}(#{fqdn})"
      return
    end

    if alt_cmd == 'create' then
      require_relative 'pools'
      if Pools::VALID_NAME_REGEX.match(workerpool) then
        # valid pool names may not be addressed directly
        fork_log :error, "SERVER: {#{@granting_user}} create(#{fqdn}): FAIL"
        fork_log :error, "SERVER: [NOOP:poolname may not match secured-server regex] create(#{fqdn})"
        return
      end

      if @@permissions[fqdn] then
        fork_log :error, "SERVER: {#{@granting_user}} create(#{fqdn}): FAIL"
        fork_log :error, "SERVER: [NOOP:server already exists] create(#{fqdn})"
        return
      else
        # if direct-worker is still a valid request, create the permscreen
        perm_obj = Permissions.new(@granting_user)
        perm_obj.hostname = hostname
        perm_obj.workerpool = workerpool
        perm_obj.servername = servername
        perm_obj.grant(@granting_user, :all)
        @@permissions[fqdn] = perm_obj
        fork_log :info, "SERVER: {#{@granting_user}} alt_cmd_create(#{fqdn}): OK"
      end
    end

    begin
      @@permissions.fetch(fqdn)
    rescue KeyError
      fork_log :error, "SERVER: {#{granting_user}} #{command}(#{fqdn}): FAIL"
      fork_log :error, "SERVER: [NOOP:server doesn't exist] #{command}(#{fqdn})"
      return
    end

    if @@permissions[fqdn].test_permission(@granting_user, command) then
      if alt_cmd == 'delete' then
        # inside if @@perms because it's about to get deleted
        require_relative 'pools'
        if Pools::VALID_NAME_REGEX.match(workerpool) then
          # valid pool names may not be addressed directly
          fork_log :error, "SERVER: {#{@granting_user}} alt_cmd_delete(ruby-worker.user.testx): FAIL"
          fork_log :error, "SERVER: [NOOP:poolname may not match secured-server regex] #{command}(#{fqdn})"
          return
        end

        @@permissions.delete(fqdn)
        fork_log :info, "SERVER: {#{@granting_user}} alt_cmd_delete(#{fqdn}): OK"
      end

      params['cmd'] = params.delete('server_cmd')
      fork_log :info, "SERVER: {#{@granting_user}} #{command}(#{fqdn}): OK"

      yield(params, worker_routing_key)
      true
    else
      fork_log :error, "SERVER: {#{@granting_user}} #{command}(#{fqdn}): FAIL"
      false
    end
  end

  def pool_exec_cmd!(params)
    hostname = params.delete('hostname')
    workerpool = params.delete('workerpool')
    manager_routing_key = "managers.#{hostname}"
    fqdn = "#{hostname}.#{workerpool}"

    command = params.fetch('pool_cmd')

    begin
      @@permissions.fetch(fqdn)
    rescue KeyError
      fork_log :error, "POOL: Cannot create server in a non-existent pool `#{fqdn}`"
      return
    end

    if @@permissions[fqdn].test_permission(@granting_user, command) then
      worker_routing_key = "workers.#{hostname}.#{workerpool}"
      params['cmd'] = params.delete('pool_cmd')
      servername = params.fetch('server_name')
      server_fqdn = "#{hostname}.#{workerpool}.#{servername}"

      case command
      when 'create'
        if @@permissions[server_fqdn] then #early exit
          fork_log :error, "POOL: {#{@granting_user}} create_server(#{hostname}.#{workerpool}.#{servername}): FAIL"
          fork_log :error, "POOL: [NOOP:server already exists] create_server(#{hostname}.#{workerpool}.#{servername})"
          return
        end

        perm_obj = Permissions.new(@granting_user)
        perm_obj.hostname = hostname
        perm_obj.workerpool = workerpool
        perm_obj.servername = servername
        perm_obj.grant(@granting_user, :all)
        @@permissions[server_fqdn] = perm_obj

        xmitted = yield(params, worker_routing_key)
        fork_log :info, "POOL: {#{@granting_user}} create_server(#{hostname}.#{workerpool}.#{servername}): OK" if xmitted
        return xmitted
      when 'delete'
        if !@@permissions[server_fqdn] then #early exit
          fork_log :error, "POOL: {#{@granting_user}} delete_server(#{hostname}.#{workerpool}.#{servername}): FAIL"
          fork_log :error, "POOL: [NOOP:server doesn't exist] delete_server(#{hostname}.#{workerpool}.#{servername})"
          return
        end
        @@permissions.delete(server_fqdn)

        xmitted = yield(params, worker_routing_key)
        fork_log :info, "POOL: {#{@granting_user}} delete_server(#{hostname}.#{workerpool}.#{servername}): OK" if xmitted
        return xmitted
      else #case
        return false
      end
      xmitted
    else
      servername = params.fetch('server_name')
      fork_log :error, "POOL: {#{@granting_user}} delete_server(#{hostname}.#{workerpool}.#{servername}): FAIL"
      return false
    end
  end

  def root_exec_cmd!(params)
    hostname = params.delete('hostname')
    manager_routing_key = "managers.#{hostname}"

    workerpool = params.fetch('workerpool')
    command = params.fetch('root_cmd')
    pool_fqdn = "#{hostname}.#{workerpool}"

    if !@@permissions[:root].test_permission(@granting_user, command) then
      fork_log :error, "PERMS: {#{granting_user}} #{command}(#{hostname}.#{workerpool}): FAIL"
      return
    end

    case command
    when 'mkpool'
      begin
        if @@permissions.fetch(pool_fqdn) then
          fork_log :error, "POOL: {#{granting_user}} mkpool(#{pool_fqdn}): FAIL"
          fork_log :error, "POOL: [NOOP:pool already exists] mkpool(#{pool_fqdn})"
          return
        end
      rescue KeyError
        perm_obj = Permissions.new(@granting_user)
        perm_obj.hostname = hostname
        perm_obj.workerpool = workerpool
        perm_obj.grant(@granting_user, :all)

        @@permissions[pool_fqdn] = perm_obj
        fork_log :info, "PERMS: {#{@granting_user}} create_permscreen(#{pool_fqdn})"
      end

      xmitted = yield({ MKPOOL: {workerpool: workerpool} }, manager_routing_key)
      fork_log :info, "PERMS: {#{granting_user}} granted :all on (#{pool_fqdn})"
      fork_log :info, "PERMS: (:all) mkpool, rmpool, spawn, despawn"
      fork_log :info, "POOL: {#{granting_user}} mkpool(#{pool_fqdn}): OK"
    when 'rmpool'
      begin
        @@permissions.fetch(pool_fqdn)
      rescue KeyError
        fork_log :error, "POOL: {#{granting_user}} rmpool(#{pool_fqdn}): FAIL"
        fork_log :error, "POOL: [NOOP:pool doesn't exist] rmpool(#{pool_fqdn})"
        return
      end

      @@permissions.delete(pool_fqdn)
      fork_log :info, "POOL: delete_permscreen(#{pool_fqdn}): OK"

      xmitted = yield({ RMPOOL: {workerpool: workerpool} }, manager_routing_key)
      fork_log :info, "POOL: {#{granting_user}} rmpool(#{pool_fqdn}): OK" if xmitted
    when 'spawnpool'
      begin
        @@permissions.fetch(pool_fqdn)
      rescue KeyError
        fork_log :error, "POOL: Cannot spawn worker in non-existent pool `#{pool_fqdn}`"
        return
      end

      xmitted = yield({ SPAWN: {workerpool: workerpool} }, manager_routing_key)
      fork_log :info, "MANAGER: SPAWNED POOL `#{workerpool} => #{manager_routing_key}`" if xmitted
    when 'despawnpool'
      #not yet implemented
    end
  end
end

