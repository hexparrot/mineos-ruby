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
      .bind(exchange, :routing_key => "to_hq.ident.*")
      .subscribe do |delivery_info, metadata, payload|
        parsed = JSON.parse(payload, :symbolize_names => true)
        assert_equal(hostname, parsed[:server_name])
        EM.stop
      end

      exchange.publish('IDENT', :routing_key => "to_workers.directives")
    end
  end

  def test_create_server
    require 'socket'
    hostname = Socket.gethostname

    step = 0
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
      .bind(exchange, :routing_key => "to_hq.receipt.*")
      .subscribe do |delivery_info, metadata, payload|
        parsed = JSON.parse(payload, :symbolize_names => true)
        assert_equal('test', parsed[:server_name])
        assert_equal('create', parsed[:cmd])
        assert_equal('true', parsed[:success])
        assert Dir.exist?(inst.env[:cwd])
        assert Dir.exist?(inst.env[:bwd])
        assert Dir.exist?(inst.env[:awd])
        step += 1
        EM.stop
      end
 
      exchange.publish(JSON.generate({cmd: 'create', server_name: 'test', server_type: ':conventional_jar'}),
                       :routing_key => "to_workers.commands.#{hostname}")
    end
    assert_equal(1, step)
  end

  def test_get_start_args
    require 'socket'
    hostname = Socket.gethostname

    step = 0
    EM.run do
      inst = Server.new('test')
  
      conn = Bunny.new
      conn.start
  
      ch = conn.create_channel
      exchange = ch.topic("backend")
  
      ch
      .queue("", :exclusive => true)
      .bind(exchange, :routing_key => "to_hq.receipt.*")
      .subscribe do |delivery_info, metadata, payload|
        parsed = JSON.parse(payload, :symbolize_names => true)
        case step
        when 0
          exchange.publish(JSON.generate({cmd: 'modify_sc', server_name: 'test', attr: 'jarfile',
                                          value: 'minecraft_server.1.8.9.jar', section: 'java'}),
                           :routing_key => "to_workers.commands.#{hostname}")
        when 1
          exchange.publish(JSON.generate({cmd: 'modify_sc', server_name: 'test', attr: 'java_xmx',
                                          value: 384, section: 'java'}),
                           :routing_key => "to_workers.commands.#{hostname}")
        when 2
          exchange.publish(JSON.generate({cmd: 'modify_sc', server_name: 'test', attr: 'java_xms',
                                          value: 384, section: 'java'}),
                           :routing_key => "to_workers.commands.#{hostname}")
        when 3
          exchange.publish(JSON.generate({cmd: 'get_start_args', server_name: 'test', type: ':conventional_jar'}),
                           :routing_key => "to_workers.commands.#{hostname}")
        when 4
          retval = parsed[:retval]
          assert_equal("/usr/bin/java", retval[0])
          assert_equal("-server", retval[1])
          assert_equal("-Xmx384M", retval[2])
          assert_equal("-Xms384M", retval[3])
          assert_equal("-jar", retval[4])
          assert_equal("minecraft_server.1.8.9.jar", retval[5])
          assert_equal("nogui", retval[6])
          EM.stop
        end
        step += 1

      end
 
      exchange.publish(JSON.generate({cmd: 'create', server_name: 'test', server_type: ':conventional_jar'}),
                       :routing_key => "to_workers.commands.#{hostname}")
    end
    assert_equal(5, step)
  end

end
