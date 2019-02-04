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
        @@logger.warn("PERMS: Insufficient permissions for #{user} to cast `#{fqdn}`:#{permission} on #{affected_user}")
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
end
