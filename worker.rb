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
  opt.on('--amqp-filepath PATH') { |o| options[:amqp_file] = o }
  opt.on('--amqp-stdin') { |o| options[:amqp_stdin] = o }
end.parse!

if options[:basedir] then
  require 'pathname'
  BASEDIR = Pathname.new(options[:basedir]).cleanpath
  logger.info("STARTUP: Using command-line provided BASEDIR `#{BASEDIR}`")
else
  BASEDIR = '/var/games/minecraft'
  logger.info("STARTUP: Using default BASEDIR `#{BASEDIR}`")
end

if options[:workerpool] then
  WHOAMI = options[:workerpool]
  logger.info("STARTUP: Using command-line provided poolname `#{WHOAMI}`")
else
  require 'etc'
  WHOAMI = Etc.getpwuid(Process.uid).name
  logger.info("STARTUP: Using default poolname `#{WHOAMI}`")
end

require 'yaml'
amqp_creds = nil
if options[:amqp_stdin] then
  if !STDIN.tty? then # if STDIN is not attached to terminal (being piped to, instead)
    amqp_creds = YAML::load($stdin.read)
    logger.info("AMQP: Detected piped content via STDIN")
  else
    logger.error("AMQP: Specified piped creds, but couldn't detect piped content via STDIN")
    raise RuntimeError.new("STDIN expecting piped input but received none")
  end
elsif options[:amqp_file] then
  require 'pathname'

  normalized_path = Pathname.new(options[:rabbit_creds]).cleanpath
  amqp_creds = YAML::load_file(normalized_path)['amqp']
  logger.info("AMQP: Specified creds via filepath")
else
  fallback_path = "/usr/local/etc/amqp.yml"
  amqp_creds = YAML::load_file(fallback_path)['amqp']
  logger.info("AMQP: Using credentials from location: #{amqp_creds}")
end

EM.run do
  servers = {}
  server_loggers = {}
  hostname = Socket.gethostname
  workerpool = WHOAMI
  logger.info("STARTUP: `workers.#{hostname}.#{workerpool}`")

  logger.info("STARTUP: Detecting servers in BASEDIR: #{BASEDIR}")
  server_dirs = Enumerator.new do |enum|
    Dir["#{BASEDIR}/servers/*"].each { |d|
      server_name = d[0..-1].match(/.*\/(.*)/)[1]
      enum.yield server_name
    }
  end

  server_dirs.each do |sn|
    #register existing servers upon startup
    servers[sn] = Server.new(sn, basedir:BASEDIR)
    logger.info("STARTUP: Finished setting up server instance: `#{sn}`")
  end

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

  directive_handler = lambda { |delivery_info, metadata, payload|
    case payload
    when "IDENT"
      logger.info("IDENT: Received directive from HQ.")
      exchange.publish({ hostname: hostname,
                         workerpool: workerpool }.to_json,
                       :routing_key => "hq",
                       :timestamp => Time.now.to_i,
                       :type => 'receipt.directive',
                       :correlation_id => metadata[:message_id],
                       :headers => { hostname: hostname,
                                     workerpool: workerpool,
                                     directive: 'IDENT' },
                       :message_id => SecureRandom.uuid)
      logger.info("IDENT: Sent receipt to HQ.")
    when "LIST"
      logger.info("LIST: Received directive from HQ.")
      exchange.publish({ servers: server_dirs.to_a }.to_json,
                       :routing_key => "hq",
                       :timestamp => Time.now.to_i,
                       :type => 'receipt',
                       :correlation_id => metadata[:message_id],
                       :headers => { hostname: hostname,
                                     workerpool: workerpool,
                                     directive: 'LIST' },
                       :message_id => SecureRandom.uuid)
      logger.info("LIST: Sent receipt to HQ.")
      logger.debug({servers: server_dirs.to_a})
    when "USAGE"
      require 'usagewatch'

      logger.info("USAGE: Received directive from HQ.")

      EM.defer do
        usw = Usagewatch
        retval = {
          uw_cpuused: usw.uw_cpuused,
          uw_memused: usw.uw_memused,
          uw_load: usw.uw_load,
          uw_diskused: usw.uw_diskused,
          uw_diskused_perc: usw.uw_diskused_perc,
        }
        exchange.publish({ usage: retval }.to_json,
                         :routing_key => "hq",
                         :timestamp => Time.now.to_i,
                         :type => 'receipt',
                         :correlation_id => metadata[:message_id],
                         :headers => { hostname: hostname,
                                       workerpool: workerpool,
                                       directive: 'USAGE' },
                         :message_id => SecureRandom.uuid)
        logger.info("USAGE: Sent receipt to HQ.")
        logger.debug({usage: retval})
      end
    when /(uw_\w+)/
      require 'usagewatch'

      logger.info("USAGE: Received uw_ directive from HQ.")

      EM.defer do
        usw = Usagewatch
        exchange.publish({ usage: {$1 =>  usw.public_send($1)} }.to_json,
                         :routing_key => "hq",
                         :timestamp => Time.now.to_i,
                         :type => 'receipt',
                         :correlation_id => metadata[:message_id],
                         :headers => { hostname: hostname,
                                       workerpool: workerpool,
                                       directive: 'REQUEST_USAGE' },
                         :message_id => SecureRandom.uuid)
        logger.info("USAGE: Sent receipt to HQ.")
        logger.debug({usage: {$1 =>  usw.public_send($1)}})
      end
    when "VERIFY_OBJSTORE"
      require 'aws-sdk-s3'

      logger.info("VERIFY_OBJSTORE: Received directive from HQ.")
      EM.defer do
        if Aws.config.empty? then
          exchange.publish('',
                           :routing_key => "hq",
                           :timestamp => Time.now.to_i,
                           :type => 'receipt.directive',
                           :correlation_id => metadata[:message_id],
                           :headers => { hostname: hostname,
                                         workerpool: workerpool,
                                         directive: 'VERIFY_OBJSTORE' },
                           :message_id => SecureRandom.uuid)
          logger.info("VERIFY_OBJSTORE: Sent nil ACK back to HQ.")
        end
      end
    else
      json_in = JSON.parse payload
      if json_in.key?('AWSCREDS') then
        require 'aws-sdk-s3'

        logger.info("AWSCREDS: Received directive from HQ.")

        parsed = json_in['AWSCREDS']
        Aws.config.update({
          endpoint: parsed['endpoint'],
          access_key_id: parsed['access_key_id'],
          secret_access_key: parsed['secret_access_key'],
          force_path_style: true,
          region: parsed['region']
        })

        begin
          c = Aws::S3::Client.new
        rescue ArgumentError => e
          retval = false
          logger.error("AWSCREDS: Endpoint invalid and Aws::S3::Client.new failed.")
        else
          retval = true
          logger.info("AWSCREDS: Endpoint valid and Aws::S3::Client.new returned no error")
        end
  
        exchange.publish(retval.to_json,
                         :routing_key => "hq",
                         :timestamp => Time.now.to_i,
                         :type => 'receipt',
                         :correlation_id => metadata[:message_id],
                         :headers => { hostname: hostname,
                                       workerpool: workerpool,
                                       directive: 'AWSCREDS' },
                         :message_id => SecureRandom.uuid)
        logger.info("AWSCREDS: Alerting HQ of connection status of `#{retval}`")
      else #if unknown directive
        exchange.publish({}.to_json,
                         :routing_key => "hq",
                         :timestamp => Time.now.to_i,
                         :type => 'receipt',
                         :correlation_id => metadata[:message_id],
                         :headers => { hostname: hostname,
                                       workerpool: workerpool,
                                       directive: 'BOGUS' }, #changing directive
                         :message_id => SecureRandom.uuid)
        logger.warn("DIRECTIVE: Received bogus directive from HQ.")
        logger.warn(payload)
        logger.warn("DIRECTIVE: Ignored, Returned: {}")

      end # json_in.key
    end
  }

  command_handler = lambda { |delivery_info, metadata, payload|
    parsed = JSON.parse payload
    server_name = parsed.delete("server_name")
    cmd = parsed.delete("cmd")

    logger.info("CMD: Received #{cmd} for server `#{server_name}")
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
          exchange_stdout.publish({ msg: line,
                                    server_name: server_name }.to_json,
                                  :routing_key => "hq",
                                  :timestamp => Time.now.to_i,
                                  :type => 'stdout',
                                  :correlation_id => metadata[:message_id],
                                  :headers => { hostname: hostname,
                                                workerpool: workerpool },
                                  :message_id => SecureRandom.uuid)
          #logger.debug(line)
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
          logger.error("S3: Networking error caught with s3 client!")
          logger.debug(e)
          exchange.publish(return_object.to_json,
                           :routing_key => "hq",
                           :timestamp => Time.now.to_i,
                           :type => 'receipt.command',
                           :correlation_id => metadata[:message_id],
                           :headers => { hostname: hostname,
                                         workerpool: workerpool,
                                         exception: { name: 'Seahorse::Client::NetworkingError',
                                                      detail: e.to_s }
                                       },
                           :message_id => SecureRandom.uuid)
          logger.error("S3: Sent exception information to HQ")
        rescue IOError => e
          logger.error("WORKER: IOError caught!")
          logger.error("WORKER: Worker process may no longer be attached to child process?")
          exchange.publish(return_object.to_json,
                           :routing_key => "hq",
                           :timestamp => Time.now.to_i,
                           :type => 'receipt.command',
                           :correlation_id => metadata[:message_id],
                           :headers => { hostname: hostname,
                                         workerpool: workerpool,
                                         exception: { name: 'IOError',
                                                      detail: e.to_s }
                                       },
                           :message_id => SecureRandom.uuid)
          logger.error("WORKER: Sent exception information to HQ")
        rescue ArgumentError => e
          # e.g., too few arguments
          logger.error("WORKER: ArgumentError caught!")
          exchange.publish(return_object.to_json,
                           :routing_key => "hq",
                           :timestamp => Time.now.to_i,
                           :type => 'receipt',
                           :correlation_id => metadata[:message_id],
                           :headers => { hostname: hostname,
                                         workerpool: workerpool,
                                         exception: { name: 'ArgumentError',
                                                      detail: e.to_s }
                                       },
                           :message_id => SecureRandom.uuid)
          logger.error("WORKER: Sent exception information to HQ")
        rescue RuntimeError => e
          logger.error("WORKER: RuntimeError caught!")
          logger.debug(e)
          logger.debug(return_object)
          exchange.publish(return_object.to_json,
                           :routing_key => "hq",
                           :timestamp => Time.now.to_i,
                           :type => 'receipt.command',
                           :correlation_id => metadata[:message_id],
                           :headers => { hostname: hostname,
                                         workerpool: workerpool,
                                         exception: { name: 'ArgumentError',
                                                      detail: e.to_s }
                                       },
                           :message_id => SecureRandom.uuid)
          logger.error("WORKER: Sent exception information to HQ")
        else
          return_object[:success] = true
          exchange.publish(return_object.to_json,
                           :routing_key => "hq",
                           :timestamp => Time.now.to_i,
                           :type => 'receipt',
                           :correlation_id => metadata[:message_id],
                           :headers => { hostname: hostname,
                                         workerpool: workerpool,
                                         exception: false },
                           :message_id => SecureRandom.uuid)
          logger.debug("WORKER: Command accepted and executed")
          logger.debug(return_object)
        end
      end #to_call

      EM.defer to_call
    else #method not defined in api
      cb = Proc.new { |retval|
        exchange.publish(return_object.to_json,
                         :routing_key => "hq",
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
        logger.warn("WORKER: Method not defined in api `#{cmd}`")
      EM.defer cb
    end #inst.respond_to

  }

  ch
  .queue("workers.#{hostname}.#{workerpool}")
  .bind(exchange, routing_key: "workers.#.#")
  .subscribe do |delivery_info, metadata, payload|
    #logger.debug("received cmd: #{payload}")
    if delivery_info[:routing_key] == "workers.#{hostname}.#{workerpool}" then
      case metadata[:type]
      when 'command'
        command_handler.call delivery_info, metadata, payload
      when 'directive'
        directive_handler.call delivery_info, metadata, payload
      end
    elsif delivery_info[:routing_key] == "workers" && metadata[:type] == "directive" then
      directive_handler.call delivery_info, metadata, payload
    end
  end

  exchange.publish({ hostname: hostname,
                     workerpool: workerpool }.to_json,
                   :routing_key => "hq",
                   :timestamp => Time.now.to_i,
                   :type => 'init',
                   :headers => { hostname: hostname,
                                 workerpool: workerpool,
                                 directive: 'IDENT' },
                   :message_id => SecureRandom.uuid)
  logger.info("IDENT: Sent startup identification")
  logger.info("STARTUP: Worker node set up and listening.")

end #EM::Run
