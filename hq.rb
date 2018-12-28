require 'sinatra/async'
require 'sinatra-websocket'
require 'json'
require 'securerandom'
require 'set'

USERS = []
SATELLITES = { :workers => Set.new, :managers => Set.new }

class HQ < Sinatra::Base
  set :server, :thin
  set :sockets, []
  set :bind, '0.0.0.0'
  register Sinatra::Async
  enable :show_exceptions
  enable :sessions

  require 'yaml'
  amqp_creds = YAML::load_file('config/amqp.yml')['rabbitmq'].transform_keys(&:to_sym)
  s3_config = YAML::load_file('config/objstore.yml')

  require 'bunny'
  conn = Bunny.new(amqp_creds)
  conn.start
  
  ch = conn.create_channel

  # exchange for directives (hostname specific)
  exchange = ch.topic("backend")

  # exchange for stdout
  exchange_stdout = ch.direct('stdout')

  ch
  .queue('', exclusive: true)
  .bind(exchange_stdout, :routing_key => "hq")
  .subscribe do |delivery_info, metadata, payload|
    settings.sockets.each { |ws| ws.send(payload) }
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
          unique_name = "#{parsed['workerpool']}@#{parsed['hostname']}"
          if !SATELLITES[:workers].include?(unique_name) then
            puts "worker.rb process registered: #{unique_name}"
            SATELLITES[:workers].add(unique_name)
            # new worker process registration, ask to verify OBJSTORE
            host = metadata[:headers]['hostname']
            workerpool = metadata[:headers]['workerpool']
            exchange.publish('ACK',
                             :routing_key => "workers.#{host}.#{workerpool}",
                             :type => "receipt.directive",
                             :message_id => SecureRandom.uuid,
                             :correlation_id => metadata[:message_id],
                             :headers => { directive: 'IDENT' },
                             :timestamp => Time.now.to_i)
            exchange.publish('VERIFY_OBJSTORE',
                             :routing_key => "workers.#{host}.#{workerpool}",
                             :type => "directive",
                             :message_id => SecureRandom.uuid,
                             :timestamp => Time.now.to_i)
          else
            # worker already registered
            puts "worker.rb process heartbeat: #{unique_name}"
          end
        else
          # :workerpool's absence implies mrmanager satellite

        end #if parsed["workerpool"]
      when 'VERIFY_OBJSTORE'
        if payload == '' then
          # on receipt of non-true VERIFY_OBJSTORE, send object store creds
          host = metadata[:headers]['hostname']
          workerpool = metadata[:headers]['workerpool']
          exchange.publish({ AWSCREDS: {
                               endpoint: s3_config['object_store']['host'],
                               access_key_id: s3_config['object_store']['access_key'],
                               secret_access_key: s3_config['object_store']['secret_key'],
                               region: 'us-west-1'
                             }
                           }.to_json,
                           :routing_key => "workers.#{host}.#{workerpool}",
                           :type => "directive",
                           :headers => { directive: 'VERIFY_OBJSTORE' },
                           :correlation_id => metadata[:message_id],
                           :message_id => SecureRandom.uuid,
                           :timestamp => Time.now.to_i)
        end
      end #case
    end #metadata if
  end #subscribe

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

              if !SATELLITES[:managers].include?(hostname)
                puts "hostname `#{hostname}` not found."
              else
                puts "sending `#{hostname}:#{workerpool}` directive:"
                puts body_parameters
                case body_parameters['dir']
                when 'mkpool'
                  exchange.publish({MKPOOL: {workerpool: workerpool}}.to_json,
                                    :routing_key => "managers.#{hostname}",
                                    :type => "directive",
                                    :message_id => uuid,
                                    :timestamp => Time.now.to_i)
                when 'spawn'
                  exchange.publish({SPAWN: {workerpool: workerpool}}.to_json,
                                    :routing_key => "managers.#{hostname}",
                                    :type => "directive",
                                    :message_id => uuid,
                                    :timestamp => Time.now.to_i)
                when 'remove'
                  exchange.publish({REMOVE: {workerpool: workerpool}}.to_json,
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

              if !SATELLITES[:workers].include?("#{workerpool}@#{hostname}")
                puts "worker `#{workerpool}@#{hostname}` not found."
                #workerpool not found?  ignore.  todo: log me somewhere!
              else
                puts "sending `#{hostname}:#{workerpool}` command:"
                puts body_parameters
                exchange.publish(body_parameters.to_json,
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
#  exchange.publish('IDENT',
#                   :routing_key => "managers",
#                   :type => "directive",
#                   :message_id => SecureRandom.uuid,
#                   :timestamp => Time.now.to_i)

  run!
end

