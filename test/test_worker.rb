require 'minitest/autorun'
require 'eventmachine'
require 'bunny'
require 'json'
require 'securerandom'
require 'socket'

class ServerTest < Minitest::Test

  def setup
    # this test assumes a worker instance is up, as a separate process
    @@basedir = '/var/games/minecraft'
    @@hostname = Socket.gethostname
    @@workerpool = ENV['USER']

    require 'yaml'
    amqp_creds = YAML::load_file('config/amqp.yml')['rabbitmq'].transform_keys(&:to_sym)

    require 'bunny'
    conn = Bunny.new(amqp_creds)
    conn.start

    @ch = conn.create_channel
    @exchange = @ch.topic('backend')

    require 'fileutils'
    FileUtils.rm_rf(@@basedir)
    FileUtils.mkdir_p(File.join(@@basedir, 'servers'))
    FileUtils.mkdir_p(File.join(@@basedir, 'backup'))
    FileUtils.mkdir_p(File.join(@@basedir, 'archive'))
  end

  def teardown
    sleep(0.3)
  end

  def test_ident
    # sends an IDENT directive (from HQ) to workers,
    # expects back hostname & workerpool name (process owner)
    guid = SecureRandom.uuid
    step = 0

    EM.run do
      @ch
      .queue('hq')
      .bind(@exchange, :routing_key => "hq")
      .subscribe do |delivery_info, metadata, payload|
        parsed = JSON.parse payload
        assert_equal(@@hostname, parsed['hostname'])
        assert_equal(@@workerpool, parsed['workerpool'])
        assert_equal(guid, metadata.correlation_id)
        assert_equal('receipt', metadata.type)
        assert_equal('IDENT', metadata[:headers]['directive'])
        assert_equal(@@hostname, metadata[:headers]['hostname'])
        assert_equal(@@workerpool, metadata[:headers]['workerpool'])
        assert(metadata.timestamp)
        assert(metadata.message_id)
        step += 1
        EM.stop
      end

      @exchange.publish('IDENT',
                        :routing_key => "workers",
                        :type => "directive",
                        :message_id => guid,
                        :timestamp => Time.now.to_i)
    end
    assert_equal(1, step)
  end

  def test_serverlist
    # sends a LIST directive (from HQ) to workers,
    # expects list of servers that hostname/workerpool has
    # detected (running or not)
    guid = SecureRandom.uuid
    step = 0

    EM.run do
      # 2) worker returns receipt of creation
      @ch
      .queue('hq')
      .bind(@exchange, :routing_key => "hq")
      .subscribe do |delivery_info, metadata, payload|
        # 3) hq sends out request for LIST of servers
        # no assertions, since create command not important here
        @exchange.publish('LIST',
                          :routing_key => "workers",
                          :type => "directive",
                          :message_id => guid,
                          :timestamp => Time.now.to_i)
        step += 1
      end

      # 4) worker returns receipt of LIST
      @ch
      .queue('hq')
      .bind(@exchange, :routing_key => "hq")
      .subscribe do |delivery_info, metadata, payload|
        parsed = JSON.parse payload
        servers = parsed['servers']
        assert_equal('test', servers.first)
        assert_equal(1, servers.length)
        assert_equal(guid, metadata.correlation_id)
        assert_equal('receipt', metadata.type)
        assert_equal('LIST', metadata[:headers]['directive'])
        assert_equal(@@hostname, metadata[:headers]['hostname'])
        assert_equal(@@workerpool, metadata[:headers]['workerpool'])
        assert(metadata.timestamp)
        assert(metadata.message_id)
        EM.stop
        step += 1
      end

      # 1) create server via cmd channel
      @exchange.publish({ cmd: 'create',
                          server_name: 'test' }.to_json,
                        :routing_key => "workers.#{@@hostname}.#{@@workerpool}",
                        :type => "command",
                        :message_id => SecureRandom.uuid,
                        :timestamp => Time.now.to_i)
    end
    assert_equal(2, step)
  end

  def test_create_server_explicit_parameters
    guid = SecureRandom.uuid
    step = 0

    EM.run do
      # 2) worker returns receipt of creation
      @ch
      .queue('hq')
      .bind(@exchange, :routing_key => "hq")
      .subscribe do |delivery_info, metadata, payload|
        parsed = JSON.parse payload
        assert_equal('test', parsed['server_name'])
        assert_equal('create', parsed['cmd'])
        assert_equal(true, parsed['success'])
        assert_equal(guid, metadata.correlation_id)
        assert_equal('receipt', metadata.type)
        assert_equal(@@hostname, metadata[:headers]['hostname'])
        assert_equal(@@workerpool, metadata[:headers]['workerpool'])
        assert_equal(false, metadata[:headers]['exception'])
        assert(metadata.timestamp)
        assert(metadata.message_id)

        step += 1
        EM.stop
      end
 
      # 1) create server via cmd channel
      @exchange.publish({ cmd: 'create',
                          server_name: 'test',
                          server_type: ':conventional_jar' }.to_json,
                        :routing_key => "workers.#{@@hostname}.#{@@workerpool}",
                        :type => "command",
                        :message_id => guid,
                        :timestamp => Time.now.to_i)
    end
    assert_equal(1, step)
  end

  def test_create_server_implicit_parameters
    guid = SecureRandom.uuid
    step = 0

    EM.run do
      # 2) worker returns receipt of creation
      @ch
      .queue('hq')
      .bind(@exchange, :routing_key => "hq")
      .subscribe do |delivery_info, metadata, payload|
        parsed = JSON.parse payload
        assert_equal('test', parsed['server_name'])
        assert_equal('create', parsed['cmd'])
        assert_equal(true, parsed['success'])

        assert_equal(guid, metadata.correlation_id)
        assert_equal('receipt', metadata.type)
        assert_equal(@@hostname, metadata[:headers]['hostname'])
        assert_equal(@@workerpool, metadata[:headers]['workerpool'])
        assert_equal(false, metadata[:headers]['exception'])
        assert(metadata.timestamp)
        assert(metadata.message_id)

        step += 1
        EM.stop
      end

      # 1) create server via cmd channel
      @exchange.publish({ cmd: 'create',
                          server_name: 'test' }.to_json,
                        :routing_key => "workers.#{@@hostname}.#{@@workerpool}",
                        :type => "command",
                        :message_id => guid,
                        :timestamp => Time.now.to_i)
    end
    assert_equal(1, step)
  end


  def test_get_start_args
    # tests cmd-level receipts
    step = 0
    EM.run do

      # 2) worker returns receipt
      @ch
      .queue('hq')
      .bind(@exchange, :routing_key => "hq")
      .subscribe do |delivery_info, metadata, payload|
        parsed = JSON.parse payload
        case step
        when 0
          # 2.1) setting s.c. settings, not testing reply here
          @exchange.publish({ cmd: 'modify_sc', server_name: 'test', attr: 'jarfile',
                              value: 'minecraft_server.1.8.9.jar', section: 'java' }.to_json,
                            :routing_key => "workers.#{@@hostname}.#{@@workerpool}",
                            :timestamp => Time.now.to_i,
                            :type => 'command',
                            :message_id => SecureRandom.uuid)
        when 1
          # 2.2) continuation
          @exchange.publish({ cmd: 'modify_sc', server_name: 'test', attr: 'java_xmx',
                              value: 384, section: 'java' }.to_json,
                            :routing_key => "workers.#{@@hostname}.#{@@workerpool}",
                            :timestamp => Time.now.to_i,
                            :type => 'command',
                            :message_id => SecureRandom.uuid)
        when 2
          # 2.3) continuation
          @exchange.publish({ cmd: 'modify_sc', server_name: 'test', attr: 'java_xms',
                              value: 384, section: 'java' }.to_json,
                            :routing_key => "workers.#{@@hostname}.#{@@workerpool}",
                            :timestamp => Time.now.to_i,
                            :type => 'command',
                            :message_id => SecureRandom.uuid)
        when 3
          # 2.4) requesting worker send start args
          @exchange.publish({ cmd: 'get_start_args', server_name: 'test', type: ':conventional_jar' }.to_json,
                            :routing_key => "workers.#{@@hostname}.#{@@workerpool}",
                            :timestamp => Time.now.to_i,
                            :type => 'command',
                            :message_id => SecureRandom.uuid)
        when 4
          retval = parsed['retval']
          assert_equal("/usr/bin/java", retval[0])
          assert_equal("-server", retval[1])
          assert_equal("-Xmx384M", retval[2])
          assert_equal("-Xms384M", retval[3])
          assert_equal("-jar", retval[4])
          assert_equal("minecraft_server.1.8.9.jar", retval[5])
          assert_equal("nogui", retval[6])

          assert_equal('receipt', metadata.type)
          assert_equal(false, metadata[:headers]['exception'])
          assert(metadata.timestamp)
          assert(metadata.message_id)
          assert(metadata.correlation_id)

          EM.stop
        end
        step += 1
      end
 
      # 1) create server via cmd channel
      @exchange.publish({ cmd: 'create', server_name: 'test', server_type: ':conventional_jar' }.to_json,
                        :routing_key => "workers.#{@@hostname}.#{@@workerpool}",
                        :timestamp => Time.now.to_i,
                        :type => 'command',
                        :message_id => SecureRandom.uuid)
    end
    assert_equal(5, step)
  end

  def test_usage
    # request heartbeat-level usage information from worker
    guid = SecureRandom.uuid
    step = 0

    EM.run do
      # 2) worker returns receipt of USAGE directive
      @ch
      .queue('hq')
      .bind(@exchange, :routing_key => "hq")
      .subscribe do |delivery_info, metadata, payload|
        parsed = JSON.parse payload
        assert(parsed['usage'].key?('uw_cpuused'))
        assert(parsed['usage'].key?('uw_memused'))
        assert(parsed['usage'].key?('uw_load'))
        assert(parsed['usage'].key?('uw_diskused'))
        assert(parsed['usage'].key?('uw_diskused_perc'))

        assert_equal(guid, metadata.correlation_id)
        assert_equal('receipt', metadata.type)
        assert_equal('USAGE', metadata[:headers]['directive'])
        assert_equal(@@hostname, metadata[:headers]['hostname'])
        assert_equal(@@workerpool, metadata[:headers]['workerpool'])
        assert(metadata.timestamp)
        assert(metadata.message_id)

        step += 1
        EM.stop
      end

      # 1) request workers return usage
      @exchange.publish('USAGE',
                        :routing_key => "workers",
                        :type => "directive",
                        :message_id => guid,
                        :timestamp => Time.now.to_i)
    end
    assert_equal(1, step)
  end

  def test_request_usage
    # request specific usage statistic from worker
    guid = SecureRandom.uuid
    step = 0

    # 2) worker returns receipt of USAGE directive
    EM.run do
      @ch
      .queue('hq')
      .bind(@exchange, :routing_key => "hq")
      .subscribe do |delivery_info, metadata, payload|
        parsed = JSON.parse payload
        assert(parsed['usage'].key?('uw_cpuused'))

        assert_equal(guid, metadata.correlation_id)
        assert_equal('receipt', metadata.type)
        assert_equal('REQUEST_USAGE', metadata[:headers]['directive'])
        assert_equal(@@hostname, metadata[:headers]['hostname'])
        assert_equal(@@workerpool, metadata[:headers]['workerpool'])
        assert(metadata.timestamp)
        assert(metadata.message_id)

        step += 1
        EM.stop
      end
  
      # 1) request workers return specific usage
      @exchange.publish('uw_cpuused',
                        :routing_key => "workers",
                        :type => 'directive',
                        :message_id => guid,
                        :timestamp => Time.now.to_i)
    end
    assert_equal(1, step)
  end

  def test_bogus_command
    # tests for bogus commands being sanitized and returned
    guid = SecureRandom.uuid
    step = 0

    EM.run do
    # 2) worker returns receipt of BOGUS directive
      @ch
      .queue('hq')
      .bind(@exchange, :routing_key => "hq")
      .subscribe do |delivery_info, metadata, payload|
        parsed = JSON.parse payload
        assert_equal('test', parsed['server_name'])
        assert_equal('fakeo', parsed['cmd'])
        assert_equal(false, parsed['success'])

        assert_equal(guid, metadata.correlation_id)
        assert_equal('receipt.command', metadata.type)
        assert_equal(@@hostname, metadata[:headers]['hostname'])
        assert_equal(@@workerpool, metadata[:headers]['workerpool'])
        assert_equal('NameError', metadata[:headers]['exception']['name'])
        assert_equal("undefined method `fakeo' for class `Server'", metadata[:headers]['exception']['detail'])
        assert(metadata.timestamp)
        assert(metadata.message_id)

        step += 1
        EM.stop
      end
 
      # 1) request workers perform made-up command
      @exchange.publish({ cmd: 'fakeo', server_name: 'test' }.to_json,
                        :routing_key => "workers.#{@@hostname}.#{@@workerpool}",
                        :type => "command",
                        :message_id => guid,
                        :timestamp => Time.now.to_i)
    end
    assert_equal(1, step)
  end

  def test_provided_insufficient_arguments
    # test graceful handling of a real command but lacking req'd args
    guid = SecureRandom.uuid
    step = 0

    # 2) worker returns receipt indicating no action performed
    EM.run do
      @ch
      .queue('hq')
      .bind(@exchange, :routing_key => "hq")
      .subscribe do |delivery_info, metadata, payload|
        parsed = JSON.parse payload
        assert_equal('test', parsed['server_name'])
        assert_equal('modify_sp', parsed['cmd'])
        assert_equal(false, parsed['success'])

        assert_equal(guid, metadata.correlation_id)
        assert_equal('receipt', metadata.type)
        assert_equal(@@hostname, metadata[:headers]['hostname'])
        assert_equal(@@workerpool, metadata[:headers]['workerpool'])
        assert_equal('ArgumentError', metadata[:headers]['exception']['name'])
        assert_equal('wrong number of arguments (given 0, expected 2)', metadata[:headers]['exception']['detail'])
        assert(metadata.timestamp)
        assert(metadata.message_id)

        step += 1
        EM.stop
      end
 
      # 1) request workers perform a command
      @exchange.publish({ cmd: 'modify_sp', server_name: 'test' }.to_json,
                        :routing_key => "workers.#{@@hostname}.#{@@workerpool}",
                        :type => "command",
                        :message_id => guid,
                        :timestamp => Time.now.to_i)
    end
    assert_equal(1, step)
  end

  def test_ignore_command
    # misroute a command to a non-existent workerpool
    guid = SecureRandom.uuid
    step = 0

    # 2) no worker returns receipt (also no action performed)
    EM.run do
      @ch
      .queue('hq')
      .bind(@exchange, :routing_key => "hq")
      .subscribe do |delivery_info, metadata, payload|
        step += 1
        assert(false)
        EM.stop
      end
 
      # 1) request worker perform a command but route it incorrectly to fake workerpool
      @exchange.publish({ cmd: 'create', server_name: 'test', server_type: ':conventional_jar' }.to_json,
                        :routing_key => "workers.#{@@hostname}.someawesomeserver",
                        :timestamp => Time.now.to_i,
                        :type => 'command',
                        :message_id => SecureRandom.uuid)

      EM.add_timer(1) {
        assert !Dir.exist?(File.join(@@basedir, 'servers', 'test'))
        assert !Dir.exist?(File.join(@@basedir, 'archive', 'test'))
        assert !Dir.exist?(File.join(@@basedir, 'backup', 'test'))
        EM.stop
      }
    end
    assert_equal(0, step)
  end

  def test_query_objstore_creds
    # request workers to reply if they need object store creds (likely aws)
    guid1 = SecureRandom.uuid
    guid2 = SecureRandom.uuid
    step = 0

    require 'yaml'
    config = YAML::load_file('config/objstore.yml')

    # 2) worker returns it does not have the creds
    EM.run do
      @ch
      .queue('hq')
      .bind(@exchange, :routing_key => "hq")
      .subscribe() do |delivery_info, metadata, payload|
        case step
        when 0
          # ack no creds stored by worker
          parsed = JSON.parse payload
          assert_nil(parsed['AWSCREDS'])
          assert_equal(guid1, metadata.correlation_id)
          assert_equal('receipt', metadata.type)
          assert_equal('VERIFY_OBJSTORE', metadata[:headers]['directive'])
          assert_equal(@@hostname, metadata[:headers]['hostname'])
          assert_equal(@@workerpool, metadata[:headers]['workerpool'])
          assert(metadata.timestamp)
          assert(metadata.message_id)

          # send creds directly to worker
          @exchange.publish({ AWSCREDS: {
                                endpoint: config['object_store']['host'],
                                access_key_id: config['object_store']['access_key'],
                                secret_access_key: config['object_store']['secret_key'],
                                region: 'us-west-1'
                              }
                            }.to_json,
                            :routing_key => "workers.#{@@hostname}.#{@@workerpool}",
                            :type => "directive",
                            :message_id => guid2,
                            :timestamp => Time.now.to_i)
          step += 1
        when 1
          # verify creds tested and connection successful
          # nil = none found, false = invalid, true = working
          parsed = JSON.parse payload
          assert_equal(true, parsed)
          assert_equal(guid2, metadata.correlation_id)
          assert_equal('receipt', metadata.type)
          assert_equal('AWSCREDS', metadata[:headers]['directive'])
          assert_equal(@@hostname, metadata[:headers]['hostname'])
          assert_equal(@@workerpool, metadata[:headers]['workerpool'])
          assert(metadata.timestamp)
          assert(metadata.message_id)
          step += 1
          EM.stop
        end
      end

      guid = SecureRandom.uuid
      # 1) send directive requesting workers to check they have AWSCREDS
      @exchange.publish('VERIFY_OBJSTORE',
                        :routing_key => "workers",
                        :type => "directive",
                        :message_id => guid1,
                        :timestamp => Time.now.to_i)

    end
    assert_equal(2, step)
  end

  def test_get_aws_creds_when_invalid_endpoint
    # request workers to reply if they need object store creds (likely aws)
    guid1 = SecureRandom.uuid
    guid2 = SecureRandom.uuid
    step = 0

    require 'yaml'
    config = YAML::load_file('config/objstore.yml')

    # 2) worker returns it does not have the creds
    EM.run do
      @ch
      .queue('hq')
      .bind(@exchange, :routing_key => "hq")
      .subscribe() do |delivery_info, metadata, payload|
        case step
        when 0
          # ack no creds stored by worker
          parsed = JSON.parse payload
          assert_nil(parsed['AWSCREDS'])
          assert_equal(guid1, metadata.correlation_id)
          assert_equal('receipt', metadata.type)
          assert_equal('VERIFY_OBJSTORE', metadata[:headers]['directive'])
          assert_equal(@@hostname, metadata[:headers]['hostname'])
          assert_equal(@@workerpool, metadata[:headers]['workerpool'])
          assert(metadata.timestamp)
          assert(metadata.message_id)

          # send creds directly to worker
          @exchange.publish({ AWSCREDS: {
                                endpoint: 'fakeendpoint',
                                access_key_id: config['object_store']['access_key'],
                                secret_access_key: config['object_store']['secret_key'],
                                region: 'us-west-1'
                              }
                            }.to_json,
                            :routing_key => "workers.#{@@hostname}.#{@@workerpool}",
                            :type => "directive",
                            :message_id => guid2,
                            :timestamp => Time.now.to_i)
          step += 1
        when 1
          # verify creds tested and connection successful
          # nil = none found, false = invalid, true = working
          parsed = JSON.parse payload
          assert_equal(false, parsed)
          assert_equal(guid2, metadata.correlation_id)
          assert_equal('receipt', metadata.type)
          assert_equal('AWSCREDS', metadata[:headers]['directive'])
          assert_equal(@@hostname, metadata[:headers]['hostname'])
          assert_equal(@@workerpool, metadata[:headers]['workerpool'])
          assert(metadata.timestamp)
          assert(metadata.message_id)
          step += 1
          EM.stop
        end
      end

      guid = SecureRandom.uuid
      # 1) send directive requesting workers to check they have AWSCREDS
      @exchange.publish('VERIFY_OBJSTORE',
                        :routing_key => "workers",
                        :type => "directive",
                        :message_id => guid1,
                        :timestamp => Time.now.to_i)

    end
    assert_equal(2, step)
  end

  def test_worker_bogus_directive
    # worker should gracefully handle bogus directive sent wide
    guid = SecureRandom.uuid
    step = 0

    # 2) worker rewrites directive to bogus in receipt
    EM.run do
      @ch
      .queue('hq')
      .bind(@exchange, :routing_key => "hq")
      .subscribe do |delivery_info, metadata, payload|
        parsed = JSON.parse payload
        assert_equal(guid, metadata.correlation_id)
        assert_equal('receipt', metadata.type)
        assert_equal('BOGUS', metadata[:headers]['directive'])
        assert_equal(@@hostname, metadata[:headers]['hostname'])
        assert_equal(@@workerpool, metadata[:headers]['workerpool'])
        assert(metadata.timestamp)
        assert(metadata.message_id)
        step += 1
        EM.stop
      end

      # 1) request workers perform a command
      @exchange.publish({ THISISFAKE: {} }.to_json,
                        :routing_key => "workers",
                        :type => "directive",
                        :message_id => guid,
                        :timestamp => Time.now.to_i)
    end
    assert_equal(1, step)

  end
end

