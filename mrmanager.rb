require 'json'
require 'eventmachine'
require 'securerandom'

EM.run do
  hostname = Socket.gethostname

  require 'yaml'
  SECRETS_PATH = File.join(File.dirname(__FILE__), 'config', 'secrets.yml')
  mineos_config = YAML::load_file(SECRETS_PATH)

  require 'bunny'
  conn = Bunny.new(:host => mineos_config['rabbitmq']['host'],
                   :port => mineos_config['rabbitmq']['port'],
                   :user => mineos_config['rabbitmq']['user'],
                   :pass => mineos_config['rabbitmq']['pass'],
                   :vhost => mineos_config['rabbitmq']['vhost'])
  conn.start

  ch = conn.create_channel
  exchange_dir = ch.topic("directives")

  directive_handler = lambda { |delivery_info, metadata, payload|
    case payload
    when 'IDENT'
      EM::Timer.new(1) do
        exchange_dir.publish({ host: hostname }.to_json,
                             :routing_key => "hq",
                             :timestamp => Time.now.to_i,
                             :type => 'receipt',
                             :correlation_id => metadata[:message_id],
                             :headers => { hostname: hostname,
                                           directive: 'IDENT' },
                             :message_id => SecureRandom.uuid)
      end
    else
      json_in = JSON.parse payload

      if json_in.key?('SPAWN') then
        require_relative 'pools'
        require 'fileutils'

        worker = json_in['SPAWN']['workerpool']
        pool_inst = Pools.new
        begin
          pool_inst.create_pool(worker, 'mypassword')
        rescue RuntimeError => e
          case e.message
          when 'pool already exists, aborting creation'
            # allow through but check if HOMEDIR exists
            FileUtils.mkdir_p "/home/#{worker}/" if !Dir.exist?("/home/#{worker}")
          when 'poolname does not fit allowable regex, aborting creation'
            # normal user running worker.rb?
            FileUtils.mkdir_p "/home/#{worker}/" if !Dir.exist?("/home/#{worker}")
          else
            raise
          end
        end

        def as_user(user, script_path, &block)
          require 'etc'
          # Find the user in the password database.
          u = (user.is_a? Integer) ? Etc.getpwuid(user) : Etc.getpwnam(user)

          # Fork the child process. Process.fork will run a given block of code
          # in the child process.
          p1 = Process.fork do
            Process.setsid
            p2 = Process.fork do
              # We're in the child. Set the process's user ID.
              Process.gid = Process.egid = u.uid
              Process.uid = Process.euid = u.uid

              # Invoke the caller's block of code.
              Dir.chdir(script_path) do
                block.call(user)
              end
            end #p2
            Process.detach(p2)
          end #p1
          Process.detach(p1)
        end

        rb_script_path = File.expand_path(File.dirname(__FILE__))

        as_user(worker, rb_script_path) do |user|
          exec "ruby worker.rb --basedir /home/#{user}/minecraft"
        end

        exchange_dir.publish({ host: hostname,
                               workerpool: worker }.to_json,
                             :routing_key => "hq",
                             :timestamp => Time.now.to_i,
                             :type => 'receipt',
                             :correlation_id => metadata[:message_id],
                             :headers => { hostname: hostname,
                                           workerpool: worker, 
                                           directive: 'SPAWN' },
                             :message_id => SecureRandom.uuid)

      elsif json_in.key?('REMOVE') then
        require_relative 'pools'

        worker = json_in['REMOVE']['workerpool']
        pool_inst = Pools.new
        pool_inst.remove_pool(worker)
      end #if
    end #case
  } #end directive_handler

  ch
  .queue('')
  .bind(exchange_dir, routing_key: "managers.#{hostname}")
  .subscribe do |delivery_info, metadata, payload|
    directive_handler.call delivery_info, metadata, payload
  end

  ch
  .queue('')
  .bind(exchange_dir, routing_key: "managers")
  .subscribe do |delivery_info, metadata, payload|
    directive_handler.call delivery_info, metadata, payload
  end

  exchange_dir.publish({ host: hostname }.to_json,
                       :routing_key => "hq",
                       :timestamp => Time.now.to_i,
                       :type => 'directive',
                       :correlation_id => nil,
                       :headers => { hostname: hostname,
                                     directive: 'IDENT' },
                       :message_id => SecureRandom.uuid)

end #EM::Run

