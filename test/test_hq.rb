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
    # IDENT from worker process startup
    # expects back follow-up of VERIFY_OBJSTORE
    guid = SecureRandom.uuid
    step = 0

    EM.run do
      @ch
      .queue("workers.#{@@hostname}.#{@@workerpool}")
      .bind(@exchange, :routing_key => "workers.#.#")
      .subscribe do |delivery_info, metadata, payload|
        assert_equal(guid, metadata.correlation_id)
        assert_equal('receipt.directive', metadata.type)
        assert_equal('ACK', payload)
        assert_equal('IDENT', metadata[:headers]['directive'])
        assert(metadata.timestamp)
        assert(metadata.message_id)
        step += 1
        EM.stop
      end

      @exchange.publish({ hostname: @@hostname,
                          workerpool: @@workerpool }.to_json,
                        :routing_key => "hq",
                        :timestamp => Time.now.to_i,
                        :type => 'init',
                        :correlation_id => nil,
                        :headers => { hostname: @@hostname,
                                      workerpool: @@workerpool,
                                      directive: 'IDENT' },
                        :message_id => guid)
    end
    assert_equal(1, step)
  end

  def test_verify_objstore
    # upon receipt of IDENT, send verify_objstore creds
    guid = SecureRandom.uuid
    guid2 = SecureRandom.uuid
    step = 0

    EM.run do
      @ch
      .queue("workers.#{@@hostname}.#{@@workerpool}")
      .bind(@exchange, :routing_key => "workers.#.#")
      .subscribe do |delivery_info, metadata, payload|
        if payload == 'ACK' then
          step += 1
        elsif payload == 'VERIFY_OBJSTORE' then
          assert_equal('directive', metadata.type)
          assert_equal('VERIFY_OBJSTORE', payload)
          assert(metadata.timestamp)
          assert(metadata.message_id)
          step += 1

          @exchange.publish('',
                            :routing_key => "hq",
                            :timestamp => Time.now.to_i,
                            :type => 'receipt.directive',
                            :correlation_id => metadata[:message_id],
                            :headers => { hostname: @@hostname,
                                          workerpool: @@workerpool,
                                          directive: 'VERIFY_OBJSTORE' },
                            :message_id => guid2)
        else
          assert_equal('directive', metadata.type)
          assert_equal(guid2, metadata.correlation_id)
          assert(payload['AWSCREDS'])
          assert(metadata.timestamp)
          assert(metadata.message_id)
          step += 1
        end
        EM.stop if step == 3
      end

      @exchange.publish({ hostname: @@hostname,
                          workerpool: @@workerpool }.to_json,
                        :routing_key => "hq",
                        :timestamp => Time.now.to_i,
                        :type => 'init',
                        :correlation_id => nil,
                        :headers => { hostname: @@hostname,
                                      workerpool: @@workerpool,
                                      directive: 'IDENT' },
                        :message_id => guid)
    end
    assert_equal(3, step)
  end
end
