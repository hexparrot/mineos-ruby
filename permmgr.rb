class PermManagement
  def initialize(granting_user, logger_obj: nil, owner: nil)
    @grantor = granting_user
    @@logger = logger_obj if !defined? @@logger
    @@permissions = { root: Permissions.new(owner) } if !defined? @@permissions
    # grantor different for all, @@permissions shared!
  end

  def perms
    return @@permissions
  end

  def root_perms(permission, affected_user)
    if !@@permissions[:root].grantor?(@grantor) then
      @@logger.warn("#{@grantor} is not a root:grantor. #{permission} not granted to #{affected_user}")
      return
    end

    case permission
    when 'mkgrantor'
      @@permissions[:root].make_grantor(affected_user)
      @@logger.info("PERMS: #{@grantor} promoting #{affected_user} to `root`:grantor")
      @@logger.info("PERMS: (grantor) mkgrantor, rmgrantor (:all) grantall, revokeall")
      # effectively makes #affected_user as powerful as #user in regards to
      # full administration of the hq
    when 'rmgrantor'
      @@permissions[:root].unmake_grantor(affected_user)
      @@logger.info("PERMS: #{@grantor} revoking `root`:grantor from #{affected_user}")
      @@logger.info("PERMS: (grantor) mkgrantor, rmgrantor (:all) grantall, revokeall")
    when 'grantall'
      @@permissions[:root].grant(affected_user, :all)
      @@logger.info("PERMS: #{@grantor} granting `root`:all to #{affected_user}")
      @@logger.info("PERMS: (:all) mkpool, rmpool, spawn, despawn")
      # allows #affected_user to create and destroy pools (remote users on all hosts)
    when 'revokeall'
      @@permissions[:root].revoke(affected_user, :all)
      @@logger.info("PERMS: #{@grantor} revoking `root`:all from #{affected_user}" )
      @@logger.info("PERMS: (:all) mkpool, rmpool, spawn, despawn")
    end
  end

  def pool_perms(permission, affected_user, fqdn)
    # Permissions within:
    # * create server
    # * delete server
    # * grantor: can grant create/delete to other users

    begin
      if !@@permissions.fetch(fqdn).grantor?(@grantor) then
        @@logger.warn( "PERMS: Insufficient permissions for #{@grantor} to cast `#{fqdn}`:#{permission} on #{affected_user}")
        return #early exit if user is not a grantor!
      end
    rescue KeyError
      @@logger.warn("PERMS: #{@grantor} cannot perform #{permission} on non-existent pool `#{fqdn}`")
      return
    end

    # now, assuming @@@permissions[fqdn] exists
    case permission
    when 'mkgrantor'
      @@permissions[fqdn].make_grantor(affected_user)
      @@logger.info("PERMS: #{@grantor} promoting #{affected_user} to `#{fqdn}`:grantor")
      @@logger.info("PERMS: (grantor) mkgrantor, rmgrantor (:all) create, delete")
      # allows #affected user to give ability to create/delete to others
    when 'rmgrantor'
      @@permissions[fqdn].unmake_grantor(affected_user)
      @@logger.info("PERMS: #{@grantor} revoking from #{affected_user} `#{fqdn}`:grantor")
      @@logger.info("PERMS: (grantor) mkgrantor, rmgrantor (:all) create, delete")
    when 'grantall'
      @@permissions[fqdn].grant(affected_user, :all)
      @@logger.info("PERMS: #{@grantor} granting #{affected_user} `#{fqdn}`:all")
      @@logger.info("PERMS: (:all) create, delete")
      # allows #affected_user to create and destroy servers
    when 'revokeall'
      @@permissions[fqdn].revoke(affected_user, :all)
      @@logger.info("PERMS: #{@grantor} revoking from #{affected_user} on `#{fqdn}`:all")
      @@logger.info("PERMS: (:all) create, delete")
    end
  end

  def server_perms(permission, affected_user, fqdn)
    # Permissions within:
    # * modify_sc, modify_sp, start, stop, eula, etc.
    # * grantor: can grant server-commands to users

    begin
      if !@@permissions.fetch(fqdn).grantor?(@grantor) then
        @@logger.warn("PERMS: Insufficient permissions for #{@grantor} to cast `#{fqdn}`:#{permission} on #{affected_user}")
        return #early exit if user is not a grantor!
      end
    rescue KeyError
      @@logger.warn("PERMS: #{@grantor} cannot perform #{permission} on non-existent server `#{fqdn}`")
      return
    end

    # and assuming @@permission[fqdn] has a server
    case permission
    when 'mkgrantor'
      @@permissions[fqdn].make_grantor(affected_user)
      @@logger.info("PERMS: #{@grantor} promoting #{affected_user} to grantor `#{fqdn}`:grantor")
      @@logger.info("PERMS: (grantor) mkgrantor, rmgrantor (:all) start, stop, etc.")
      # allows #affected user to give ability to start/stop servers
    when 'rmgrantor'
      @@permissions[fqdn].unmake_grantor(affected_user)
      @@logger.info("PERMS: #{@grantor} revoking from #{affected_user} `#{fqdn}`:grantor")
      @@logger.info("PERMS: (grantor) mkgrantor, rmgrantor (:all) create, delete")
    when 'grantall'
      @@permissions[fqdn].grant(affected_user, :all)
      @@logger.info("PERMS: #{@grantor} granting #{affected_user} on `#{fqdn}`:all")
      @@logger.info("PERMS: (:all) start, stop, etc.")
      # allows #affected_user to create and destroy servers
    when 'revokeall'
      @@permissions[fqdn].revoke(affected_user, :all)
      @@logger.info("PERMS: #{@grantor} revoking from #{affected_user} on `#{fqdn}`:all")
      @@logger.info("PERMS: (:all) start, stop, etc.")
    end
  end

  ### commands

  def server_command(params)
    hostname = params.delete('hostname')
    workerpool = params.delete('workerpool')
    worker_routing_key = "workers.#{hostname}.#{workerpool}"

    servername = params.fetch('server_name')
    fqdn = "#{hostname}.#{workerpool}.#{servername}"

    command = params['server_cmd']
    alt_cmd = params['alt_cmd']
    params.delete('alt_cmd') if alt_cmd

    if alt_cmd == 'create' then
      require_relative 'pools'
      if Pools::VALID_NAME_REGEX.match(workerpool) then
        # valid pool names may not be addressed directly
        @@logger.error("PERMS: Invalid create server (msg directed to direct-worker, but may not match pool regex)")
        return
      end

      if @@permissions[fqdn] then
        @@logger.error("PERMS: Permissions already exist for direct-worker create command. NOOP")
        @@logger.debug(params)
        return
      else
        # if direct-worker is still a valid request, create the permscreen
        perm_obj = Permissions.new(@grantor)
        perm_obj.hostname = hostname
        perm_obj.workerpool = workerpool
        perm_obj.servername = servername
        perm_obj.grant(@grantor, :all)
        @@permissions[fqdn] = perm_obj
        @@logger.info("PERMS: CREATE SERVER (via alt_cmd) `#{servername} => #{worker_routing_key}`")
      end
    end

    begin
      @@permissions.fetch(fqdn)
    rescue KeyError
      @@logger.error("POOL: Cannot execute #{command} on a non-existent server `#{fqdn}`")
      return
    end

    if @@permissions[fqdn].test_permission(@grantor, command) then
      if alt_cmd == 'delete' then
        # inside if @@perms because it's about to get deleted
        require_relative 'pools'
        if Pools::VALID_NAME_REGEX.match(workerpool) then
          # valid pool names may not be addressed directly
          @@logger.error("PERMS: Invalid delete server (msg directed to direct-worker, but may not match pool regex)")
          return
        end

        if @@permissions[fqdn] then
          @@permissions.delete(fqdn)
          @@logger.info("PERMS: DELETE SERVER (via alt_cmd) `#{servername} => #{worker_routing_key}`")
        else
          @@logger.error("PERMS: Permissions don't exist for direct-worker delete command. NOOP")
          @@logger.debug(params)
        end
      end

      params['cmd'] = params.delete('server_cmd')
      @@logger.info("PERMS: #{command} by #{@grantor}@#{fqdn}: OK")

      xmitted = yield(params, worker_routing_key)
      @@logger.info("HQ: Forwarded command `#{worker_routing_key}`") if xmitted
      @@logger.debug(params) if xmitted
    else
      @@logger.warn("PERMS: #{command} by #{@grantor}@#{fqdn}: FAIL")
    end
  end


  def pool_command(params)
    hostname = params.delete('hostname')
    workerpool = params.delete('workerpool')
    manager_routing_key = "managers.#{hostname}"
    fqdn = "#{hostname}.#{workerpool}"

    command = params.fetch('pool_cmd')

    begin
      @@permissions.fetch(fqdn)
    rescue KeyError
      @@logger.error("POOL: Cannot create server in a non-existent pool `#{fqdn}`")
      return
    end

    if @@permissions[fqdn].test_permission(@grantor, command) then
      @@logger.info("PERMS: #{command} by #{@grantor}@#{fqdn}: OK")

      worker_routing_key = "workers.#{hostname}.#{workerpool}"
      servername = params.fetch('server_name')
      params['cmd'] = params.delete('pool_cmd')
      server_fqdn = "#{hostname}.#{workerpool}.#{servername}"

      case command
      when 'create'
        if @@permissions[server_fqdn] then #early exit
          @@logger.error("POOL: Server already exists, #{command} ignored: `#{server_fqdn}`")
          return
        end

        perm_obj = Permissions.new(@grantor)
        perm_obj.hostname = hostname
        perm_obj.workerpool = workerpool
        perm_obj.servername = servername
        perm_obj.grant(@grantor, :all)
        @@permissions[server_fqdn] = perm_obj

        xmitted = yield(params, worker_routing_key)
        @@logger.info("POOL: CREATE SERVER `#{servername} => #{worker_routing_key}`") if xmitted
      when 'delete'
        if !@@permissions[server_fqdn] then #early exit
          @@logger.error("POOL: Server doesn't exist, #{command} ignored: `#{server_fqdn}`")
          return
        end
        @@permissions.delete(server_fqdn)

        xmitted = yield(params, worker_routing_key)
        @@logger.info("POOL: DELETE SERVER `#{servername} => #{worker_routing_key}`") if xmitted
      else
        @@logger.info("PERMS: #{command} by #{@grantor}@#{fqdn}: FAIL")
      end
    end
  end

  def root_command(params)
    hostname = params.delete('hostname')
    manager_routing_key = "managers.#{hostname}"

    workerpool = params.fetch('workerpool')
    command = params.fetch('root_cmd')
    pool_fqdn = "#{hostname}.#{workerpool}"

    if !@@permissions[:root].test_permission(@grantor, command) then
      @@logger.warn("PERMS: #{command} by #{@grantor}@#{workerpool}: FAIL")
      return
    end

    case command
    when 'mkpool'
      begin
        if @@permissions.fetch(pool_fqdn) then
          @@logger.error("POOL: Pool already exists: #{command} ignored `#{pool_fqdn}`")
          return
        end
      rescue KeyError
        perm_obj = Permissions.new(@grantor)
        perm_obj.hostname = hostname
        perm_obj.workerpool = workerpool
        perm_obj.grant(@grantor, :all)

        @@permissions[pool_fqdn] = perm_obj
        @@logger.info("PERMS: CREATED PERMSCREEN `#{workerpool} => #{manager_routing_key}`")
      end

      xmitted = yield({ MKPOOL: {workerpool: workerpool} }, manager_routing_key)
      @@logger.info("MANAGER: MKPOOL `#{workerpool} => #{manager_routing_key}`") if xmitted
    when 'rmpool'
      begin
        @@permissions.fetch(pool_fqdn)
      rescue KeyError
        @@logger.warn("PERMS: NO EXISTING PERMSCREEN `#{workerpool} => #{manager_routing_key}` - NOOP")
        return
      end

      @@permissions.delete(pool_fqdn)
      @@logger.info("POOL: DELETED PERMSCREEN`#{workerpool} => #{manager_routing_key}`")

      xmitted = yield({ REMOVE: {workerpool: workerpool} }, manager_routing_key)
      @@logger.info("POOL: DELETED `#{workerpool} => #{manager_routing_key}`") if xmitted
    when 'spawnpool'
      begin
        @@permissions.fetch(pool_fqdn)
      rescue KeyError
        @@logger.error("POOL: Cannot spawn worker in non-existent pool `#{pool_fqdn}`")
        return
      end

      xmitted = yield({ SPAWN: {workerpool: workerpool} }, manager_routing_key)
      @@logger.info("MANAGER: SPAWNED POOL `#{workerpool} => #{manager_routing_key}`") if xmitted
    when 'despawnpool'
      #not yet implemented
    end
  end
end

