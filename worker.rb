require 'json'
require 'eventmachine'
require 'securerandom'
require_relative 'mineos'

require 'logger'
logger = Logger.new(STDOUT)
logger.datetime_format = '%Y-%m-%d %H:%M:%S'
logger.level = Logger::DEBUG

require 'optparse'
options = {}
OptionParser.new do |opt|
  opt.on('--basedir PATH') { |o| options[:basedir] = o }
  opt.on('--workerpool NAME') { |o| options[:workerpool] = o }
  opt.on('--secretsfile PATH') { |o| options[:secretsfile] = o }
end.parse!

if options[:basedir] then
  require 'pathname'
  BASEDIR = Pathname.new(options[:basedir]).cleanpath
else
  BASEDIR = '/var/games/minecraft'
end

if options[:secretsfile] then
  require 'pathname'
  SECRETS_PATH = Pathname.new(options[:secretsfile]).cleanpath
else
  SECRETS_PATH = File.join(File.dirname(__FILE__), 'config', 'secrets.yml')
end

EM.run do
  servers = {}
  server_loggers = {}
  hostname = Socket.gethostname
  workerpool = options[:workerpool] || ENV['USER']
  logger.info("Starting up worker pool: `#{workerpool}`")

  logger.info("Scanning servers from BASEDIR: #{BASEDIR}")
  server_dirs = Enumerator.new do |enum|
    Dir["#{BASEDIR}/servers/*"].each { |d|
      server_name = d[0..-1].match(/.*\/(.*)/)[1]
      enum.yield server_name
    }
  end

  server_dirs.each do |sn|
    #register existing servers upon startup
    servers[sn] = Server.new(sn, basedir:BASEDIR)
    logger.info("Finished setting up server instance: `#{sn}`")
  end

  require 'yaml'
  mineos_config = YAML::load_file(SECRETS_PATH)
  logger.info("Finished loading mineos secrets.")

  require 'bunny'
  conn = Bunny.new(:host => mineos_config['rabbitmq']['host'],
                   :port => mineos_config['rabbitmq']['port'],
                   :user => mineos_config['rabbitmq']['user'],
                   :pass => mineos_config['rabbitmq']['pass'],
                   :vhost => mineos_config['rabbitmq']['vhost'])
  conn.start
  logger.info("Finished creating AMQP connection.")

  ch = conn.create_channel
  exchange_cmd = ch.direct("commands")
  exchange_dir = ch.topic("directives")
  exchange_stdout = ch.direct("stdout")

  directive_handler = lambda { |delivery_info, metadata, payload|
    case payload
    when "IDENT"
      exchange_dir.publish({ host: hostname,
                             workerpool: workerpool}.to_json,
                           :routing_key => "to_hq",
                           :timestamp => Time.now.to_i,
                           :type => 'receipt.directive',
                           :correlation_id => metadata[:message_id],
                           :headers => { hostname: hostname,
                                         workerpool: workerpool,
                                         directive: 'IDENT' },
                           :message_id => SecureRandom.uuid)
      logger.info("Received IDENT directive from HQ.")
    when "LIST"
      exchange_dir.publish({ servers: server_dirs.to_a }.to_json,
                           :routing_key => "to_hq",
                           :timestamp => Time.now.to_i,
                           :type => 'receipt.directive',
                           :correlation_id => metadata[:message_id],
                           :headers => { hostname: hostname,
                                         workerpool: workerpool,
                                         directive: 'LIST' },
                           :message_id => SecureRandom.uuid)
      logger.info("Received LIST directive from HQ.")
      logger.debug({servers: server_dirs.to_a})
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
        exchange_dir.publish({ usage: retval }.to_json,
                             :routing_key => "to_hq",
                             :timestamp => Time.now.to_i,
                             :type => 'receipt.directive',
                             :correlation_id => metadata[:message_id],
                             :headers => { hostname: hostname,
                                           workerpool: workerpool,
                                           directive: 'USAGE' },
                             :message_id => SecureRandom.uuid)
        logger.info("Received USAGE directive from HQ.")
        logger.debug({usage: retval})
      end
    when /(uw_\w+)/
      require 'usagewatch'

      EM.defer do
        usw = Usagewatch
        exchange_dir.publish({ usage: {$1 =>  usw.public_send($1)} }.to_json,
                             :routing_key => "to_hq",
                             :timestamp => Time.now.to_i,
                             :type => 'receipt.directive',
                             :correlation_id => metadata[:message_id],
                             :headers => { hostname: hostname,
                                           workerpool: workerpool,
                                           directive: 'REQUEST_USAGE' },
                             :message_id => SecureRandom.uuid)
        logger.info("Received USAGE directive from HQ.")
        logger.debug({usage: {$1 =>  usw.public_send($1)}})
      end
    else
      json_in = JSON.parse payload
      if json_in.key?('AWSCREDS') then
        parsed = json_in['AWSCREDS']
  
        require 'aws-sdk-s3'
        Aws.config.update({
          endpoint: parsed['endpoint'],
          access_key_id: parsed['access_key_id'],
          secret_access_key: parsed['secret_access_key'],
          force_path_style: true,
          region: parsed['region']
        })
  
        logger.info("Received AWSCREDS directive from HQ.")

        begin
          c = Aws::S3::Client.new
        rescue ArgumentError => e
          retval = {
            endpoint: nil,
            access_key_id: nil,
            secret_access_key: nil,
            force_path_style: true,
            region: nil
          } 
          logger.error("Endpoint invalid and Aws::S3::Client.new failed. Returning:")
          logger.debug(retval)
        else
          retval = Aws.config
          logger.info("Endpoint valid and Aws::S3::Client.new returned no error")
          #logger.debug(retval)
        end
  
        exchange_dir.publish(retval.to_json,
                             :routing_key => "to_hq",
                             :timestamp => Time.now.to_i,
                             :type => 'receipt.directive',
                             :correlation_id => metadata[:message_id],
                             :headers => { hostname: hostname,
                                           workerpool: workerpool,
                                           directive: 'AWSCREDS' },
                             :message_id => SecureRandom.uuid)
      else #if unknown directive
        exchange_dir.publish({}.to_json,
                             :routing_key => "to_hq",
                             :timestamp => Time.now.to_i,
                             :type => 'receipt.directive',
                             :correlation_id => metadata[:message_id],
                             :headers => { hostname: hostname,
                                           workerpool: workerpool,
                                           directive: 'BOGUS' }, #changing directive
                             :message_id => SecureRandom.uuid)
        logger.warn("Received bogus directive from HQ. Received:")
        logger.warn(payload)
        logger.warn("Ignored as BOGUS. Returned: {}")

      end # json_in.key
    end
  }

  command_handler = lambda { |delivery_info, metadata, payload|
    parsed = JSON.parse payload
    server_name = parsed.delete("server_name")
    cmd = parsed.delete("cmd")

    logger.info("Received #{cmd} for server `#{server_name}")
    logger.info(parsed)

    if servers[server_name].is_a? Server then
      inst = servers[server_name]
    else
      inst = Server.new(server_name, basedir:BASEDIR)
      servers[server_name] = inst
    end

    if !server_loggers[server_name] then
      server_loggers[server_name] = Thread.new do
        loop do
          line = inst.console_log.shift.strip
          puts line
          exchange_stdout.publish({ msg: line,
                                    server_name: server_name }.to_json,
                                  :routing_key => "to_hq",
                                  :timestamp => Time.now.to_i,
                                  :type => 'stdout',
                                  :correlation_id => metadata[:message_id],
                                  :headers => {hostname: hostname},
                                  :message_id => SecureRandom.uuid)
        end # loop
      end # Thread.new
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
        require 'aws-sdk-s3'
        begin
          retval = inst.public_send(cmd, *reordered)
          if cmd == 'delete' then
            servers.delete(server_name)
            server_loggers.delete(server_name)
          end
          return_object[:retval] = retval
        rescue Seahorse::Client::NetworkingError => e
          logger.error("Networking error caught with s3 client!")
          logger.debug(e)
          exchange_cmd.publish(return_object.to_json,
                               :routing_key => "to_hq",
                               :timestamp => Time.now.to_i,
                               :type => 'receipt.command',
                               :correlation_id => metadata[:message_id],
                               :headers => { hostname: hostname,
                                             workerpool: workerpool,
                                             exception: { name: 'Seahorse::Client::NetworkingError',
                                                          detail: e.to_s }
                                           },
                               :message_id => SecureRandom.uuid)
        rescue IOError => e
          logger.error("IOError caught!")
          logger.error("Worker process may no longer be attached to child process?")
          exchange_cmd.publish(return_object.to_json,
                               :routing_key => "to_hq",
                               :timestamp => Time.now.to_i,
                               :type => 'receipt.command',
                               :correlation_id => metadata[:message_id],
                               :headers => { hostname: hostname,
                                             workerpool: workerpool,
                                             exception: { name: 'IOError',
                                                          detail: e.to_s }
                                           },
                               :message_id => SecureRandom.uuid)
        rescue ArgumentError => e
          logger.error("ArgumentError caught!")
          exchange_cmd.publish(return_object.to_json,
                               :routing_key => "to_hq",
                               :timestamp => Time.now.to_i,
                               :type => 'receipt.command',
                               :correlation_id => metadata[:message_id],
                               :headers => { hostname: hostname,
                                             workerpool: workerpool,
                                             exception: { name: 'ArgumentError',
                                                          detail: e.to_s }
                                           },
                               :message_id => SecureRandom.uuid)
        rescue RuntimeError => e
          logger.error("RuntimeError caught!")
          logger.debug(e)
          logger.debug(return_object)
          exchange_cmd.publish(return_object.to_json,
                               :routing_key => "to_hq",
                               :timestamp => Time.now.to_i,
                               :type => 'receipt.command',
                               :correlation_id => metadata[:message_id],
                               :headers => { hostname: hostname,
                                             workerpool: workerpool,
                                             exception: { name: 'ArgumentError',
                                                          detail: e.to_s }
                                           },
                               :message_id => SecureRandom.uuid)
        else
          return_object[:success] = true
          logger.debug(return_object)
          exchange_cmd.publish(return_object.to_json,
                               :routing_key => "to_hq",
                               :timestamp => Time.now.to_i,
                               :type => 'receipt.command',
                               :correlation_id => metadata[:message_id],
                               :headers => { hostname: hostname,
                                             workerpool: workerpool,
                                             exception: false },
                               :message_id => SecureRandom.uuid)
        end
      end #to_call

      EM.defer to_call
    else #method not defined in api
      cb = Proc.new { |retval|
        exchange_cmd.publish(return_object.to_json,
                             :routing_key => "to_hq",
                             :timestamp => Time.now.to_i,
                             :type => 'receipt.command',
                             :correlation_id => metadata[:message_id],
                             :headers => { hostname: hostname,
                                           workerpool: workerpool,
                                           exception: { name: 'NameError',
                                                        detail: "undefined method `#{cmd}' for class `Server'" }
                                         },
                             :message_id => SecureRandom.uuid)
      }
      EM.defer cb
    end #inst.respond_to

  }

  ch
  .queue('', exclusive: true)
  .bind(exchange_cmd, routing_key: "to_workers.#{hostname}.#{workerpool}")
  .subscribe do |delivery_info, metadata, payload|
    #logger.debug("received cmd: #{payload}")
    command_handler.call delivery_info, metadata, payload
  end

  ch
  .queue('')
  .bind(exchange_dir, routing_key: "to_workers")
  .subscribe do |delivery_info, metadata, payload|
    #logger.debug("received dir: #{payload}")
    directive_handler.call delivery_info, metadata, payload
  end

  exchange_dir.publish({ host: hostname,
                         workerpool: workerpool }.to_json,
                       :routing_key => "to_hq",
                       :timestamp => Time.now.to_i,
                       :type => 'receipt.directive',
                       :correlation_id => nil,
                       :headers => { hostname: hostname,
                                     workerpool: workerpool,
                                     directive: 'IDENT' },
                       :message_id => SecureRandom.uuid)
  logger.info("Sent IDENT message.")
  logger.info("Worker node set up and listening.")

end #EM::Run
