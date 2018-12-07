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
    mineos_config = YAML::load_file('../config/secrets.yml')

    require 'bunny'
    conn = Bunny.new(:host => mineos_config['rabbitmq']['host'],
                     :port => mineos_config['rabbitmq']['port'],
                     :user => mineos_config['rabbitmq']['user'],
                     :pass => mineos_config['rabbitmq']['pass'],
                     :vhost => mineos_config['rabbitmq']['vhost'])
    conn.start

    @ch = conn.create_channel
    @exchange_cmd = @ch.direct('commands')
    @exchange_dir = @ch.topic('directives')

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
    guid = SecureRandom.uuid
    step = 0

    EM.run do
      @ch
      .queue('')
      .bind(@exchange_dir, :routing_key => "to_hq")
      .subscribe do |delivery_info, metadata, payload|
        parsed = JSON.parse payload
        assert_equal(@@hostname, parsed['host'])
        assert_equal(@@workerpool, parsed['workerpool'])
        assert_equal(guid, metadata.correlation_id)
        assert_equal('receipt.directive', metadata.type)
        assert_equal('IDENT', metadata[:headers]['directive'])
        assert_equal(@@hostname, metadata[:headers]['hostname'])
        assert_equal(@@workerpool, metadata[:headers]['workerpool'])
        assert(metadata.timestamp)
        assert(metadata.message_id)
        step += 1
        EM.stop
      end

      @exchange_dir.publish('IDENT',
                            :routing_key => "to_workers",
                            :type => "directive",
                            :message_id => guid,
                            :timestamp => Time.now.to_i)
    end
    assert_equal(1, step)
  end

  def test_serverlist
    guid = SecureRandom.uuid
    step = 0

    EM.run do
      @ch
      .queue('')
      .bind(@exchange_cmd, :routing_key => "to_hq")
      .subscribe do |delivery_info, metadata, payload|
        @exchange_dir.publish('LIST',
                              :routing_key => "to_workers",
                              :type => "directive",
                              :message_id => guid,
                              :timestamp => Time.now.to_i)
        step += 1
      end

      @ch
      .queue('')
      .bind(@exchange_dir, :routing_key => "to_hq")
      .subscribe do |delivery_info, metadata, payload|
        parsed = JSON.parse payload
        servers = parsed['servers']
        assert_equal('test', servers.first)
        assert_equal(1, servers.length)
        assert_equal(guid, metadata.correlation_id)
        assert_equal('receipt.directive', metadata.type)
        assert_equal('LIST', metadata[:headers]['directive'])
        assert_equal(@@hostname, metadata[:headers]['hostname'])
        assert_equal(@@workerpool, metadata[:headers]['workerpool'])
        assert(metadata.timestamp)
        assert(metadata.message_id)
        EM.stop
        step += 1
      end

      @exchange_cmd.publish({ cmd: 'create',
                              server_name: 'test'}.to_json,
                            :routing_key => "to_workers.#{@@hostname}.#{@@workerpool}",
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
      @ch
      .queue('')
      .bind(@exchange_cmd, :routing_key => "to_hq")
      .subscribe do |delivery_info, metadata, payload|
        parsed = JSON.parse payload
        assert_equal('test', parsed['server_name'])
        assert_equal('create', parsed['cmd'])
        assert_equal(true, parsed['success'])

        assert_equal(guid, metadata.correlation_id)
        assert_equal('receipt.command', metadata.type)
        assert_equal(@@hostname, metadata[:headers]['hostname'])
        assert_equal(@@workerpool, metadata[:headers]['workerpool'])
        assert_equal(false, metadata[:headers]['exception'])
        assert(metadata.timestamp)
        assert(metadata.message_id)

        step += 1
        EM.stop
      end
 
      @exchange_cmd.publish({ cmd: 'create',
                              server_name: 'test',
                              server_type: ':conventional_jar' }.to_json,
                            :routing_key => "to_workers.#{@@hostname}.#{@@workerpool}",
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
      @ch
      .queue('')
      .bind(@exchange_cmd, :routing_key => "to_hq")
      .subscribe do |delivery_info, metadata, payload|
        parsed = JSON.parse payload
        assert_equal('test', parsed['server_name'])
        assert_equal('create', parsed['cmd'])
        assert_equal(true, parsed['success'])

        assert_equal(guid, metadata.correlation_id)
        assert_equal('receipt.command', metadata.type)
        assert_equal(@@hostname, metadata[:headers]['hostname'])
        assert_equal(@@workerpool, metadata[:headers]['workerpool'])
        assert_equal(false, metadata[:headers]['exception'])
        assert(metadata.timestamp)
        assert(metadata.message_id)

        step += 1
        EM.stop
      end

      @exchange_cmd.publish({ cmd: 'create',
                              server_name: 'test' }.to_json,
                            :routing_key => "to_workers.#{@@hostname}.#{@@workerpool}",
                            :type => "command",
                            :message_id => guid,
                            :timestamp => Time.now.to_i)
    end
    assert_equal(1, step)
  end


  def test_get_start_args
    step = 0
    EM.run do
      @ch
      .queue('')
      .bind(@exchange_cmd, :routing_key => "to_hq")
      .subscribe do |delivery_info, metadata, payload|
        parsed = JSON.parse payload
        case step
        when 0
          @exchange_cmd.publish({ cmd: 'modify_sc', server_name: 'test', attr: 'jarfile',
                                  value: 'minecraft_server.1.8.9.jar', section: 'java' }.to_json,
                                :routing_key => "to_workers.#{@@hostname}.#{@@workerpool}",
                                :timestamp => Time.now.to_i,
                                :type => 'command',
                                :message_id => SecureRandom.uuid)
        when 1
          @exchange_cmd.publish({ cmd: 'modify_sc', server_name: 'test', attr: 'java_xmx',
                                  value: 384, section: 'java' }.to_json,
                                :routing_key => "to_workers.#{@@hostname}.#{@@workerpool}",
                                :timestamp => Time.now.to_i,
                                :type => 'command',
                                :message_id => SecureRandom.uuid)
        when 2
          @exchange_cmd.publish({ cmd: 'modify_sc', server_name: 'test', attr: 'java_xms',
                                  value: 384, section: 'java' }.to_json,
                                :routing_key => "to_workers.#{@@hostname}.#{@@workerpool}",
                                :timestamp => Time.now.to_i,
                                :type => 'command',
                                :message_id => SecureRandom.uuid)
        when 3
          @exchange_cmd.publish({ cmd: 'get_start_args', server_name: 'test', type: ':conventional_jar' }.to_json,
                                :routing_key => "to_workers.#{@@hostname}.#{@@workerpool}",
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

          assert_equal('receipt.command', metadata.type)
          assert_equal(false, metadata[:headers]['exception'])
          assert(metadata.timestamp)
          assert(metadata.message_id)
          assert(metadata.correlation_id)

          EM.stop
        end
        step += 1
      end
 
      @exchange_cmd.publish({ cmd: 'create', server_name: 'test', server_type: ':conventional_jar' }.to_json,
                            :routing_key => "to_workers.#{@@hostname}.#{@@workerpool}",
                            :timestamp => Time.now.to_i,
                            :type => 'command',
                            :message_id => SecureRandom.uuid)
    end
    assert_equal(5, step)
  end

  def test_usage
    guid = SecureRandom.uuid
    step = 0

    EM.run do
      @ch
      .queue('')
      .bind(@exchange_dir, :routing_key => "to_hq")
      .subscribe do |delivery_info, metadata, payload|
        parsed = JSON.parse payload
        assert(parsed['usage'].key?('uw_cpuused'))
        assert(parsed['usage'].key?('uw_memused'))
        assert(parsed['usage'].key?('uw_load'))
        assert(parsed['usage'].key?('uw_diskused'))
        assert(parsed['usage'].key?('uw_diskused_perc'))

        assert_equal(guid, metadata.correlation_id)
        assert_equal('receipt.directive', metadata.type)
        assert_equal('USAGE', metadata[:headers]['directive'])
        assert_equal(@@hostname, metadata[:headers]['hostname'])
        assert_equal(@@workerpool, metadata[:headers]['workerpool'])
        assert(metadata.timestamp)
        assert(metadata.message_id)

        step += 1
        EM.stop
      end

      @exchange_dir.publish('USAGE',
                            :routing_key => "to_workers",
                            :type => "directive",
                            :message_id => guid,
                            :timestamp => Time.now.to_i)
    end
    assert_equal(1, step)
  end

  def test_request_usage
    guid = SecureRandom.uuid
    step = 0

    EM.run do
      @ch
      .queue('')
      .bind(@exchange_dir, :routing_key => "to_hq")
      .subscribe do |delivery_info, metadata, payload|
        parsed = JSON.parse payload
        assert(parsed['usage'].key?('uw_cpuused'))

        assert_equal(guid, metadata.correlation_id)
        assert_equal('receipt.directive', metadata.type)
        assert_equal('REQUEST_USAGE', metadata[:headers]['directive'])
        assert_equal(@@hostname, metadata[:headers]['hostname'])
        assert_equal(@@workerpool, metadata[:headers]['workerpool'])
        assert(metadata.timestamp)
        assert(metadata.message_id)

        step += 1
        EM.stop
      end

      @exchange_dir.publish('uw_cpuused',
                            :routing_key => "to_workers",
                            :type => 'directive',
                            :message_id => guid,
                            :timestamp => Time.now.to_i)
    end
    assert_equal(1, step)
  end

  def test_bogus_command
    guid = SecureRandom.uuid
    step = 0

    EM.run do
      @ch
      .queue('')
      .bind(@exchange_cmd, :routing_key => "to_hq")
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
 
      @exchange_cmd.publish({ cmd: 'fakeo', server_name: 'test' }.to_json,
                            :routing_key => "to_workers.#{@@hostname}.#{@@workerpool}",
                            :type => "command",
                            :message_id => guid,
                            :timestamp => Time.now.to_i)
    end
    assert_equal(1, step)
  end

  def test_provided_insufficient_arguments
    guid = SecureRandom.uuid
    step = 0

    EM.run do
      @ch
      .queue('')
      .bind(@exchange_cmd, :routing_key => "to_hq")
      .subscribe do |delivery_info, metadata, payload|
        parsed = JSON.parse payload
        assert_equal('test', parsed['server_name'])
        assert_equal('modify_sp', parsed['cmd'])
        assert_equal(false, parsed['success'])

        assert_equal(guid, metadata.correlation_id)
        assert_equal('receipt.command', metadata.type)
        assert_equal(@@hostname, metadata[:headers]['hostname'])
        assert_equal(@@workerpool, metadata[:headers]['workerpool'])
        assert_equal('ArgumentError', metadata[:headers]['exception']['name'])
        assert_equal('wrong number of arguments (given 0, expected 2)', metadata[:headers]['exception']['detail'])
        assert(metadata.timestamp)
        assert(metadata.message_id)

        step += 1
        EM.stop
      end
 
      @exchange_cmd.publish({ cmd: 'modify_sp', server_name: 'test' }.to_json,
                            :routing_key => "to_workers.#{@@hostname}.#{@@workerpool}",
                            :type => "command",
                            :message_id => guid,
                            :timestamp => Time.now.to_i)
    end
    assert_equal(1, step)
  end

  def test_ignore_command
    guid = SecureRandom.uuid
    step = 0

    EM.run do
      @ch
      .queue('')
      .bind(@exchange_cmd, :routing_key => "to_hq")
      .subscribe do |delivery_info, metadata, payload|
        step += 1
        assert(false)
        EM.stop
      end
 
      @exchange_cmd.publish({ cmd: 'create', server_name: 'test', server_type: ':conventional_jar' }.to_json,
                            :routing_key => "to_workers.#{@@hostname}.someawesomeserver",
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

  def test_get_aws_creds
    guid = SecureRandom.uuid
    step = 0

    require 'yaml'
    config = YAML::load_file('../config/objstore.yml')

    EM.run do
      @ch
      .queue('')
      .bind(@exchange_dir, :routing_key => "to_hq")
      .subscribe() do |delivery_info, metadata, payload|
        parsed = JSON.parse payload
        assert_equal(guid, metadata.correlation_id)
        assert_equal('receipt.directive', metadata.type)
        assert_equal('AWSCREDS', metadata[:headers]['directive'])
        assert_equal(@@hostname, metadata[:headers]['hostname'])
        assert_equal(@@workerpool, metadata[:headers]['workerpool'])
        assert_equal(config['object_store']['host'], parsed['endpoint'])
        assert_equal(config['object_store']['access_key'], parsed['access_key_id'])
        assert_equal(config['object_store']['secret_key'], parsed['secret_access_key'])
        assert_equal(true, parsed['force_path_style'])
        assert_equal('us-west-1', parsed['region'])
        assert(metadata.timestamp)
        assert(metadata.message_id)
        step += 1
        EM.stop
      end

      @exchange_dir.publish({ AWSCREDS: {
                               endpoint: config['object_store']['host'],
                               access_key_id: config['object_store']['access_key'],
                               secret_access_key: config['object_store']['secret_key'],
                               region: 'us-west-1'
                              }
                            }.to_json,
                            :routing_key => "to_workers",
                            :type => "directive",
                            :message_id => guid,
                            :timestamp => Time.now.to_i)
    end
    assert_equal(1, step)
  end

  def test_get_aws_creds_when_invalid_endpoint
    guid = SecureRandom.uuid
    step = 0

    require 'yaml'
    config = YAML::load_file('../config/objstore.yml')

    EM.run do
      @ch
      .queue('')
      .bind(@exchange_dir, :routing_key => "to_hq")
      .subscribe do |delivery_info, metadata, payload|
        parsed = JSON.parse payload
        assert_equal(guid, metadata.correlation_id)
        assert_equal('receipt.directive', metadata.type)
        assert_equal('AWSCREDS', metadata[:headers]['directive'])
        assert_equal(@@hostname, metadata[:headers]['hostname'])
        assert_equal(@@workerpool, metadata[:headers]['workerpool'])
        assert_nil(parsed['endpoint'])
        assert_nil(parsed['access_key_id'])
        assert_nil(parsed['secret_access_key'])
        assert_equal(true, parsed['force_path_style'])
        assert_nil(parsed['region'])
        assert(metadata.timestamp)
        assert(metadata.message_id)
        step += 1
        EM.stop
      end

      @exchange_dir.publish({ AWSCREDS: {
                                endpoint: 'fakeendpoint',
                                access_key_id: config['object_store']['access_key'],
                                secret_access_key: config['object_store']['secret_key'],
                                region: 'us-west-1'
                              }
                            }.to_json,
                            :routing_key => "to_workers",
                            :type => "directive",
                            :message_id => guid,
                            :timestamp => Time.now.to_i)
    end
    assert_equal(1, step)
  end

  def test_worker_bogus_directive
    guid = SecureRandom.uuid
    step = 0

    EM.run do
      @ch
      .queue('')
      .bind(@exchange_dir, :routing_key => "to_hq")
      .subscribe do |delivery_info, metadata, payload|
        parsed = JSON.parse payload
        assert_equal(guid, metadata.correlation_id)
        assert_equal('receipt.directive', metadata.type)
        assert_equal('BOGUS', metadata[:headers]['directive'])
        assert_equal(@@hostname, metadata[:headers]['hostname'])
        assert_equal(@@workerpool, metadata[:headers]['workerpool'])
        assert(metadata.timestamp)
        assert(metadata.message_id)
        step += 1
        EM.stop
      end

      @exchange_dir.publish({ THISISFAKE: {} }.to_json,
                            :routing_key => "to_workers",
                            :type => "directive",
                            :message_id => guid,
                            :timestamp => Time.now.to_i)
    end
    assert_equal(1, step)

  end
end

