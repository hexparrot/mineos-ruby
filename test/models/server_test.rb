require 'test_helper'

class ServerTest < ActiveSupport::TestCase

  def setup
    @@basedir = '/var/games/minecraft'

    require 'fileutils'
    FileUtils.rm_rf(@@basedir)
    FileUtils.mkdir_p(File.join(@@basedir, 'servers'))
    FileUtils.mkdir_p(File.join(@@basedir, 'backup'))
    FileUtils.mkdir_p(File.join(@@basedir, 'archive'))
  end

  test "name setter" do
    inst = Server.new(name: 'test')
    assert(inst.name, 'test')
  end

  test "server name is valid" do
    ['test', 'asdf1234', 'hello_is_it_me', '1.7.10'].each do |name|
      inst = Server.new(name: name)
      assert_equal(name, inst.name)
    end
    ['.test', '#test', '?test', '!test', 'server\'s', 'test^again', 'Vanilla-1.8.9', 'feed me'].each do |name|
      assert_raises(RuntimeError) { inst = Server.new(name: name) }
    end
  end

  test "live directory" do
    inst = Server.new(name: 'test')
    assert_equal(File.join(@@basedir, 'servers/test'), inst.env[:cwd])
    assert_equal(File.join(@@basedir, 'backup/test'), inst.env[:bwd])
    assert_equal(File.join(@@basedir, 'archive/test'), inst.env[:awd])
  end

  test "second live directory" do
    inst = Server.new(name: 'test2')
    assert_equal(File.join(@@basedir, 'servers/test2'), inst.env[:cwd])
    assert_equal(File.join(@@basedir, 'backup/test2'), inst.env[:bwd])
    assert_equal(File.join(@@basedir, 'archive/test2'), inst.env[:awd])
  end

  test "create server paths" do
    inst = Server.new(name: 'test')
    assert !Dir.exist?(inst.env[:cwd])
    assert !Dir.exist?(inst.env[:bwd])
    assert !Dir.exist?(inst.env[:awd])
    inst.create_paths
    assert Dir.exist?(inst.env[:cwd])
    assert Dir.exist?(inst.env[:bwd])
    assert Dir.exist?(inst.env[:awd])
  end

  test "create only missing server paths" do
    inst = Server.new(name: 'test')
    Dir.mkdir inst.env[:cwd]
    Dir.mkdir inst.env[:bwd]
    assert !Dir.exist?(inst.env[:awd])
    inst.create_paths
    assert Dir.exist?(inst.env[:cwd])
    assert Dir.exist?(inst.env[:bwd])
    assert Dir.exist?(inst.env[:awd])
  end

  test "create server.config" do
    inst = Server.new(name: 'test')
    inst.create_paths
    assert !File.exist?(inst.env[:sc])
    inst.sc
    assert !File.exist?(inst.env[:sc])
    inst.sc!
    assert File.exist?(inst.env[:sc])
  end

  test "modify attr from sc" do
    inst = Server.new(name: 'test')
    inst.create_paths
    assert_equal({}, inst.sc)
    inst.modify_sc('java_xmx', 256, 'java')
    assert_equal(256, inst.sc['java']['java_xmx'])
    inst.modify_sc('java_xms', 256, 'java')
    assert_equal(256, inst.sc['java']['java_xms'])
    inst.modify_sc('start', false, 'onreboot')
    assert_equal(256, inst.sc['java']['java_xmx'])
    assert_equal(256, inst.sc['java']['java_xms'])
    assert_equal(false, inst.sc['onreboot']['start'])

    require('inifile')
    sc = IniFile.load(inst.env[:sc])
    assert_equal(256, sc['java']['java_xmx'])
    assert_equal(256, sc['java']['java_xms'])
    assert_equal(false, sc['onreboot']['start'])
  end

  test "modify sc without creating first" do
    inst = Server.new(name: 'test')
    inst.create_paths
    inst.modify_sc('java_xmx', 256, 'java')
    assert_equal(256, inst.sc['java']['java_xmx'])
  end

  test "delete server paths" do
    inst = Server.new(name: 'test')
    inst.create_paths
    inst.delete_paths
    assert !Dir.exist?(inst.env[:cwd])
    assert !Dir.exist?(inst.env[:bwd])
    assert !Dir.exist?(inst.env[:awd])
  end

  test "check eula state" do
    require('fileutils')

    inst = Server.new(name: 'test')
    inst.create_paths
    eula_path = File.expand_path("lib/assets/eula.txt", Dir.pwd)
    FileUtils.cp(eula_path, inst.env[:cwd])
    assert_equal(false, inst.eula)
  end

  test "change eula state" do
    require('fileutils')

    inst = Server.new(name: 'test')
    inst.create_paths
    eula_path = File.expand_path("lib/assets/eula.txt", Dir.pwd)
    FileUtils.cp(eula_path, inst.env[:cwd])

    inst.accept_eula
    assert_equal(true, inst.eula)
  end

  test "create server.properties" do
    inst = Server.new(name: 'test')
    inst.create_paths
    assert !File.exist?(inst.env[:sp])
    inst.sp
    assert !File.exist?(inst.env[:sp])
    inst.sp!
    assert File.exist?(inst.env[:sp])
  end


  test "read server.properties" do
    require('fileutils')

    inst = Server.new(name: 'test')
    inst.create_paths
    sp_path = File.expand_path("lib/assets/server.properties", Dir.pwd)
    FileUtils.cp(sp_path, inst.env[:cwd])

    assert_equal(25565, inst.sp['server-port'])
    assert_equal("", inst.sp['server-ip'])
    assert !inst.sp['enable-rcon']
    assert !inst.sp['enable-query']
  end

  test "modify server.properties" do
    require('fileutils')

    inst = Server.new(name: 'test')
    inst.create_paths
    sp_path = File.expand_path("lib/assets/server.properties", Dir.pwd)
    FileUtils.cp(sp_path, inst.env[:cwd])

    number_attributes = inst.sp.keys.length

    inst.modify_sp('server-port', 25570)
    assert_equal(25570, inst.sp['server-port'])
    inst.modify_sp('enable-rcon', true)
    assert_equal(true, inst.sp['enable-rcon'])
    inst.modify_sp('do-awesomeness', true)
    assert_equal(true, inst.sp['do-awesomeness'])

    assert_equal(number_attributes + 1, inst.sp.keys.length)

    require('inifile')
    sp = IniFile.load(inst.env[:sp])['global']
    assert_equal(25570, sp['server-port'])
    assert_equal(true, sp['enable-rcon'])
    assert_equal(true, sp['do-awesomeness'])
  end

  test "overlay properties onto server.properties" do
    inst = Server.new(name: 'test')
    inst.create_paths

    inst.overlay_sp({ 'server-port' => 25565,
                      'difficulty' => 1,
                      'enable-query' => false })
    assert_equal(25565, inst.sp['server-port'])
    assert_equal(1, inst.sp['difficulty'])
    assert_equal(false, inst.sp['enable-query'])

    require('inifile')
    sp = IniFile.load(inst.env[:sp])['global']
    assert_equal(25565, sp['server-port'])
    assert_equal(1, sp['difficulty'])
    assert_equal(false, sp['enable-query'])
  end

  test "java jar start args-conventional" do
    inst = Server.new(name: 'test')
    inst.create_paths
    #missing jarfile <-- , xmx
    ex = assert_raises(RuntimeError) { inst.get_jar_args(:conventional_jar) }
    assert_equal('no runnable jarfile selected', ex.message)

    #missing xmx
    inst.modify_sc('jarfile', 'mc.jar', 'java')
    ex = assert_raises(RuntimeError) { inst.get_jar_args(:conventional_jar) }
    assert_equal('missing java argument: Xmx', ex.message)

    #string as xmx
    inst.modify_sc('java_xmx', 'hello', 'java')
    ex = assert_raises(RuntimeError) { inst.get_jar_args(:conventional_jar) }
    assert_equal('invalid java argument: Xmx must be an integer > 0', ex.message)

    #string as xms
    inst.modify_sc('java_xmx', 128, 'java')
    inst.modify_sc('java_xms', 'hello', 'java')
    ex = assert_raises(RuntimeError) { inst.get_jar_args(:conventional_jar) }
    assert_equal('invalid java argument: Xms must be unset or an integer > 0', ex.message)

    #invalid xmx
    inst.modify_sc('java_xmx', 0, 'java')
    inst.modify_sc('java_xms', 0, 'java')
    ex = assert_raises(RuntimeError) { inst.get_jar_args(:conventional_jar) }
    assert_equal('invalid java argument: Xmx must be an integer > 0', ex.message)

    inst.modify_sc('java_xmx', 1024, 'java')
    assert_equal(['/usr/bin/java', '-server', '-Xmx1024M', '-Xms1024M', '-jar', 'mc.jar', 'nogui' ],
                 inst.get_jar_args(:conventional_jar))

    inst.modify_sc('java_xms', 768, 'java')
    assert_equal(['/usr/bin/java', '-server', '-Xmx1024M', '-Xms768M', '-jar', 'mc.jar', 'nogui' ],
                 inst.get_jar_args(:conventional_jar))

    inst.modify_sc('java_tweaks', '-Xmn256M', 'java')
    assert_equal(['/usr/bin/java', '-server', '-Xmx1024M', '-Xms768M', '-Xmn256M', '-jar', 'mc.jar', 'nogui' ],
                 inst.get_jar_args(:conventional_jar))

    inst.modify_sc('jar_args', 'dostuff', 'java')
    assert_equal(['/usr/bin/java', '-server', '-Xmx1024M', '-Xms768M', '-Xmn256M', '-jar', 'mc.jar', 'dostuff' ],
                 inst.get_jar_args(:conventional_jar))

    #xmx < xms
    inst.modify_sc('java_xmx', 256, 'java')
    inst.modify_sc('java_xms', 768, 'java')
    ex = assert_raises(RuntimeError) { inst.get_jar_args(:conventional_jar) }
    assert_equal('invalid java argument: Xmx must be > Xms', ex.message)

    #xms == 0
    inst.modify_sc('java_xmx', 1024, 'java')
    inst.modify_sc('java_xms', 0, 'java')
    assert_equal(['/usr/bin/java', '-server', '-Xmx1024M', '-Xms1024M', '-Xmn256M', '-jar', 'mc.jar', 'dostuff' ],
                 inst.get_jar_args(:conventional_jar))

  end

  test "java jar start args-unconventional" do
    inst = Server.new(name: 'test')
    inst.create_paths

    #missing jarfile
    ex = assert_raises(RuntimeError) { inst.get_jar_args(:unconventional_jar) }
    assert_equal('no runnable jarfile selected', ex.message)

    #invalid xmx
    inst.modify_sc('jarfile', 'mc.jar', 'java')
    inst.modify_sc('java_xmx', -1024, 'java')
    ex = assert_raises(RuntimeError) { inst.get_jar_args(:unconventional_jar) }
    assert_equal('invalid java argument: Xmx must be unset or > 0', ex.message)

    #invalid xms
    inst.modify_sc('java_xmx', 1024, 'java')
    inst.modify_sc('java_xms', -1024, 'java')
    ex = assert_raises(RuntimeError) { inst.get_jar_args(:unconventional_jar) }
    assert_equal('invalid java argument: Xms must be unset or > 0', ex.message)

    inst.modify_sc('java_xmx', 0, 'java')
    inst.modify_sc('java_xms', 0, 'java')
    inst.modify_sc('java_tweaks', '-Xmn256M', 'java')
    assert_equal(['/usr/bin/java', '-server', '-Xmn256M', '-jar', 'mc.jar' ],
                 inst.get_jar_args(:unconventional_jar))

    inst.modify_sc('java_xmx', 256, 'java')
    assert_equal(['/usr/bin/java', '-server', '-Xmx256M', '-Xmn256M', '-jar', 'mc.jar' ],
                 inst.get_jar_args(:unconventional_jar))

    inst.modify_sc('jar_args', 'dostuff', 'java')
    assert_equal(['/usr/bin/java', '-server', '-Xmx256M', '-Xmn256M', '-jar', 'mc.jar', 'dostuff' ],
                 inst.get_jar_args(:unconventional_jar))

    #string as xmx
    inst.modify_sc('java_xmx', 'hello', 'java')
    ex = assert_raises(RuntimeError) { inst.get_jar_args(:unconventional_jar) }
    assert_equal('invalid java argument: Xmx must be unset or an integer > 0', ex.message)

    #string as xms
    inst.modify_sc('java_xmx', 0, 'java')
    inst.modify_sc('java_xms', 'hello', 'java')
    ex = assert_raises(RuntimeError) { inst.get_jar_args(:unconventional_jar) }
    assert_equal('invalid java argument: Xms must be unset or an integer > 0', ex.message)

    #set xms, unset xmx
    inst.modify_sc('java_xmx', 0, 'java')
    inst.modify_sc('java_xms', 256, 'java')
    ex = assert_raises(RuntimeError) { inst.get_jar_args(:unconventional_jar) }
    assert_equal('invalid java argument: Xms may not be set without Xmx', ex.message)

    #xms > xmx
    inst.modify_sc('java_xmx', 128, 'java')
    inst.modify_sc('java_xms', 256, 'java')
    ex = assert_raises(RuntimeError) { inst.get_jar_args(:unconventional_jar) }
    assert_equal('invalid java argument: Xmx may not be lower than Xms', ex.message)
  end

  test "php phar start args" do
    inst = Server.new(name: 'test') 
    inst.create_paths

    #missing pharfile
    ex = assert_raises(RuntimeError) { inst.get_jar_args(:phar) }
    assert_equal('no runnable pharfile selected', ex.message)

    #fallback for backward compat with previous webuis
    inst.modify_sc('jarfile', 'pocket.phar', 'java')
    assert_equal(['/usr/bin/php', 'pocket.phar'], inst.get_jar_args(:phar))

    #existence of [nonjava][executable] will override
    inst.modify_sc('executable', 'pocketmine.phar', 'nonjava')
    assert_equal(['/usr/bin/php', 'pocketmine.phar'], inst.get_jar_args(:phar))

    #empty executable should fallback
    inst.modify_sc('executable', '', 'nonjava')
    assert_equal(['/usr/bin/php', 'pocket.phar'], inst.get_jar_args(:phar))

    #empty jarfile should error out
    inst.modify_sc('jarfile', '', 'java')
    ex = assert_raises(RuntimeError) { inst.get_jar_args(:phar) }
    assert_equal('no runnable pharfile selected', ex.message)
  end

  test "unrecognized get_start_args request" do
    inst = Server.new(name: 'test') 
    ex = assert_raises(NotImplementedError) { inst.get_jar_args(:bogus) }
    assert_equal('unrecognized get_jar_args argument: bogus', ex.message)
    ex = assert_raises(NotImplementedError) { inst.get_jar_args(:more_bogus) }
    assert_equal('unrecognized get_jar_args argument: more_bogus', ex.message)
  end

  test "server start" do
    inst = Server.new(name: 'test')
    inst.create_paths

    jar_path = File.expand_path("lib/assets/minecraft_server.1.8.9.jar", Dir.pwd)
    FileUtils.cp(jar_path, inst.env[:cwd])

    inst.modify_sc('jarfile', 'minecraft_server.1.8.9.jar', 'java')
    inst.modify_sc('java_xmx', 384, 'java')
    inst.modify_sc('java_xms', 256, 'java')
    pid = inst.start
    
    assert(pid.is_a?(Integer))
    assert(inst.pid.is_a?(Integer))
    assert(inst.stdin.is_a?(IO))
    assert(inst.stdout.is_a?(IO))
    assert(inst.stderr.is_a?(IO))
    assert_equal(1, Process.kill(0, inst.pid))

    begin
      #Process.kill returns 1 if running
      while Process.kill(0, inst.pid) do
        sleep(0.5)
      end
    rescue Errno::ESRCH
      assert_equal(false, inst.eula)
    end  
  end
end
