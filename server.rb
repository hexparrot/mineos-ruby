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
        exchange.publish(JSON.generate({:server_name => server_name, :cmd => 'create', :success => 'true'}),
                         :routing_key => "to_hq")
      }
      EM.defer to_call, cb
    end #end case
  end
#puts 'subbing'
#puts payload
#    parsed = JSON.parse(payload, :symbolize_names => true)
#puts parsed
#    server_name = parsed.delete(:server_name)
#    cmd = parsed.delete(:cmd)
#
#    reordered = []
#    inst = Server.new(server_name)
#
#    puts parsed, server_name, cmd
#    return if !inst
#    inst.method(cmd).parameters.map do |req_or_opt, name|
#      if parsed[name][0] == ':' then
#        #if string begins with :, interpret as symbol (remove : and convert)
#        reordered << parsed[name][1..-1].to_sym
#      else
#        reordered << parsed[name]
#      end
#    end
#
#    to_call = Proc.new do
#      begin
#        inst.public_send(cmd, *reordered)
#      rescue IOError
#        puts "IOERROR CAUGHT"
#      end
#    end
#    EM.defer to_call
#  end
#    cb = Proc.new { |retval| ws.send JSON.generate({:channel => server_name, :retval => retval}) }
#    EM.defer to_call, cb
#  EM::WebSocket.run(:host => "0.0.0.0", :port => 8000) do |ws|
#    ws.onopen do |handshake|
#      p handshake
#      ws.send JSON.generate({:hostname => hostname})
#      server_dirs.each do |sn|
#        #websocket should be limited to 1, but until limit implemented, use consoles {}
#        if !consoles.key?(sn)
#          consoles[server_name] = Thread.new do
#            loop do
#              line = servers[server_name].console_log.shift
#              ws.send JSON.generate({:channel => server_name, :message => line})
#            end
#          end
#        end
#      end
#    end #onopen
#
#    ws.onclose do
#      consoles.delete_if do |key, t|
#        t.exit
#      end
#    end #onclose
# 
#    ws.onmessage do |msg|
#      begin
#        parsed = JSON.parse msg, :symbolize_names => true
#        server_name = parsed.delete(:server_name)
#        cmd = parsed.delete(:cmd)
#      rescue
#        next
#      end
#
#      if server_name then
#        servers[server_name] = Server.new(server_name) unless servers.key?(server_name)
#        inst = servers[server_name]
#      end
#
#      p cmd
#      if cmd == 'disconnect' then
#        ws.close 1000
#      elsif cmd == 'getdirs'
#        server_dirs.each do |sn|
#          ws.send JSON.generate({:found_dir => sn })
#        end
#      else
#        reordered = []
#        inst.method(cmd).parameters.map do |req_or_opt, name|
#          if parsed[name][0] == ':' then
#            #if string begins with :, interpret as symbol (remove : and convert)
#            reordered << parsed[name][1..-1].to_sym
#          else
#            reordered << parsed[name]
#          end
#        end
# 
#        to_call = Proc.new do
#          begin
#            inst.public_send(cmd, *reordered)
#          rescue IOError
#            puts "IOERROR CAUGHT"
#          end
#        end
#        cb = Proc.new { |retval| ws.send JSON.generate({:channel => server_name, :retval => retval}) }
#        EM.defer to_call, cb
#
#      end
#      p 'done'
#
#    end #onmessage
#
#  end #EM::Websocket
#
end #EM::Run
