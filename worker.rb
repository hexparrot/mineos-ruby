require 'json'
require 'eventmachine'
require 'securerandom'
require './mineos'

require 'logger'
logger = Logger.new(STDOUT)
logger.datetime_format = '%Y-%m-%d %H:%M:%S'
logger.level = Logger::DEBUG
 
EM.run do
  servers = {}
  server_loggers = {}
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

  require 'yaml'
  mineos_config = YAML::load_file('config/secrets.yml')

  require 'bunny'
  conn = Bunny.new(:host => mineos_config['rabbitmq']['host'],
                   :port => mineos_config['rabbitmq']['port'],
                   :user => mineos_config['rabbitmq']['user'],
                   :pass => mineos_config['rabbitmq']['pass'],
                   :vhost => mineos_config['rabbitmq']['vhost'])
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
    else
      json_in = JSON.parse payload
      parsed = json_in['AWSCREDS']

      require 'aws-sdk-s3'
      Aws.config.update({
        endpoint: parsed['endpoint'],
        access_key_id: parsed['access_key_id'],
        secret_access_key: parsed['secret_access_key'],
        force_path_style: parsed['force_path_style'],
        region: parsed['region']
      })

      exchange.publish(Aws.config.to_json,
                       :routing_key => "to_hq",
                       :timestamp => Time.now.to_i,
                       :type => 'receipt.directive',
                       :correlation_id => metadata[:message_id],
                       :headers => {hostname: hostname,
                                    directive: 'AWSCREDS'},
                       :message_id => SecureRandom.uuid)

    end
  }

  command_handler = lambda { |delivery_info, metadata, payload|
    parsed = JSON.parse payload
    server_name = parsed.delete("server_name")
    cmd = parsed.delete("cmd")

    logger.info("Received #{cmd} for server `#{server_name}")
    logger.info(parsed)

    if servers[server_name].is_a?(Server) then
      logger.debug("using existing instance for #{server_name}")
      inst = servers[server_name]
    else
      logger.debug("creating new instance for #{server_name}")
      inst = Server.new(server_name)
      servers[server_name] = inst

      #Thread.new do
      #  server_loggers[server_name] = Logger.new(STDOUT)
      #  server_loggers[server_name].datetime_format = "%H:%M:%S [#{server_name}]"
      #  server_loggers[server_name].level = Logger::INFO
      #  loop do
      #    server_loggers[server_name].info(inst.console_log.pop.strip)
      #  end
      #end

    end

    return_object = {server_name: server_name, cmd: cmd, success: false, retval: nil}

    if inst.respond_to?(cmd) then
      reordered = []
      inst.method(cmd).parameters.map do |req_or_opt, name|
        begin
          if parsed[name.to_s][0] == ':' then
            #if string begins with :, interpret as symbol (remove : and convert)
            reordered << parsed[name.to_s][1..-1].to_sym
          else
            reordered << parsed[name.to_s]
          end
        rescue NoMethodError => e
          #logger.debug(e)
          #occurs if optional arguments are not provided (non-fatal)
          #invalid arguments will break at inst.public_send below
          #break out if first argument opt or not is absent
          break
        end
      end #map

      to_call = Proc.new do
        begin
          retval = inst.public_send(cmd, *reordered)
          if cmd == 'delete' then
            servers.delete_if { |key,value| key == server_name  }
          end
        rescue IOError
          logger.error("IOError caught!")
        rescue ArgumentError => e
          logger.error("ArgumentError caught!")
          exchange.publish(return_object.to_json,
                           :routing_key => "to_hq",
                           :timestamp => Time.now.to_i,
                           :type => 'receipt.command',
                           :correlation_id => metadata[:message_id],
                           :headers => {hostname: hostname,
                                        exception: {name: 'ArgumentError',
                                                    detail: e.to_s }},
                           :message_id => SecureRandom.uuid)
        rescue RuntimeError => e
          logger.error("RuntimeError caught!")
          logger.info(e)
          logger.debug(return_object)
          exchange.publish(return_object.to_json,
                           :routing_key => "to_hq",
                           :timestamp => Time.now.to_i,
                           :type => 'receipt.command',
                           :correlation_id => metadata[:message_id],
                           :headers => {hostname: hostname,
                                        exception: {name: 'ArgumentError',
                                                    detail: e.to_s }},
                           :message_id => SecureRandom.uuid)

        end
        retval #necessary because inst.public_send used to implicitly ret value
      end #to_call

      cb = Proc.new { |retval|
        return_object[:retval] = retval
        return_object[:success] = true
        exchange.publish(return_object.to_json,
                         :routing_key => "to_hq",
                         :timestamp => Time.now.to_i,
                         :type => 'receipt.command',
                         :correlation_id => metadata[:message_id],
                         :headers => {hostname: hostname,
                                      exception: false},
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
                         :headers => {hostname: hostname,
                                      exception: {name: 'NameError',
                                                  detail: "undefined method `#{cmd}' for class `Server'" }},
                         :message_id => SecureRandom.uuid)
      }
      EM.defer cb
    end #inst.respond_to

  }

  ch
  .queue('')
  .bind(exchange, :routing_key => 'to_workers.#')
  .subscribe do |delivery_info, metadata, payload|
    #logger.debug(delivery_info)
    #logger.debug(metadata)
    #logger.debug(payload)
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

  exchange.publish({host: hostname}.to_json,
                    :routing_key => "to_hq",
                    :timestamp => Time.now.to_i,
                    :type => 'receipt.directive',
                    :correlation_id => nil,
                    :headers => {hostname: hostname,
                                 directive: 'IDENT'},
                    :message_id => SecureRandom.uuid)

end #EM::Run
