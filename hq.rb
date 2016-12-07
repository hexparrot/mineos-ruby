require 'sinatra/async'
require 'eventmachine'
require 'json'
require 'securerandom'

#setup

 
class HQ < Sinatra::Base
  set :server, :thin
  register Sinatra::Async
  enable :show_exceptions

  require 'bunny'
  require 'set'
  conn = Bunny.new
  conn.start
  
  ch = conn.create_channel
  exchange = ch.topic('backend')
  
  available_workers = Set.new
  ch
  .queue("directives")
  .bind(exchange, :routing_key => "to_hq")
  .subscribe do |delivery_info, metadata, payload|
    if metadata.type == 'IDENT' then
      available_workers.add(payload)
    end
  end
  
  exchange.publish('IDENT',
                    :routing_key => "to_workers",
                    :type => "directive",
                    :message_id => SecureRandom.uuid,
                    :timestamp => Time.now.to_i)

  get '/workerlist' do
    {:hosts => available_workers.to_a}.to_json
  end

  apost '/create/:worker/:servername' do |worker, servername|
    if worker == 'any'
      candidate = available_workers.to_a.sample
    elsif !available_workers.include?(worker)
      halt 404, {server_name: servername, success: false}.to_json
    else
      candidate = worker 
    end
    uuid = SecureRandom.uuid

    ch
    .queue("")
    .bind(exchange, :routing_key => "to_hq")
    .subscribe do |delivery_info, metadata, payload|
      if metadata.correlation_id == uuid then
        status 201
        body payload
      end
    end

    exchange.publish({cmd: 'create',
                      server_name: servername,
                      server_type: ':conventional_jar'}.to_json,
                     :routing_key => "to_workers.#{candidate}",
                     :type => "command",
                     :message_id => uuid,
                     :timestamp => Time.now.to_i)
  end

  run!
end

