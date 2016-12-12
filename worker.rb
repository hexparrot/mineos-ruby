require 'json'
require 'bunny'
require 'eventmachine'
require 'securerandom'
require './mineos'
 
EM.run do
  servers = {}
  hostname = Socket.gethostname
  amqp = 'amqp://localhost'

  server_dirs = Enumerator.new do |enum|
    Dir['/var/games/minecraft/servers/*'].each { |d| 
      server_name = d[0..-1].match(/.*\/(.*)/)[1]
      enum.yield server_name
    }
  end

  server_dirs.each do |sn|
    #register existing servers upon startup
    servers[sn] = Server.new(sn)
  end

  conn = Bunny.new(amqp)
  conn.start

  ch = conn.create_channel
  exchange = ch.topic("backend")

  directive_handler = lambda { |delivery_info, metadata, payload|
    case payload
    when "IDENT"
      exchange.publish({host: hostname}.to_json,
                       :routing_key => "to_hq",
                       :timestamp => Time.now.to_i,
                       :type => 'receipt.directive',
                       :correlation_id => metadata[:message_id],
                       :headers => {hostname: hostname,
                                    directive: 'IDENT'},
                       :message_id => SecureRandom.uuid)
    when "LIST"
      exchange.publish({servers: server_dirs.to_a}.to_json,
                       :routing_key => "to_hq",
                       :timestamp => Time.now.to_i,
                       :type => 'receipt.directive',
                       :correlation_id => metadata[:message_id],
                       :headers => {hostname: hostname,
                                    directive: 'LIST'},
                       :message_id => SecureRandom.uuid)
    when "USAGE"
      require 'usagewatch'

      EM.defer do
        usw = Usagewatch
        retval = {
          uw_cpuused: usw.uw_cpuused,
          uw_memused: usw.uw_memused,
          uw_load: usw.uw_load,
          uw_diskused: usw.uw_diskused,
          uw_diskused_perc: usw.uw_diskused_perc,
        }
        exchange.publish({usage: retval}.to_json,
                         :routing_key => "to_hq",
                         :timestamp => Time.now.to_i,
                         :type => 'receipt.directive',
                         :correlation_id => metadata[:message_id],
                         :headers => {hostname: hostname,
                                      directive: 'USAGE'},
                         :message_id => SecureRandom.uuid)
      end
    when /(uw_\w+)/
      require 'usagewatch'

      EM.defer do
        usw = Usagewatch
        exchange.publish({usage: {$1 =>  usw.public_send($1)}}.to_json,
                         :routing_key => "to_hq",
                         :timestamp => Time.now.to_i,
                         :type => 'receipt.directive',
                         :correlation_id => metadata[:message_id],
                         :headers => {hostname: hostname,
                                      directive: 'REQUEST_USAGE'},
                         :message_id => SecureRandom.uuid)
      end
    end
  }

  command_handler = lambda { |delivery_info, metadata, payload|
    parsed = JSON.parse(payload, :symbolize_names => true)
    server_name = parsed.delete(:server_name)
    cmd = parsed.delete(:cmd)
    inst = Server.new(server_name)

    return_object = {server_name: server_name, cmd: cmd, success: false, retval: nil}

    if inst.respond_to?(cmd) then
      reordered = []
      inst.method(cmd).parameters.map do |req_or_opt, name|
        begin
          if parsed[name][0] == ':' then
            #if string begins with :, interpret as symbol (remove : and convert)
            reordered << parsed[name][1..-1].to_sym
          else
            reordered << parsed[name]
          end
        rescue NoMethodError
          if req_or_opt == 'req' then
            exchange.publish(return_object.to_json,
                             :routing_key => "to_hq",
                             :timestamp => Time.now.to_i,
                             :type => 'receipt.command',
                             :correlation_id => metadata[:message_id],
                             :headers => {hostname: hostname},
                             :message_id => SecureRandom.uuid)
          else
            break #if optional and absent, break loop and advance
            # there are currently no functions with 2+ optional parameters
          end
        end
      end

      to_call = Proc.new do
        begin
          inst.public_send(cmd, *reordered)
        rescue IOError
          puts "IOERROR CAUGHT"
        end
      end

      cb = Proc.new { |retval|
        return_object[:retval] = retval
        return_object[:success] = true
        exchange.publish(return_object.to_json,
                         :routing_key => "to_hq",
                         :timestamp => Time.now.to_i,
                         :type => 'receipt.command',
                         :correlation_id => metadata[:message_id],
                         :headers => {hostname: hostname},
                         :message_id => SecureRandom.uuid)
      }
      EM.defer to_call, cb
    else #method not defined in api
      cb = Proc.new { |retval|
        exchange.publish(return_object.to_json,
                         :routing_key => "to_hq",
                         :timestamp => Time.now.to_i,
                         :type => 'receipt.command',
                         :correlation_id => metadata[:message_id],
                         :headers => {hostname: hostname},
                         :message_id => SecureRandom.uuid)
      }
      EM.defer cb
    end

  }

  ch
  .queue('worker.dispatcher')
  .bind(exchange, :routing_key => 'to_workers.#')
  .subscribe do |delivery_info, metadata, payload|
    #puts delivery_info
    #puts metadata
    #puts payload
    if delivery_info.routing_key.split('.')[1] == hostname ||
       delivery_info.routing_key == 'to_workers' then
      case metadata.type
      when 'directive'
        directive_handler.call delivery_info, metadata, payload
      when 'command'
        command_handler.call delivery_info, metadata, payload
      end
    end
  end
end #EM::Run
