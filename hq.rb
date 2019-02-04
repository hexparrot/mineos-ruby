require 'sinatra/async'
require 'sinatra-websocket'
require 'json'
require 'securerandom'
require_relative 'perms'

SOCKET = Struct.new("Socket", :websocket, :user)

class HQ < Sinatra::Base
  set :server, :thin
  set :sockets, []
  set :bind, '0.0.0.0'
  register Sinatra::Async
  enable :show_exceptions
  enable :sessions

  require 'set'
  @@satellites = { :workers => Set.new, :managers => Set.new }
  @@users = []

  promises = {}

  require 'openssl'
  rsa_key = OpenSSL::PKey::RSA.generate(2048)

  require 'logger'
  logger = Logger.new(STDOUT)
  logger.datetime_format = '%Y-%m-%d %H:%M:%S'
  logger.level = Logger::DEBUG

  require_relative 'permmgr'
  @@perm_mgr = PermManagement.new('plain:mc', logger_obj: logger, owner: 'plain:mc')

  require 'yaml'
  amqp_creds = YAML::load_file('config/amqp.yml')['rabbitmq'].transform_keys(&:to_sym)
  logger.info("AMQP: Using credentials from location `config/amqp.yml`")
  s3_config = YAML::load_file('config/objstore.yml')
  logger.info("S3: Using credentials from location `config/objstore.yml`")

  require 'bunny'
  conn = Bunny.new(amqp_creds)
  conn.start
  logger.debug("AMQP: Connection to AMQP service successful")
  
  ch = conn.create_channel

  # exchange for directives (hostname specific)
  exchange = ch.topic("backend")
  logger.debug("AMQP: Attached to exchange: `backend`")

  # exchange for stdout
  exchange_stdout = ch.direct('stdout')
  logger.debug("AMQP: Attached to exchange: `stdout`")

  # AMQP handling
  ch
  .queue('', exclusive: true)
  .bind(exchange_stdout, :routing_key => "hq")
  .subscribe do |delivery_info, metadata, payload|
    parsed = JSON.parse payload

    settings.sockets.each { |ws|
      user = "#{ws.user.authtype}:#{ws.user.id}"
      fqdn = "#{metadata[:headers]['hostname']}.#{metadata[:headers]['workerpool']}.#{parsed['server_name']}"

      if @@perm_mgr.perms[fqdn].test_permission(user, :console) then
        ws.websocket.send(payload)
      end
    }
  end

  ch
  .queue('hq', exclusive: true)
  .bind(exchange, :routing_key => "hq")
  .subscribe do |delivery_info, metadata, payload|

    inbound_command = Proc.new do |delivery_info, metadata, payload|
      if metadata[:headers]['exception'] then
        promises[metadata.correlation_id].call 400, payload
      elsif parsed['cmd'] == 'create' then
        promises[metadata.correlation_id].call 201, payload
      else
        promises[metadata.correlation_id].call 200, payload
      end
    end

    inbound_directive = Proc.new do |delivery_info, metadata, payload|
      case metadata[:headers]['directive']
      when 'IDENT'
        parsed = JSON.parse payload

        if parsed.key?("workerpool") then
          # :workerpool's only exists only from worker satellite
          routing_key = "workers.#{parsed['hostname']}.#{parsed['workerpool']}"

          if @@satellites[:workers].include?(routing_key) then
            # worker already registered

            logger.debug("IDENT: Worker heartbeat `#{routing_key}`")
          else
            # new worker process registration, ask to verify OBJSTORE

            @@satellites[:workers].add(routing_key)
            logger.info("IDENT: Worker registered `#{routing_key}`")
            exchange.publish('ACK',
                             :routing_key => routing_key,
                             :type => "receipt.directive",
                             :message_id => SecureRandom.uuid,
                             :correlation_id => metadata[:message_id],
                             :headers => { directive: 'IDENT' },
                             :timestamp => Time.now.to_i)
          end

          # every hq-received IDENT should come with verification of OBJSTORE
          exchange.publish('VERIFY_OBJSTORE',
                           :routing_key => routing_key,
                           :type => "directive",
                           :message_id => SecureRandom.uuid,
                           :timestamp => Time.now.to_i)
          logger.info("VERIFY_OBJSTORE: Request sent to `#{routing_key}`")
        else
          # workerpool key absence implies mrmanager satellite
          routing_key = "managers.#{parsed['hostname']}"

          if @@satellites[:managers].include?(routing_key) then
            # mrmanager already registered
            logger.debug("IDENT: Manager heartbeat `#{routing_key}`")
          else
            @@satellites[:managers].add(routing_key)
            logger.info("IDENT: Manager registered `#{routing_key}`")
          end
        end # if parsed.key?("workerpool")

      when 'VERIFY_OBJSTORE'
        routing_key = "workers.#{metadata[:headers]['hostname']}.#{metadata[:headers]['workerpool']}"

        if payload == '' then
          logger.info("VERIFY_OBJSTORE: returned, creds absent. Sending AWSCREDS to `#{routing_key}`")
          # on receipt of non-true VERIFY_OBJSTORE, send object store creds
          exchange.publish({ AWSCREDS: {
                               endpoint: s3_config['object_store']['host'],
                               access_key_id: s3_config['object_store']['access_key'],
                               secret_access_key: s3_config['object_store']['secret_key'],
                               region: 'us-west-1'
                             }
                           }.to_json,
                           :routing_key => routing_key,
                           :type => "directive",
                           :headers => { directive: 'VERIFY_OBJSTORE' },
                           :correlation_id => metadata[:message_id],
                           :message_id => SecureRandom.uuid,
                           :timestamp => Time.now.to_i)
        else
          # truthy responses do not need follow up
          logger.debug("VERIFY_OBJSTORE: returned, creds present. NOOP `#{routing_key}`")
        end
      end # case
    end # inbound_directive

    if metadata[:headers]['command'] then
      inbound_command.call(delivery_info, metadata, payload)
    elsif metadata[:headers]['directive'] then
      inbound_directive.call(delivery_info, metadata, payload)
    end
  end # subscribe

## route handlers

  get '/' do
    if !current_user then
      send_file File.join('public', 'login.html')
      next
    end

    if !request.websocket? then
      send_file File.join('public', 'index.html')
      next
    end

    request.websocket do |ws|
      # WEBSOCKET INIT
      ws.onopen do
        settings.sockets << Struct::Socket.new(ws, current_user)
      end

      # WEBSOCKET ON-RECEIVE
      ws.onmessage do |msg|
        user = "#{current_user.authtype}:#{current_user.id}"

        require_relative 'permmgr'
        perm_mgr = PermManagement.new user

        ### DIRECTIVE PROCESSING
        server_command = Proc.new do |params|
          hostname = params.delete('hostname')
          workerpool = params.delete('workerpool')
          worker_routing_key = "workers.#{hostname}.#{workerpool}"

          servername = params.fetch('server_name')
          fqdn = "#{hostname}.#{workerpool}.#{servername}"

          if !@@satellites[:workers].include?(worker_routing_key) then
            logger.error("WORKER: Unregistered worker addressed `#{user} => #{worker_routing_key}`")
            next
          end

          command = params['server_cmd']

          alt_cmd = params['alt_cmd']
          params.delete('alt_cmd') if alt_cmd

          if alt_cmd == 'create' then
            require_relative 'pools'
            if Pools::VALID_NAME_REGEX.match(workerpool) then
              # valid pool names may not be addressed directly
              logger.error("PERMS: Invalid create server (msg directed to direct-worker, but may not match pool regex)")
              next
            end

            if perm_mgr.perms[fqdn] then
              logger.error("PERMS: Permissions already exist for direct-worker create command. NOOP")
              logger.debug(params)
              next
            else
              # if direct-worker is still a valid request, create the permscreen
              perm_obj = Permissions.new(user)
              perm_obj.hostname = hostname
              perm_obj.workerpool = workerpool
              perm_obj.servername = servername
              perm_obj.grant(user, :all)
              perm_mgr.perms[fqdn] = perm_obj
              logger.info("PERMS: CREATE SERVER (via alt_cmd) `#{servername} => #{worker_routing_key}`")
            end
          end

          begin
            perm_mgr.perms.fetch(fqdn)
          rescue KeyError
            logger.error("POOL: Cannot execute #{command} on a non-existent server `#{fqdn}`")
            next
          end

          if perm_mgr.perms[fqdn].test_permission(user, command) then
            if alt_cmd == 'delete' then
              # inside if @@perms because it's about to get deleted
              require_relative 'pools'
              if Pools::VALID_NAME_REGEX.match(workerpool) then
                # valid pool names may not be addressed directly
                logger.error("PERMS: Invalid delete server (msg directed to direct-worker, but may not match pool regex)")
                next
              end

              if perm_mgr.perms[fqdn] then
                perm_mgr.perms.delete(fqdn)
                logger.info("PERMS: DELETE SERVER (via alt_cmd) `#{servername} => #{worker_routing_key}`")
              else
                logger.error("PERMS: Permissions don't exist for direct-worker delete command. NOOP")
                logger.debug(params)
              end
            end

            params['cmd'] = params.delete('server_cmd')
            logger.info("PERMS: #{command} by #{user}@#{fqdn}: OK")

            uuid = SecureRandom.uuid
            promises[uuid] = Proc.new { |status_code, retval|
              ws.send(retval)
            }

            exchange.publish(params.to_json,
                             :routing_key => worker_routing_key,
                             :type => "command",
                             :message_id => uuid,
                             :timestamp => Time.now.to_i)
            logger.info("POOL: Forwarded command `#{worker_routing_key}`")
            logger.debug(params)
          else
            logger.warn("PERMS: #{command} by #{user}@#{fqdn}: FAIL")
          end
        end

        pool_command = Proc.new do |params|
          hostname = params.delete('hostname')
          workerpool = params.delete('workerpool')
          manager_routing_key = "managers.#{hostname}"
          fqdn = "#{hostname}.#{workerpool}"

          command = params.fetch('pool_cmd')

          if !@@satellites[:managers].include?(manager_routing_key) then
            logger.error("MANAGER: Unregistered manager addressed `#{user} => #{manager_routing_key}`")
            next
          end

          begin
            perm_mgr.perms.fetch(fqdn)
          rescue KeyError
            logger.error("POOL: Cannot create server in a non-existent pool `#{fqdn}`")
            next
          end

          if perm_mgr.perms[fqdn].test_permission(user, command) then
            logger.info("PERMS: #{command} by #{user}@#{fqdn}: OK")

            uuid = SecureRandom.uuid
            promises[uuid] = Proc.new { |status_code, retval|
              ws.send(retval)
            }

            worker_routing_key = "workers.#{hostname}.#{workerpool}"
            servername = params.fetch('server_name')
            params['cmd'] = params.delete('pool_cmd')
            server_fqdn = "#{hostname}.#{workerpool}.#{servername}"

            case command
            when 'create'
              if perm_mgr.perms[server_fqdn] then #early exit
                logger.error("POOL: Server already exists, #{command} ignored: `#{server_fqdn}`")
                next
              end

              perm_obj = Permissions.new(user)
              perm_obj.hostname = hostname
              perm_obj.workerpool = workerpool
              perm_obj.servername = servername
              perm_obj.grant(user, :all)
              perm_mgr.perms[server_fqdn] = perm_obj

              exchange.publish(params.to_json,
                               :routing_key => worker_routing_key,
                               :type => "command",
                               :message_id => uuid,
                               :timestamp => Time.now.to_i)
              logger.info("POOL: CREATE SERVER `#{servername} => #{worker_routing_key}`")
            when 'delete'
              if !perm_mgr.perms[server_fqdn] then #early exit
                logger.error("POOL: Server doesn't exist, #{command} ignored: `#{server_fqdn}`")
                next
              end
              perm_mgr.perms.delete(server_fqdn)

              exchange.publish(params.to_json,
                               :routing_key => worker_routing_key,
                               :type => "command",
                               :message_id => uuid,
                               :timestamp => Time.now.to_i)
              logger.info("POOL: DELETE SERVER `#{servername} => #{worker_routing_key}`")
            end
          else
            logger.info("PERMS: #{command} by #{user}@#{fqdn}: FAIL")
          end
        end

        root_command = Proc.new do |params|
          hostname = params.delete('hostname')
          manager_routing_key = "managers.#{hostname}"

          workerpool = params.fetch('workerpool')
          command = params.fetch('root_cmd')
          pool_fqdn = "#{hostname}.#{workerpool}"

          if !@@satellites[:managers].include?(manager_routing_key) then
            logger.error("MANAGER: Unregistered manager addressed `#{user} => #{manager_routing_key}`")
            next
          end

          if !perm_mgr.perms[:root].test_permission(user, command) then
            logger.warn("PERMS: #{command} by #{user}@#{workerpool}: FAIL")
            next
          end

          uuid = SecureRandom.uuid
          promises[uuid] = Proc.new { |status_code, retval|
            ws.send(retval)
          }

          case command
          when 'mkpool'
            begin
              if perm_mgr.perms.fetch(pool_fqdn) then
                logger.error("POOL: Pool already exists: #{command} ignored `#{pool_fqdn}`")
                next
              end
            rescue KeyError
              perm_obj = Permissions.new(user)
              perm_obj.hostname = hostname
              perm_obj.workerpool = workerpool
              perm_obj.grant(user, :all)
              perm_mgr.perms[pool_fqdn] = perm_obj
              logger.info("PERMS: CREATED PERMSCREEN `#{workerpool} => #{manager_routing_key}`")
            end

            exchange.publish({ MKPOOL: {workerpool: workerpool} }.to_json,
                             :routing_key => manager_routing_key,
                             :type => "directive",
                             :message_id => uuid,
                             :timestamp => Time.now.to_i)
            logger.info("MANAGER: MKPOOL `#{workerpool} => #{manager_routing_key}`")
          when 'rmpool'
            begin
              perm_mgr.perms.fetch(pool_fqdn)
            rescue KeyError
              logger.warn("PERMS: NO EXISTING PERMSCREEN `#{workerpool} => #{manager_routing_key}` - NOOP")
              next
            end

            perm_mgr.perms.delete(pool_fqdn)
            logger.info("POOL: DELETED PERMSCREEN`#{workerpool} => #{manager_routing_key}`")

            exchange.publish({ REMOVE: {workerpool: workerpool} }.to_json,
                             :routing_key => manager_routing_key,
                             :type => "directive",
                             :message_id => uuid,
                             :timestamp => Time.now.to_i)
            logger.info("POOL: DELETED `#{workerpool} => #{manager_routing_key}`")
          when 'spawnpool'
            begin
              perm_mgr.perms.fetch(pool_fqdn)
            rescue KeyError
              logger.error("POOL: Cannot spawn worker in non-existent pool `#{pool_fqdn}`")
              next
            end

            exchange.publish({ SPAWN: {workerpool: workerpool} }.to_json,
                             :routing_key => manager_routing_key,
                             :type => "directive",
                             :message_id => uuid,
                             :timestamp => Time.now.to_i)
            logger.info("MANAGER: SPAWNED POOL `#{workerpool} => #{manager_routing_key}`")
          when 'despawnpool'
            #not yet implemented
          end
        end

        body_parameters = JSON.parse msg
        if body_parameters.key?('permission') then
          # permissions route
          if body_parameters.key?('server_name') then
            permission = body_parameters.delete('permission')
            affected_user = body_parameters.delete('affected_user')
            hostname = body_parameters.delete('hostname')
            workerpool = body_parameters.delete('workerpool')
            servername = body_parameters.delete('server_name')
            fqdn = "#{hostname}.#{workerpool}.#{servername}"

            perm_mgr.server_perms(permission, affected_user, fqdn)
          elsif body_parameters.key?('workerpool') then
            permission = body_parameters.delete('permission')
            affected_user = body_parameters.delete('affected_user')
            hostname = body_parameters.delete('hostname')
            workerpool = body_parameters.delete('workerpool')
            fqdn = "#{hostname}.#{workerpool}"

            perm_mgr.pool_perms(permission, affected_user, fqdn)
          else # root
            permission = body_parameters.delete('permission')
            affected_user = body_parameters.delete('affected_user')

            perm_mgr.root_perms(permission, affected_user)
          end
        else
          if body_parameters.key?('alt_cmd') then
            server_command.call(body_parameters)
          elsif body_parameters.key?('root_cmd') then
            root_command.call(body_parameters)
          elsif body_parameters.key?('pool_cmd') then
            pool_command.call(body_parameters)
          elsif body_parameters.key?('server_cmd') then
            server_command.call(body_parameters)
          end
        end
      end # ws.onmessage

      # WEBSOCKET CLOSE
      ws.onclose do
        logger.warn("websocket closed")
        settings.sockets.each do |sock|
          settings.sockets.delete(sock) if sock.websocket == ws
        end #each
      end #ws.onclose
    end # request.websocket
  end # get

  post '/sign_in' do
    require './auth'
    #currently assumes :plain TODO: accept separate methods in webui
    auth_inst = Auth.new
    login_token = auth_inst.login_plain(params[:username], params[:password])
    if login_token
      logger.info("#{params[:username]} validated")
      @@users << login_token
      session.clear
      session[:user_id] = login_token[:uuid]
    else
      logger.warn("#{params[:username]} rejected")
    end
    redirect '/'
  end

## helpers

  helpers do
    def current_user
      if session[:user_id]
        @@users.find { |u| u[:uuid] == session[:user_id] }
      else
        nil
      end
    end
  end

# startup broadcasts for IDENT
  exchange.publish('IDENT',
                   :routing_key => "workers",
                   :type => "directive",
                   :message_id => SecureRandom.uuid,
                   :timestamp => Time.now.to_i)
  logger.debug("IDENT: Requesting all workers report in")
  exchange.publish('IDENT',
                   :routing_key => "managers",
                   :type => "directive",
                   :message_id => SecureRandom.uuid,
                   :timestamp => Time.now.to_i)
  logger.debug("IDENT: Requesting all managers report in")

  run!
end

