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
      exchange_dir.publish({ host: hostname }.to_json,
                           :routing_key => "to_hq",
                           :timestamp => Time.now.to_i,
                           :type => 'receipt.directive',
                           :correlation_id => metadata[:message_id],
                           :headers => { hostname: hostname,
                                         directive: 'IDENT' },
                           :message_id => SecureRandom.uuid)
    else
      json_in = JSON.parse payload
      if json_in.key?('SPAWN') then

        def as_user(user, &block)
          # http://brizzled.clapper.org/blog/2011/01/01/running-a-ruby-block-as-another-user/
          require 'etc'
          # Find the user in the password database.
          u = (user.is_a? Integer) ? Etc.getpwuid(user) : Etc.getpwnam(user)

          # Fork the child process. Process.fork will run a given block of code
          # in the child process.
          Process.fork do
            # We're in the child. Set the process's user ID.
            Process.gid = Process.egid = u.uid
            Process.uid = Process.euid = u.uid

            # Invoke the caller's block of code.
            Dir.chdir(File.dirname(__FILE__)) do
              block.call()
            end
          end
        end

        worker = json_in['SPAWN']['workerpool']
        as_user worker do
          exec "ruby worker.rb"
        end

        pid = 5

        exchange_dir.publish({ host: hostname,
                               workerpool: worker,
                               pid: 5 }.to_json,
                             :routing_key => "to_hq",
                             :timestamp => Time.now.to_i,
                             :type => 'receipt.directive',
                             :correlation_id => metadata[:message_id],
                             :headers => { hostname: hostname,
                                           workerpool: worker, 
                                           directive: 'SPAWN' },
                             :message_id => SecureRandom.uuid)

      end #if
    end #case
  } #end directive_handler

  ch
  .queue('')
  .bind(exchange_dir, routing_key: "to_managers.#{hostname}")
  .subscribe do |delivery_info, metadata, payload|
    directive_handler.call delivery_info, metadata, payload
  end

  ch
  .queue('')
  .bind(exchange_dir, routing_key: "to_managers")
  .subscribe do |delivery_info, metadata, payload|
    directive_handler.call delivery_info, metadata, payload
  end

  exchange_dir.publish({ host: hostname }.to_json,
                       :routing_key => "to_hq",
                       :timestamp => Time.now.to_i,
                       :type => 'receipt.directive',
                       :correlation_id => nil,
                       :headers => { hostname: hostname,
                                     directive: 'IDENT' },
                       :message_id => SecureRandom.uuid)

end #EM::Run

