require 'minitest/autorun'

require './mineos'
require 'eventmachine'
require 'bunny'
require 'json'

class ServerTest < Minitest::Test

  def setup
    @@basedir = '/var/games/minecraft'
    @@amq_uri = 'localhost'

    require 'fileutils'
    FileUtils.rm_rf(@@basedir)
    FileUtils.mkdir_p(File.join(@@basedir, 'servers'))
    FileUtils.mkdir_p(File.join(@@basedir, 'backup'))
    FileUtils.mkdir_p(File.join(@@basedir, 'archive'))

    if 1 then
      @pid = fork do
        STDOUT.reopen('/dev/null', 'w')
        STDERR.reopen('/dev/null', 'w')
        exec "ruby server.rb"
      end
    end

    Process.detach(@pid)
    sleep(1)
  end

  def teardown
    begin
      Process.kill(9, @pid) if @pid
    rescue Errno::ESRCH
    else
      sleep(1)
    end
  end

  def test_ping_workers
    require 'socket'
    hostname = Socket.gethostname

    EM.run do
      conn = Bunny.new
      conn.start
  
      ch = conn.create_channel
      exchange = ch.topic("backend")
  
      ch
      .queue("", :exclusive => true)
      .bind(exchange, :routing_key => "to_hq")
      .subscribe do |delivery_info, metadata, payload|
        parsed = JSON.parse(payload, :symbolize_names => true)
        assert_equal(hostname, parsed[:server_name])
        EM.stop
      end

      exchange.publish('IDENT', :routing_key => "workers")
    end
  end

  def test_create_server
    require 'socket'
    hostname = Socket.gethostname

    EM.run do
      inst = Server.new('test')
      assert !Dir.exist?(inst.env[:cwd])
      assert !Dir.exist?(inst.env[:bwd])
      assert !Dir.exist?(inst.env[:awd])
  
      conn = Bunny.new
      conn.start
  
      ch = conn.create_channel
      exchange = ch.topic("backend")
  
      ch
      .queue("", :exclusive => true)
      .bind(exchange, :routing_key => "to_hq")
      .subscribe do |delivery_info, metadata, payload|
        parsed = JSON.parse(payload, :symbolize_names => true)
        assert_equal('test', parsed[:server_name])
        assert_equal('create', parsed[:cmd])
        assert_equal('true', parsed[:success])
        assert Dir.exist?(inst.env[:cwd])
        assert Dir.exist?(inst.env[:bwd])
        assert Dir.exist?(inst.env[:awd])
        EM.stop
      end
 
      exchange.publish(JSON.generate({cmd: 'create', server_name: 'test', server_type: ':conventional_jar'}),
                       :routing_key => "workers.#{hostname}")
    end
  end

end
