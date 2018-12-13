require 'sinatra/async'
require 'sinatra-websocket'
require 'eventmachine'
require 'json'
require 'securerandom'

USERS = []

class HQ < Sinatra::Base
  set :server, :thin
  set :sockets, []
  set :bind, '0.0.0.0'
  register Sinatra::Async
  enable :show_exceptions
  enable :sessions

  require 'set'
  available_workers = Set.new
  available_managers = Set.new

  require 'yaml'
  mineos_config = YAML::load_file('config/secrets.yml')
  s3_config = YAML::load_file('config/objstore.yml')

  require 'bunny'
  conn = Bunny.new(:host => mineos_config['rabbitmq']['host'],
                   :port => mineos_config['rabbitmq']['port'],
                   :user => mineos_config['rabbitmq']['user'],
                   :pass => mineos_config['rabbitmq']['pass'],
                   :vhost => mineos_config['rabbitmq']['vhost'])
  conn.start
  
  ch = conn.create_channel

  # exchange for commands (workerpool+server specific)
  exchange_cmd = ch.direct('commands')

  # exchange for directives (hostname specific)
  exchange_dir = ch.topic("directives")

  # exchange for stdout
  exchange_stdout = ch.direct('stdout')

  ch
  .queue('', exclusive: true)
  .bind(exchange_stdout, :routing_key => "hq")
  .subscribe do |delivery_info, metadata, payload|
    settings.sockets.each { |ws| ws.send(payload) }
  end

  promises = {}
  promise_retvals = {}

  ch
  .queue('', exclusive: true)
  .bind(exchange_dir, :routing_key => "hq")
  .subscribe do |delivery_info, metadata, payload|
    parsed = JSON.parse payload
    case metadata.type
    when 'receipt.directive'
      case metadata[:headers]['directive']
      when 'IDENT'
        if parsed['workerpool'] then
          #this is coming from a worker
          available_workers.add(parsed['workerpool'])

          # on receipt of IDENT, send object store creds
          exchange_dir.publish({ AWSCREDS: {
                                   endpoint: s3_config['object_store']['host'],
                                   access_key_id: s3_config['object_store']['access_key'],
                                   secret_access_key: s3_config['object_store']['secret_key'],
                                   region: 'us-west-1'
                                 }
                               }.to_json,
                               :routing_key => "workers",
                               :type => "directive",
                               :message_id => SecureRandom.uuid,
                               :timestamp => Time.now.to_i)
        else
          puts "adding new manager: #{parsed['host']}"
          available_managers.add(parsed['host'])
        end
      when 'LIST'
        yet_to_respond = promise_retvals[metadata.correlation_id][:hosts].length
        promise_retvals[metadata.correlation_id][:hosts].each do |obj|
          if obj[:workerpool] == metadata[:headers]['workerpool'] then
            obj[:servers] = parsed['servers']
            obj[:timestamp] = metadata[:timestamp]
            yet_to_respond -= 1
          end
        end
  
        if yet_to_respond == 0 then
          #timeout needs to be added for if server does not respond
          #this mechanism expected to fail without 100% reply rate
          promises[metadata.correlation_id].call 200, promise_retvals[metadata.correlation_id].to_json
        end
      end
    when 'receipt.command'
      if metadata[:headers]['exception'] then
        promises[metadata.correlation_id].call 400, payload
      elsif parsed['cmd'] == 'create' then
        promises[metadata.correlation_id].call 201, payload
      else
        promises[metadata.correlation_id].call 200, payload
      end
    end
  end
 
## route handlers

  get '/' do
    if !current_user
      send_file File.join('public', 'login.html')
    else # auth successful
      if !request.websocket?
        send_file File.join('public', 'index.html')
      else
        request.websocket do |ws|
          ws.onopen do
            settings.sockets << ws
          end #end ws.onopen

          ws.onmessage do |msg|
            uuid = SecureRandom.uuid

            body_parameters = JSON.parse msg
            if body_parameters.key?('dir') then
              hostname = body_parameters.delete('hostname')
              workerpool = body_parameters.delete('workerpool')

              promises[uuid] = Proc.new { |status_code, retval|
                ws.send(retval)
              }

              if !available_managers.include?(hostname)
                puts "hostname `#{hostname}` not found."
              else
                puts "sending `#{hostname}:#{workerpool}` directive:"
                puts body_parameters
                case body_parameters['dir']
                when 'spawn'
                  exchange_dir.publish({SPAWN: {workerpool: workerpool}}.to_json,
                                        :routing_key => "managers.#{hostname}",
                                        :type => "directive",
                                        :message_id => uuid,
                                        :timestamp => Time.now.to_i)
                when 'remove'
                  exchange_dir.publish({REMOVE: {workerpool: workerpool}}.to_json,
                                        :routing_key => "managers.#{hostname}",
                                        :type => "directive",
                                        :message_id => uuid,
                                        :timestamp => Time.now.to_i)
                end
              end
            elsif body_parameters.key?('cmd') then
              hostname = body_parameters.delete('hostname')
              workerpool = body_parameters.delete('workerpool')
              servername = body_parameters['server_name']

              promises[uuid] = Proc.new { |status_code, retval|
                ws.send(retval)
              }

              if !available_workers.include?(workerpool)
                puts "worker `#{workerpool}` not found."
                #workerpool not found?  ignore.  todo: log me somewhere!
              else
                puts "sending hostname:workerpool `#{hostname}:#{workerpool}` command:"
                puts body_parameters
                exchange_cmd.publish(body_parameters.to_json,
                                     :routing_key => "workers.#{hostname}.#{workerpool}",
                                     :type => "command",
                                     :message_id => uuid,
                                     :timestamp => Time.now.to_i)
              end
            end
          end # ws.onmessage

          ws.onclose do
            warn("websocket closed")
            settings.sockets.delete(ws)
          end
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

  get '/workerlist' do
    {:hosts => available_workers.to_a}.to_json
  end

  aget '/serverlist' do
    uuid = SecureRandom.uuid

    promises[uuid] = Proc.new { |status_code, retval|
      status status_code
      body retval
    }

    promise_retvals[uuid] = {hosts: [], timestamp: Time.now.to_i}

    available_workers.each do |worker|
      promise_retvals[uuid][:hosts] << {
        hostname: worker,
        servers: [],
        timestamp: nil
      }
    end

    exchange_cmd.publish('LIST',
                         :routing_key => "workers",
                         :type => "directive",
                         :message_id => uuid,
                         :timestamp => Time.now.to_i)
  end

  apost '/:worker/:servername' do |worker, servername|
    body_parameters = JSON.parse request.body.read

    uuid = SecureRandom.uuid
    body_parameters['server_name'] = servername

    promises[uuid] = Proc.new { |status_code, retval|
      status status_code
      body retval
    }

    if !available_workers.include?(worker)
      halt 404, {server_name: servername, success: false}.to_json
    else
      exchange_cmd.publish(body_parameters.to_json,
                           :routing_key => "workers.#{worker}",
                           :type => "command",
                           :message_id => uuid,
                           :timestamp => Time.now.to_i)
    end
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

## startup broadcasts for IDENT
  exchange_dir.publish('IDENT',
                       :routing_key => "workers",
                       :type => "directive",
                       :message_id => SecureRandom.uuid,
                       :timestamp => Time.now.to_i)
  exchange_dir.publish('IDENT',
                       :routing_key => "managers",
                       :type => "directive",
                       :message_id => SecureRandom.uuid,
                       :timestamp => Time.now.to_i)


  run!
end

