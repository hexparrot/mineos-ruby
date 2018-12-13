require 'minitest/autorun'
require 'eventmachine'
require 'bunny'
require 'json'
require 'securerandom'

class ManagerTest < Minitest::Test

  def setup
    # this test assumes a manager instance is up, as a separate process
    @@hostname = Socket.gethostname
    @@workerpool = 'user'

    require 'yaml'
    mineos_config = YAML::load_file('config/secrets.yml')

    require 'bunny'
    conn = Bunny.new(:host => mineos_config['rabbitmq']['host'],
                     :port => mineos_config['rabbitmq']['port'],
                     :user => mineos_config['rabbitmq']['user'],
                     :pass => mineos_config['rabbitmq']['pass'],
                     :vhost => mineos_config['rabbitmq']['vhost'])
    conn.start

    @ch = conn.create_channel
    @exchange_dir = @ch.topic('directives')
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
      .bind(@exchange_dir, :routing_key => "hq")
      .subscribe do |delivery_info, metadata, payload|
        parsed = JSON.parse payload
        assert_equal(@@hostname, parsed['host'])
        assert_equal(guid, metadata.correlation_id)
        assert_equal('receipt.directive', metadata.type)
        assert_equal('IDENT', metadata[:headers]['directive'])
        assert_equal(@@hostname, metadata[:headers]['hostname'])
        assert(metadata.timestamp)
        assert(metadata.message_id)
        step += 1
        EM.stop
      end

      @exchange_dir.publish('IDENT',
                            :routing_key => "managers",
                            :type => "directive",
                            :message_id => guid,
                            :timestamp => Time.now.to_i)
    end
    assert_equal(1, step)
  end

  def test_spawn_worker
    guid = SecureRandom.uuid
    step = 0

    EM.run do
      @ch
      .queue('')
      .bind(@exchange_dir, :routing_key => "hq")
      .subscribe do |delivery_info, metadata, payload|
        parsed = JSON.parse payload
        case metadata[:headers]['directive']
        when 'SPAWN'
          assert_equal(@@hostname, parsed['host'])
          assert_equal(guid, metadata.correlation_id)
          assert_equal('receipt.directive', metadata.type)
          assert_equal('SPAWN', metadata[:headers]['directive'])
          assert_equal(@@hostname, metadata[:headers]['hostname'])
          assert_equal(@@workerpool, metadata[:headers]['workerpool'])
          assert(metadata.timestamp)
          assert(metadata.message_id)
          step += 1
        when 'IDENT'
          if metadata[:headers]['workerpool'] then
            # coming from spawned process
            assert_equal(@@hostname, parsed['host'])
            assert_equal(@@workerpool, parsed['workerpool'])
            assert_equal('receipt.directive', metadata.type)
            assert_equal('IDENT', metadata[:headers]['directive'])
            assert_equal(@@hostname, metadata[:headers]['hostname'])
            assert_equal(@@workerpool, metadata[:headers]['workerpool'])
            assert(metadata.timestamp)
            assert(metadata.message_id)
            step += 1
          else
            # coming from manager
            assert_equal(@@hostname, parsed['host'])
            assert_equal(@@workerpool, parsed['workerpool'])
            assert(parsed['pid'])
            assert_equal(guid, metadata.correlation_id)
            assert_equal('receipt.directive', metadata.type)
            assert_equal('IDENT', metadata[:headers]['directive'])
            assert_equal(@@hostname, metadata[:headers]['hostname'])
            assert(metadata.timestamp)
            assert(metadata.message_id)
          end
          EM.stop if step >= 2
        end
      end

      @exchange_dir.publish({SPAWN: {workerpool: @@workerpool}}.to_json,
                            :routing_key => "managers.#{@@hostname}",
                            :type => "directive",
                            :message_id => guid,
                            :timestamp => Time.now.to_i)
    end
    assert_equal(2, step)
  end

  def test_spawn_worker_for_new_user
    new_user = '_throwaway-500'
    guid = SecureRandom.uuid
    step = 0

    EM.run do
      @ch
      .queue('')
      .bind(@exchange_dir, :routing_key => "hq")
      .subscribe do |delivery_info, metadata, payload|
        parsed = JSON.parse payload
        case metadata[:headers]['directive']
        when 'SPAWN'
          assert_equal(@@hostname, parsed['host'])
          assert_equal(guid, metadata.correlation_id)
          assert_equal('receipt.directive', metadata.type)
          assert_equal('SPAWN', metadata[:headers]['directive'])
          assert_equal(@@hostname, metadata[:headers]['hostname'])
          assert_equal(new_user, metadata[:headers]['workerpool'])
          assert(metadata.timestamp)
          assert(metadata.message_id)
          step += 1
        when 'IDENT'
          if metadata[:headers]['workerpool'] then
            # coming from spawned process
            assert_equal(@@hostname, parsed['host'])
            assert_equal(new_user, parsed['workerpool'])
            assert_equal('receipt.directive', metadata.type)
            assert_equal('IDENT', metadata[:headers]['directive'])
            assert_equal(@@hostname, metadata[:headers]['hostname'])
            assert_equal(new_user, metadata[:headers]['workerpool'])
            assert(metadata.timestamp)
            assert(metadata.message_id)
            step += 1
          else
            # coming from manager
            assert_equal(@@hostname, parsed['host'])
            assert_equal(new_user, parsed['workerpool'])
            assert(parsed['pid'])
            assert_equal(guid, metadata.correlation_id)
            assert_equal('receipt.directive', metadata.type)
            assert_equal('IDENT', metadata[:headers]['directive'])
            assert_equal(@@hostname, metadata[:headers]['hostname'])
            assert(metadata.timestamp)
            assert(metadata.message_id)
          end
          EM.stop if step >= 2
        end
      end

      @exchange_dir.publish({SPAWN: {workerpool: new_user}}.to_json,
                            :routing_key => "managers.#{@@hostname}",
                            :type => "directive",
                            :message_id => guid,
                            :timestamp => Time.now.to_i)
    end
    assert_equal(2, step)

    new_home = "/home/#{new_user}"
    script_home = File.join(new_home, "mineos-ruby")
    uid = File.stat(new_home).uid
    owner_name = Etc.getpwuid(uid).name

    assert_equal(new_user, owner_name)
    Dir.foreach(script_home) do |item|
      next if item == '.' or item == '..'
      fp = File.join(script_home, item)
      file_uid = File.stat(fp).uid
      assert_equal(new_user, Etc.getpwuid(file_uid).name)
    end
  end
end
