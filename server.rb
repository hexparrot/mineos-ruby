require 'json'
require 'bunny'
require 'eventmachine'
require './mineos'
 
servers = {}

def jsonify(hash_obj)
  return JSON.generate(hash_obj)
end

EM.run do
  servers = {}
  consoles = {}
  hostname = Socket.gethostname

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

  amq = Bunny.new
  amq.start

  ch = amq.create_channel
  exchange = ch.topic("backend")

  ch
  .queue("workers.#{hostname}")
  .bind(exchange, :routing_key => "workers.#")
  .subscribe do |delivery_info, metadata, payload|
    case payload
    when "IDENT"
      exchange.publish(jsonify({ server_name: hostname }), :routing_key => "to_hq")
    else
      parsed = JSON.parse(payload, :symbolize_names => true)
      server_name = parsed.delete(:server_name)
      cmd = parsed.delete(:cmd)
      inst = Server.new(server_name)

      reordered = []
      inst.method(cmd).parameters.map do |req_or_opt, name|
        if parsed[name][0] == ':' then
          #if string begins with :, interpret as symbol (remove : and convert)
          reordered << parsed[name][1..-1].to_sym
        else
          reordered << parsed[name]
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
        exchange.publish(JSON.generate({:server_name => server_name, :cmd => cmd, :success => 'true', :retval => retval}),
                         :routing_key => "to_hq")
      }
      EM.defer to_call, cb
    end #end case
  end
end #EM::Run
