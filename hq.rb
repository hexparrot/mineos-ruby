require 'sinatra/async'
require 'sinatra-websocket'
require 'json'
require 'securerandom'
require_relative 'perms'

SOCKET = Struct.new("Socket", :websocket, :user)
STDOUT.sync = true

# Defines the HQ class, responsible for all the thinking in this operation.
# It provides the authoritative source on all mineos operations, between
# user logins and authentication, a listening webui on 4567, and a websocket
# endpoint for remote control of all manager and worker nodes.
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

  require 'yaml'
  amqp_creds = YAML::load_file('/usr/local/etc/amqp.yml')['amqp']
  logger.info("AMQP: Using credentials from location `/usr/local/etc/amqp.yml`")
  s3_config = YAML::load_file('/usr/local/etc/objstore.yml')
  logger.info("S3: Using credentials from location `/usr/local/etc/objstore.yml`")

  # create perm directory on disk
  # this specific local path contains all the state for user logins' permissions
  # between handling pools, servers, and commands to a server.
  # The permissions manager is set to save after each operation
  require 'fileutils'
  perm_directory = File.join(File.expand_path(__dir__), 'config', 'perms')
  FileUtils.mkdir_p perm_directory

  # load perms
  require_relative 'permmgr'
  require_relative 'perms'
  temp_perm_hash = {}
  Dir["#{perm_directory}/*"].each do |fp|
    fn = File.basename(fp)
    no_ext = fn.rpartition('.').first
    no_ext = :root if no_ext == 'root' # change to sym!

    p_obj = Permissions.new(nil)
    p_obj.load_file(fp)
    temp_perm_hash[no_ext] = p_obj
  end

  if temp_perm_hash.key?(:root) then
    @@perm_mgr = PermManager.new(temp_perm_hash[:root].owner)
    @@perm_mgr.perms[:root] = temp_perm_hash.delete(:root)
    logger.info("PERMS: Loaded :root permissions")
  else
    @@perm_mgr = PermManager.new('plain:mc')
  end

  temp_perm_hash.each do |key, perm_obj|
    @@perm_mgr.perms[key] = perm_obj
    logger.info("PERMS: Loaded #{key}")
    logger.debug(perm_obj)
  end

  ## AMQP services provided by rabbitmq. The channels must be
  # secured by auth/enc
  require 'bunny'
  conn = Bunny.new(amqp_creds)
  conn.start
  logger.debug("AMQP: Connection to AMQP service successful")
  
  ch = conn.create_channel

  # exchange for directives (hostname specific)
  # directives includes tasks like IDENT (workers, id yourself)
  exchange = ch.topic("backend")
  logger.debug("AMQP: Attached to exchange: `backend`")

  # exchange for stdout
  # Any messages from each of the workers' STDOUT/STDERR can be
  # sent over amqp to any listening channels.  By default, this
  # will be the webui the user is connected to.  However,
  # there need not be any consumers of these feeds, and there
  # likewise is support for any amount of listening (webuis are
  # not limited in count, and can all cooperate in tandem).
  exchange_stdout = ch.direct('stdout')
  logger.debug("AMQP: Attached to exchange: `stdout`")

  # AMQP handling
  ch
  .queue('')
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
  .queue('hq')
  .bind(exchange, :routing_key => "hq")
  .subscribe do |delivery_info, metadata, payload|

    # when sent a command, routed to HQ, respond with meaningful, actionable http codes
    inbound_command = Proc.new do |delivery_info, metadata, payload|
      if metadata[:headers]['exception'] then
        promises[metadata.correlation_id].call 400, payload
      elsif parsed['cmd'] == 'create' then
        promises[metadata.correlation_id].call 201, payload
      else
        promises[metadata.correlation_id].call 200, payload
      end
    end

    # Directives are configuration-centered payloads made to ensure all satellites
    # are operating with the necessary, identical infrastructure.
    # Baked into this is a lot of meticulous--and now seemingly frivilous to the point
    # of confusing--added metadata in all publishes. message_id and correlation_ids do
    # actually correspond as expected, though the practical value added is marginal..
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

        # If the worker does not report knowing the minio/awscreds, publish it and route it directly.
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
          # This worker now has access to the s3 store, and all the profiles within.
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

        perm_mgr = PermManager.new user
        perm_mgr.set_logger(logger)

        ### DIRECTIVE PROCESSING

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

            perm_mgr.cast_server_perm!(permission, affected_user, fqdn)
          elsif body_parameters.key?('workerpool') then
            permission = body_parameters.delete('permission')
            affected_user = body_parameters.delete('affected_user')
            hostname = body_parameters.delete('hostname')
            workerpool = body_parameters.delete('workerpool')
            fqdn = "#{hostname}.#{workerpool}"

            perm_mgr.cast_pool_perm!(permission, affected_user, fqdn)
          else # root
            permission = body_parameters.delete('permission')
            affected_user = body_parameters.delete('affected_user')

            perm_mgr.cast_root_perm!(permission, affected_user)
          end
          # end permissions route
        else
          if body_parameters.key?('alt_cmd') then
            perm_mgr.server_exec_cmd!(body_parameters) { |params, rk|
              if !@@satellites[:workers].include?(rk) then
                logger.error("WORKER: Unregistered worker addressed `#{user} => #{rk}`")
                nil
              else
                exchange.publish(params.to_json,
                                 :routing_key => rk,
                                 :type => "command",
                                 :message_id => SecureRandom.uuid,
                                 :timestamp => Time.now.to_i)
                true
              end
            }
          elsif body_parameters.key?('root_cmd') then
            perm_mgr.root_exec_cmd!(body_parameters) { |params, rk|
              if !@@satellites[:managers].include?(rk) then
                logger.error("MANAGER: Unregistered manager addressed `#{user} => #{rk}`")
                nil
              else
                exchange.publish(params.to_json,
                                 :routing_key => rk,
                                 :type => "directive",
                                 :message_id => SecureRandom.uuid,
                                 :timestamp => Time.now.to_i)
                true
              end
            }
          elsif body_parameters.key?('pool_cmd') then
            perm_mgr.pool_exec_cmd!(body_parameters) { |params, rk|
              if !@@satellites[:workers].include?(rk) then
                logger.error("WORKER: Unregistered worker addressed `#{user} => #{rk}`")
                nil
              else
                exchange.publish(params.to_json,
                                 :routing_key => rk,
                                 :type => "command",
                                 :message_id => SecureRandom.uuid,
                                 :timestamp => Time.now.to_i)
                true
              end
            }
          elsif body_parameters.key?('server_cmd') then
            perm_mgr.server_exec_cmd!(body_parameters) { |params, rk|
              if !@@satellites[:workers].include?(rk) then
                logger.error("WORKER: Unregistered worker addressed `#{user} => #{rk}`")
                nil
              else
                exchange.publish(params.to_json,
                                 :routing_key => rk,
                                 :type => "command",
                                 :message_id => SecureRandom.uuid,
                                 :timestamp => Time.now.to_i)
                true
              end
            }
          end
        end

        # save permissions to disk @ ./config/perms/
        perm_mgr.perms.each do |key, perm_obj|
          perm_obj.save_file!(File.join(perm_directory, "#{key.to_s}.yml"))
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
      # presence of user in @@users signifies valid login
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

