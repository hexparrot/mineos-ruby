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
    exchange_dir.publish({ host: hostname }.to_json,
                         :routing_key => "to_hq",
                         :timestamp => Time.now.to_i,
                         :type => 'receipt.directive',
                         :correlation_id => metadata[:message_id],
                         :headers => { hostname: hostname,
                                       directive: 'IDENT' },
                         :message_id => SecureRandom.uuid)
  }

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
