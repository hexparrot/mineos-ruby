require 'sinatra/async'
require 'sinatra-websocket'
require 'json'
require 'securerandom'
require_relative 'perms'

SOCKET = Struct.new("Socket", :websocket, :user)

# helper functions
def test_access_worker(user, action, hostname, worker, server, dataset)
  match = dataset.detect { |s| s.hostname == hostname &&
                             s.workerpool == worker &&
                             s.servername == server }
  if match.nil? then
    nil #no match is found, action is irrelevant, return nil
  else
    match.test_permission(user, action) #match found, return true/false
  end
end

def test_access_manager(user, action, hostname, dataset)
  match = dataset.detect { |s| s.hostname == hostname }
  if match.nil? then
    nil #no match is found, action is irrelevant, return nil
  else
    match.test_permission(user, action) #match found, return true/false
  end
end

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
  @@servers = []
  @@managers = []
  promises = {}

  require 'openssl'
  rsa_key = OpenSSL::PKey::RSA.generate(2048)

  require 'logger'
  logger = Logger.new(STDOUT)
  logger.datetime_format = '%Y-%m-%d %H:%M:%S'
  logger.level = Logger::DEBUG

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

      if test_access_worker(user,
                            :console,
                            metadata[:headers]['hostname'],
                            metadata[:headers]['workerpool'],
                            parsed["server_name"],
                            @@servers) then
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

        inbound_directive = Proc.new do |params|
          hostname = params.delete('hostname')
          workerpool = params.delete('workerpool')
          routing_key = "managers.#{hostname}"
          directive = params.delete('dir')

          if !@@satellites[:managers].include?(routing_key) then
            logger.error("MANAGER: Invalid manager addressed `#{user} => #{routing_key}`")
            next
          end

          logger.debug("MANAGER: Forwarding directive from `#{user}`")

          if test_access_manager(user, :all, hostname, @@managers).nil? then
            #testing if manager has a corresponding entry, which will return non-nil (t/f)
            logger.warn("PERMS: None set for #{hostname} => #{routing_key}")
            logger.warn("PERMS: Creating a default perm manifest for #{user}")

            perm_obj = Permissions.new(user)
            perm_obj.hostname = hostname
            perm_obj.grant(user, :all)
            @@managers.push(perm_obj)
          end

          if test_access_manager(user, directive, hostname, @@managers) then
            logger.info("PERMS: #{user} for #{directive}: OK")

            uuid = SecureRandom.uuid
            promises[uuid] = Proc.new { |status_code, retval|
              ws.send(retval)
            }

            case directive
            when 'mkpool'
              exchange.publish({ MKPOOL: {workerpool: workerpool} }.to_json,
                               :routing_key => routing_key,
                               :type => "directive",
                               :message_id => uuid,
                               :timestamp => Time.now.to_i)
              logger.info("MANAGER: MKPOOL `#{workerpool} => #{routing_key}`")
            when 'spawn'
              exchange.publish({ SPAWN: {workerpool: workerpool} }.to_json,
                               :routing_key => routing_key,
                               :type => "directive",
                               :message_id => uuid,
                               :timestamp => Time.now.to_i)
              logger.info("MANAGER: SPAWN `#{workerpool} => #{routing_key}`")
            when 'remove'
              exchange.publish({ REMOVE: {workerpool: workerpool} }.to_json,
                               :routing_key => routing_key,
                               :type => "directive",
                               :message_id => uuid,
                               :timestamp => Time.now.to_i)
              logger.info("MANAGER: REMOVE `#{workerpool} => #{routing_key}`")
            end #case
          else
            logger.warn("PERMS: #{user} for #{directive}: FAIL")
            next
          end #test_access_manager
        end

        inbound_permission_manager = Proc.new do |params|
          hostname = params.delete('hostname')
          routing_key = "managers.#{hostname}"

          logger.info("PERMS: Forwarding permission-change from `#{user}`")

          if !@@satellites[:managers].include?(routing_key) then
            logger.error("PERMS: Invalid manager addressed `#{user} => #{routing_key}`")
            next
          end

          if test_access_manager(user, :all, hostname, @@managers).nil? then
            # testing if manager has a corresponding entry, which will return non-nil (t/f)
            # this will eventually be removed when the stateful information is saved
            # via yaml+disk or database.
            logger.warn("PERMS: None set for #{hostname} => #{routing_key}")
            logger.warn("PERMS: Creating a default perm manifest for #{user}")

            perm_obj = Permissions.new(user)
            perm_obj.hostname = hostname
            perm_obj.grant(user, :all)
            perm_obj.make_grantor(user)
            @@managers.push(perm_obj)
          end

          target_user = params.delete('user')
          target_perm = params.delete('perm')

          match = @@managers.find { |s| s.hostname == hostname }
          if match && match.grantor?(user) then
            logger.info("PERMS: #{user} able to cast #{target_perm}: TRUE")

            case target_perm
            when 'mkgrantor'
              match.make_grantor(target_user)
              logger.info("PERMS: Elevating #{target_user} to grantor for #{hostname}")
            when 'rmgrantor'
              match.unmake_grantor(target_user)
              logger.info("PERMS: Revoking #{target_user} grantor privileges on #{hostname}")
            else
              logger.error("PERMS: Requested #{target_perm} not applicable to managers.")
            end #case
          else
            logger.warn("PERMS: #{user} able to cast #{target_perm}: FALSE")
            next
          end
        end #inbound_permission

        inbound_permission_worker = Proc.new do |params|
          hostname = params.delete('hostname')
          workerpool = params.delete('workerpool')
          servername = params['server_name']
          routing_key = "workers.#{hostname}.#{workerpool}"
          command = params['cmd']

          if !@@satellites[:workers].include?(routing_key) then
            logger.error("WORKER: Invalid worker addressed `#{user} => #{routing_key}`")
            next
          end

          if test_access_worker(user, :all, hostname, workerpool, servername, @@servers).nil? then
            #okay to test for all, because .nil? implies server not found, see func at top
            logger.warn("PERMS: None set for `#{servername} => #{routing_key}`")
            case command
            when 'create'
              logger.info("PERMS: :create requested, making default permissions `#{servername} => #{routing_key}`")
              perm_obj = Permissions.new(user)
              perm_obj.hostname = hostname
              perm_obj.workerpool = workerpool
              perm_obj.servername = servername
              perm_obj.grant(user, :all)
              @@servers << perm_obj
            end
          end

          target_user = params.delete('user')
          target_perm = params.delete('perm')

          match = @@servers.find { |s| s.hostname == hostname &&
                                       s.workerpool == workerpool &&
                                       s.servername == servername }
          if match && match.grantor?(user) then
            logger.info("PERMS: #{user} able to cast #{target_perm}: TRUE")

            case target_perm
            when 'grantall'
              match.grant(target_user, :all)
              logger.info("PERMS: Providing #{target_user} with :all on #{servername} => #{routing_key}")
            when 'revokeall'
              match.revoke(target_user, :all)
              logger.info("PERMS: Revoking :all from #{target_user} for #{servername} => #{routing_key}")
            else
              logger.error("PERMS: Requested #{target_perm} not applicable to workers.")
            end #case
          else
            logger.warn("PERMS: #{user} able to cast #{target_perm}: FALSE")
            next
          end
        end

        inbound_command = Proc.new do |params|
          hostname = params.delete('hostname')
          workerpool = params.delete('workerpool')
          servername = params['server_name']
          routing_key = "workers.#{hostname}.#{workerpool}"
          command = params['cmd']

          if !@@satellites[:workers].include?(routing_key) then
            logger.error("WORKER: Invalid worker addressed `#{user} => #{routing_key}`")
            next
          end

          if test_access_worker(user, :all, hostname, workerpool, servername, @@servers).nil? then
            #okay to test for all, because .nil? implies server not found, see func at top
            logger.warn("PERMS: None set for `#{servername} => #{routing_key}`")
            case command
            when 'create'
              logger.info("PERMS: :create requested, making default permissions `#{servername} => #{routing_key}`")
              perm_obj = Permissions.new(user)
              perm_obj.hostname = hostname
              perm_obj.workerpool = workerpool
              perm_obj.servername = servername
              perm_obj.grant(user, :all)
              @@servers << perm_obj
            end
          end

          begin
            if test_access_worker(user, command, hostname, workerpool, servername, @@servers) then
              logger.info("PERMS: #{user} for #{command}: OK")

              uuid = SecureRandom.uuid
              promises[uuid] = Proc.new { |status_code, retval|
                ws.send(retval)
              }

              exchange.publish(params.to_json,
                               :routing_key => routing_key,
                               :type => "command",
                               :message_id => uuid,
                               :timestamp => Time.now.to_i)
              logger.info("PERMS: Forwarded command `#{routing_key}`")
              logger.debug(params)
            else
              logger.warn("PERMS: #{user} for #{params['cmd']}: FAIL")
            end #test_permission
          rescue NoMethodError
            # no match, NOOP
            logger.error("PERMS: no matching permission screen: NOOP")
          end #begin
        end

        body_parameters = JSON.parse msg
        if body_parameters.key?('dir') then
          inbound_directive.call(body_parameters)
        elsif body_parameters.key?('perm') then
          if body_parameters.key?('server_name') then
            inbound_permission_worker.call(body_parameters)
          else #manager permissions if 'server' absent
            inbound_permission_manager.call(body_parameters)
          end
        elsif body_parameters.key?('cmd') then
          inbound_command.call(body_parameters)
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

