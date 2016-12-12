require 'minitest/autorun'

require 'eventmachine'
require 'bunny'
require 'json'
require 'securerandom'
require 'socket'

class ServerTest < Minitest::Test

  def setup
    @@basedir = '/var/games/minecraft'
    @@hostname = Socket.gethostname
    @@amqp = 'amqp://localhost'

    conn = Bunny.new(@@amqp)
    conn.start

    @ch = conn.create_channel
    @exchange = @ch.topic('backend')

    require 'fileutils'
    FileUtils.rm_rf(@@basedir)
    FileUtils.mkdir_p(File.join(@@basedir, 'servers'))
    FileUtils.mkdir_p(File.join(@@basedir, 'backup'))
    FileUtils.mkdir_p(File.join(@@basedir, 'archive'))

    if 1 then
      @pid = fork do
        STDOUT.reopen('/dev/null', 'w')
        STDERR.reopen('/dev/null', 'w')
        exec "ruby worker.rb"
      end
    end

    Process.detach(@pid)
  end

  def teardown
    Process.kill 9, @pid 
    sleep(0.1)
  end

  def test_ident
    guid = SecureRandom.uuid
    step = 0

    EM.run do
      @ch
      .queue('')
      .bind(@exchange, :routing_key => "to_hq")
      .subscribe(:exclusive => true) do |delivery_info, metadata, payload|
        parsed = JSON.parse(payload, :symbolize_names => true)
        assert_equal(@@hostname, parsed[:host])
        assert_equal(guid, metadata.correlation_id)
        assert_equal('receipt.directive', metadata.type)
        assert_equal('IDENT', metadata[:headers]['directive'])
        assert_equal(@@hostname, metadata[:headers]['hostname'])
        assert(metadata.timestamp)
        assert(metadata.message_id)
        step += 1
        EM.stop
      end

      @exchange.publish('IDENT',
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
      .queue('', :exclusive => true)
      .bind(@exchange, :routing_key => "to_hq")
      .subscribe do |delivery_info, metadata, payload|
        case step
        when 0
          @exchange.publish('LIST',
                            :routing_key => "to_workers",
                            :type => "directive",
                            :message_id => guid,
                            :timestamp => Time.now.to_i)
        when 1
          parsed = JSON.parse(payload, :symbolize_names => true)
          servers = parsed[:servers]
          assert_equal('test', servers.first)
          assert_equal(1, servers.length)
          assert_equal(guid, metadata.correlation_id)
          assert_equal('receipt.directive', metadata.type)
          assert_equal('LIST', metadata[:headers]['directive'])
          assert_equal(@@hostname, metadata[:headers]['hostname'])
          assert(metadata.timestamp)
          assert(metadata.message_id)
          EM.stop
        end
        step += 1
      end

      @exchange.publish({cmd: 'create',
                         server_name: 'test'}.to_json,
                        :routing_key => "to_workers.#{@@hostname}",
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
      .queue('', :exclusive => true)
      .bind(@exchange, :routing_key => "to_hq")
      .subscribe do |delivery_info, metadata, payload|
        parsed = JSON.parse(payload, :symbolize_names => true)
        assert_equal('test', parsed[:server_name])
        assert_equal('create', parsed[:cmd])
        assert_equal(true, parsed[:success])

        assert_equal(guid, metadata.correlation_id)
        assert_equal('receipt.command', metadata.type)
        assert_equal(@@hostname, metadata[:headers]['hostname'])
        assert(metadata.timestamp)
        assert(metadata.message_id)

        step += 1
        EM.stop
      end
 
      @exchange.publish({cmd: 'create',
                         server_name: 'test',
                         server_type: ':conventional_jar'}.to_json,
                        :routing_key => "to_workers.#{@@hostname}",
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
      .queue('', :exclusive => true)
      .bind(@exchange, :routing_key => "to_hq")
      .subscribe do |delivery_info, metadata, payload|
        parsed = JSON.parse(payload, :symbolize_names => true)
        assert_equal('test', parsed[:server_name])
        assert_equal('create', parsed[:cmd])
        assert_equal(true, parsed[:success])

        assert_equal(guid, metadata.correlation_id)
        assert_equal('receipt.command', metadata.type)
        assert_equal(@@hostname, metadata[:headers]['hostname'])
        assert(metadata.timestamp)
        assert(metadata.message_id)

        step += 1
        EM.stop
      end

      @exchange.publish({cmd: 'create',
                         server_name: 'test'}.to_json,
                        :routing_key => "to_workers.#{@@hostname}",
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
      .queue('', :exclusive => true)
      .bind(@exchange, :routing_key => "to_hq")
      .subscribe do |delivery_info, metadata, payload|
        parsed = JSON.parse(payload, :symbolize_names => true)
        case step
        when 0
          @exchange.publish({cmd: 'modify_sc', server_name: 'test', attr: 'jarfile',
                             value: 'minecraft_server.1.8.9.jar', section: 'java'}.to_json,
                            :routing_key => "to_workers.#{@@hostname}",
                            :timestamp => Time.now.to_i,
                            :type => 'command',
                            :message_id => SecureRandom.uuid)
        when 1
          @exchange.publish({cmd: 'modify_sc', server_name: 'test', attr: 'java_xmx',
                             value: 384, section: 'java'}.to_json,
                            :routing_key => "to_workers.#{@@hostname}",
                            :timestamp => Time.now.to_i,
                            :type => 'command',
                            :message_id => SecureRandom.uuid)
        when 2
          @exchange.publish({cmd: 'modify_sc', server_name: 'test', attr: 'java_xms',
                             value: 384, section: 'java'}.to_json,
                            :routing_key => "to_workers.#{@@hostname}",
                            :timestamp => Time.now.to_i,
                            :type => 'command',
                            :message_id => SecureRandom.uuid)
        when 3
          @exchange.publish({cmd: 'get_start_args', server_name: 'test', type: ':conventional_jar'}.to_json,
                            :routing_key => "to_workers.#{@@hostname}",
                            :timestamp => Time.now.to_i,
                            :type => 'command',
                            :message_id => SecureRandom.uuid)
        when 4
          retval = parsed[:retval]
          assert_equal("/usr/bin/java", retval[0])
          assert_equal("-server", retval[1])
          assert_equal("-Xmx384M", retval[2])
          assert_equal("-Xms384M", retval[3])
          assert_equal("-jar", retval[4])
          assert_equal("minecraft_server.1.8.9.jar", retval[5])
          assert_equal("nogui", retval[6])

          assert_equal('receipt.command', metadata.type)
          assert(metadata.timestamp)
          assert(metadata.message_id)
          assert(metadata.correlation_id)

          EM.stop
        end
        step += 1
      end
 
      @exchange.publish({cmd: 'create', server_name: 'test', server_type: ':conventional_jar'}.to_json,
                        :routing_key => "to_workers.#{@@hostname}",
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
      .queue('', :exclusive => true)
      .bind(@exchange, :routing_key => "to_hq")
      .subscribe do |delivery_info, metadata, payload|
        parsed = JSON.parse(payload, :symbolize_names => true)
        assert(parsed[:usage].key?(:uw_cpuused))
        assert(parsed[:usage].key?(:uw_memused))
        assert(parsed[:usage].key?(:uw_load))
        assert(parsed[:usage].key?(:uw_diskused))
        assert(parsed[:usage].key?(:uw_diskused_perc))

        assert_equal(guid, metadata.correlation_id)
        assert_equal('receipt.directive', metadata.type)
        assert_equal('USAGE', metadata[:headers]['directive'])
        assert_equal(@@hostname, metadata[:headers]['hostname'])
        assert(metadata.timestamp)
        assert(metadata.message_id)

        step += 1
        EM.stop
      end

      @exchange.publish('USAGE',
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
      .queue('', :exclusive => true)
      .bind(@exchange, :routing_key => "to_hq")
      .subscribe do |delivery_info, metadata, payload|
        parsed = JSON.parse(payload, :symbolize_names => true)
        assert(parsed[:usage].key?(:uw_cpuused))

        assert_equal(guid, metadata.correlation_id)
        assert_equal('receipt.directive', metadata.type)
        assert_equal('REQUEST_USAGE', metadata[:headers]['directive'])
        assert_equal(@@hostname, metadata[:headers]['hostname'])
        assert(metadata.timestamp)
        assert(metadata.message_id)

        step += 1
        EM.stop
      end

      @exchange.publish('uw_cpuused',
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
      .queue('', :exclusive => true)
      .bind(@exchange, :routing_key => "to_hq")
      .subscribe do |delivery_info, metadata, payload|
        parsed = JSON.parse(payload, :symbolize_names => true)
        assert_equal('test', parsed[:server_name])
        assert_equal('fakeo', parsed[:cmd])
        assert_equal(false, parsed[:success])

        assert_equal(guid, metadata.correlation_id)
        assert_equal('receipt.command', metadata.type)
        assert_equal(@@hostname, metadata[:headers]['hostname'])
        assert(metadata.timestamp)
        assert(metadata.message_id)

        step += 1
        EM.stop
      end
 
      @exchange.publish({cmd: 'fakeo', server_name: 'test'}.to_json,
                        :routing_key => "to_workers.#{@@hostname}",
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
      .queue('', :exclusive => true)
      .bind(@exchange, :routing_key => "to_hq")
      .subscribe do |delivery_info, metadata, payload|
        step += 1
        assert(false)
        EM.stop
      end
 
      @exchange.publish({cmd: 'create', server_name: 'test', server_type: ':conventional_jar'}.to_json,
                        :routing_key => "to_workers.someawesomeserver",
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
end

