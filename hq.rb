require 'sinatra/async'
require 'sinatra-websocket'
require 'json'
require 'securerandom'
require_relative 'perms'

require 'set'
SATELLITES = { :workers => Set.new, :managers => Set.new }
SOCKET = Struct.new("Socket", :websocket, :user)
USERS = []
SERVERS = []

def test_access(user, action, host, worker, server)
  match = SERVERS.find { |s| s.host == host &&
                             s.pool == worker &&
                             s.server == server }
  if match.nil? then
    nil #no match is found, action is irrelevant, return nil
  else
    match.permissions.test_permission(user, action) #match found, return true/false
  end
end

class HQ < Sinatra::Base
  set :server, :thin
  set :sockets, []
  set :bind, '0.0.0.0'
  register Sinatra::Async
  enable :show_exceptions
  enable :sessions

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

  ch
  .queue('', exclusive: true)
  .bind(exchange_stdout, :routing_key => "hq")
  .subscribe do |delivery_info, metadata, payload|
    settings.sockets.each { |ws|
      parsed = JSON.parse payload
      user = "#{ws.user.authtype}:#{ws.user.id}"

      ws.websocket.send(payload) if test_access(user,
                                                :console,
                                                metadata[:headers]['hostname'],
                                                metadata[:headers]['workerpool'],
                                                parsed["server_name"])
    }
  end

  promises = {}

  ch
  .queue('hq', exclusive: true)
  .bind(exchange, :routing_key => "hq")
  .subscribe do |delivery_info, metadata, payload|
    if metadata[:headers]['command'] then
      # for inbound commands
      if metadata[:headers]['exception'] then
        promises[metadata.correlation_id].call 400, payload
      elsif parsed['cmd'] == 'create' then
        promises[metadata.correlation_id].call 201, payload
      else
        promises[metadata.correlation_id].call 200, payload
      end
    elsif metadata[:headers]['directive'] then
      # for inbound directives
      case metadata[:headers]['directive']
      when 'IDENT'
        parsed = JSON.parse payload

        if parsed["workerpool"] then
          # :workerpool's only exists only from worker satellite
          routing_key = "workers.#{parsed['hostname']}.#{parsed['workerpool']}"

          if !SATELLITES[:workers].include?(routing_key) then
            logger.info("IDENT: Worker registered `#{routing_key}`")
            SATELLITES[:workers].add(routing_key)
            # new worker process registration, ask to verify OBJSTORE
            exchange.publish('ACK',
                             :routing_key => routing_key,
                             :type => "receipt.directive",
                             :message_id => SecureRandom.uuid,
                             :correlation_id => metadata[:message_id],
                             :headers => { directive: 'IDENT' },
                             :timestamp => Time.now.to_i)
          else
            # worker already registered
            logger.info("IDENT: Worker heartbeat `#{routing_key}`")
          end

          exchange.publish('VERIFY_OBJSTORE',
                           :routing_key => routing_key,
                           :type => "directive",
                           :message_id => SecureRandom.uuid,
                           :timestamp => Time.now.to_i)
          logger.info("VERIFY_OBJSTORE: Request sent to `#{routing_key}`")
        else
          # :workerpool's absence implies mrmanager satellite
          routing_key = "managers.#{parsed['hostname']}"

          if !SATELLITES[:managers].include?(routing_key) then
            logger.info("IDENT: Manager registered `#{routing_key}`")
            SATELLITES[:managers].add(routing_key)
          else
            # mrmanager already registered
            logger.info("IDENT: Manager heartbeat `#{routing_key}`")
          end
        end #if parsed["workerpool"]
      when 'VERIFY_OBJSTORE'
        routing_key = "workers.#{metadata[:headers]['hostname']}.#{metadata[:headers]['workerpool']}"
        if payload == '' then
          logger.info("VERIFY_OBJSTORE: returned, creds absent. AWSCREDS to `#{routing_key}`")
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
          logger.info("VERIFY_OBJSTORE: returned, creds present. NOOP `#{routing_key}`")
        end
      end #case
    end #metadata if
  end #subscribe

## route handlers

  Perms = Struct.new("Perms", :host, :pool, :server, :permissions)

  get '/' do
    if !current_user
      send_file File.join('public', 'login.html')
    else # auth successful
      if !request.websocket?
        send_file File.join('public', 'index.html')
      else
        request.websocket do |ws|
          ws.onopen do
            settings.sockets << Struct::Socket.new(ws, current_user)
          end #end ws.onopen

          ws.onmessage do |msg|
            uuid = SecureRandom.uuid
            user = "#{current_user.authtype}:#{current_user.id}"

            body_parameters = JSON.parse msg
            if body_parameters.key?('dir') then
              hostname = body_parameters.delete('hostname')
              workerpool = body_parameters.delete('workerpool')
              routing_key = "managers.#{hostname}"

              promises[uuid] = Proc.new { |status_code, retval|
                ws.send(retval)
              }

              if !SATELLITES[:managers].include?(routing_key)
                logger.error("MANAGER: Invalid manager addressed `#{user} => #{routing_key}`")
              else
                logger.info("MANAGER: Forwarding directive from `#{user}`")
                case body_parameters['dir']
                when 'shutdown'
                  exchange.publish({ SHUTDOWN: {manager: routing_key} }.to_json,
                                   :routing_key => routing_key,
                                   :type => "directive",
                                   :message_id => uuid,
                                   :timestamp => Time.now.to_i)
                  logger.info("MANAGER: MKPOOL `#{workerpool} => #{routing_key}`")
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
                end
              end
            elsif body_parameters.key?('cmd') then
              hostname = body_parameters.delete('hostname')
              workerpool = body_parameters.delete('workerpool')
              servername = body_parameters['server_name']

              routing_key = "workers.#{hostname}.#{workerpool}"

              if !SATELLITES[:workers].include?(routing_key) then
                logger.error("WORKER: Invalid worker addressed `#{user} => #{routing_key}`")
              else
                if test_access(user, :all, hostname, workerpool, servername).nil? then
                  #okay to test for all, because .nil? implies server not found, see func at top
                  logger.warn("PERMS: None set for `#{servername} => #{routing_key}`")
                  case body_parameters['cmd']
                  when 'create'
                    logger.info("PERMS: :create requested, making default permissions `#{servername} => #{routing_key}`")
                    match = Struct::Perms.new(hostname,
                                              workerpool,
                                              servername,
                                              Permissions.new(owner: user))
                    match.permissions.grant(user, :all)
                    SERVERS << match
                  end #case
                end #match.nil?

                begin
                  if test_access(user,
                                 body_parameters['cmd'],
                                 hostname,
                                 workerpool,
                                 servername) then
                    # and permissions granted to user for cmd

                    logger.info("PERMS: #{user} for #{body_parameters['cmd']}: OK")

                    promises[uuid] = Proc.new { |status_code, retval|
                      ws.send(retval)
                    }

                    exchange.publish(body_parameters.to_json,
                                     :routing_key => routing_key,
                                     :type => "command",
                                     :message_id => uuid,
                                     :timestamp => Time.now.to_i)
                    logger.info("PERMS: Forwarded command `#{routing_key}`")
                    logger.debug(body_parameters)
                  else
                    logger.warn("PERMS: #{user} for #{body_parameters['cmd']}: FAIL")
                  end #test_permission
                rescue NoMethodError
                  # no match, NOOP
                  logger.error("PERMS: no matching permission screen: NOOP")
                end #begin
              end #!SATELLITES

            end #body_parameters
          end # ws.onmessage

          ws.onclose do
            warn("websocket closed")
            settings.sockets.each do |sock|
              settings.sockets.delete(sock) if sock.websocket == ws
            end #each
          end #ws.onclose
        end # request.websocket
      end # if/else
    end # current user
  end # get

  post '/sign_in' do
    require './auth'
    #currently assumes :plain TODO: accept separate methods in webui
    auth_inst = Auth.new
    login_token = auth_inst.login_plain(params[:username], params[:password])
    if login_token
      USERS << login_token
      session.clear
      session[:user_id] = login_token[:uuid]
    end
    redirect '/'
  end

## helpers

  helpers do
    def current_user
      if session[:user_id]
        USERS.find { |u| u[:uuid] == session[:user_id] }
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

