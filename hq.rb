require 'sinatra/async'
require 'eventmachine'
require 'json'
require 'securerandom'

class HQ < Sinatra::Base
  set :server, :thin
  register Sinatra::Async
  enable :show_exceptions

  require 'set'
  available_workers = Set.new

  require 'bunny'
  conn = Bunny.new
  conn.start
  
  ch = conn.create_channel
  exchange = ch.topic('backend')

  promises = {}

  ch
  .queue('')
  .bind(exchange, :routing_key => "to_hq")
  .subscribe do |delivery_info, metadata, payload|
    parsed = JSON.parse(payload, :symbolize_names => true)
    case metadata.type
    when 'receipt.directive'
      case metadata[:headers]['directive']
      when 'IDENT'
        available_workers.add(parsed[:host])
      when 'LIST'
        yet_to_respond = promises[metadata.correlation_id][:retval][:hosts].length
        promises[metadata.correlation_id][:retval][:hosts].each do |obj|
          if obj[:hostname] == metadata[:headers]['hostname'] then
            obj[:servers] = parsed[:servers]
            obj[:timestamp] = metadata[:timestamp]
            yet_to_respond -= 1
          end
        end
  
        if yet_to_respond == 0 then
          #timeout needs to be added for if server does not respond
          #this mechanism expected to fail without 100% reply rate
          promises[metadata.correlation_id][:callback].call 200, promises[metadata.correlation_id][:retval].to_json
        end
      end
    when 'receipt.command'
      promises[metadata.correlation_id][:retval][:success] = parsed[:success]
      promises[metadata.correlation_id][:callback].call 201, promises[metadata.correlation_id][:retval].to_json
    end
  end
 
  exchange.publish('IDENT',
                   :routing_key => "to_workers",
                   :type => "directive",
                   :message_id => SecureRandom.uuid,
                   :timestamp => Time.now.to_i)

## route handlers

  get '/workerlist' do
    {:hosts => available_workers.to_a}.to_json
  end

  aget '/serverlist' do
    uuid = SecureRandom.uuid

    promises[uuid] = {
      callback: 
        Proc.new { |status_code, retval|
          status status_code
          body retval
        },
      retval: {hosts: [], timestamp: Time.now.to_i}
    }

    available_workers.each do |worker|
      promises[uuid][:retval][:hosts] << {
        hostname: worker,
        servers: [],
        timestamp: nil
      }
    end

    exchange.publish('LIST',
                     :routing_key => "to_workers",
                     :type => "directive",
                     :message_id => uuid,
                     :timestamp => Time.now.to_i)
  end

  apost '/:worker/:servername' do |worker, servername|
    body_parameters = JSON.parse request.body.read

    if worker == 'any'
      candidate = available_workers.to_a.sample
    elsif !available_workers.include?(worker)
      halt 404, {server_name: servername, success: false}.to_json
    else
      candidate = worker
    end

    case body_parameters['cmd']
    when 'create'
      uuid = SecureRandom.uuid

      promises[uuid] = {
        callback: 
          Proc.new { |status_code, retval|
            status status_code
            body retval
          },
        retval: {
          server_name: servername,
          cmd: body_parameters['cmd'],
          success: false
        }
      }

      exchange.publish({cmd: 'create',
                        server_name: servername}.to_json,
                       :routing_key => "to_workers.#{candidate}",
                       :type => "command",
                       :message_id => uuid,
                       :timestamp => Time.now.to_i)
    else
      status 400
      body
    end
  end

  run!
end

