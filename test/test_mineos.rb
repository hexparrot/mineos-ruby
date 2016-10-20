require 'minitest/autorun'
require 'mineos'

class ServerTest < Minitest::Test

  def setup
    @@basedir = '/var/games/minecraft'
    @@server_jar = 'minecraft_server.1.8.9.jar'
    @@assets_path = 'assets'
    @@server_jar_path = File.join(@@assets_path, @@server_jar)

    require 'fileutils'
    FileUtils.rm_rf(@@basedir)
    FileUtils.mkdir_p(File.join(@@basedir, 'servers'))
    FileUtils.mkdir_p(File.join(@@basedir, 'backup'))
    FileUtils.mkdir_p(File.join(@@basedir, 'archive'))
  end

  def test_name
    inst = Server.new('test')
    assert(inst.name, 'test')
  end

  def test_server_name_is_valid
    ['test', 'asdf1234', 'hello_is_it_me', '1.7.10'].each do |name|
      inst = Server.new(name)
      assert_equal(name, inst.name)
    end
    ['.test', '#test', '?test', '!test', 'server\'s', 'test^again', 'Vanilla-1.8.9', 'feed me'].each do |name|
      assert_raises(RuntimeError) { inst = Server.new(name) }
    end
  end

  def test_live_directory
    inst = Server.new('test')
    assert_equal(File.join(@@basedir, 'servers/test'), inst.env[:cwd])
    assert_equal(File.join(@@basedir, 'backup/test'), inst.env[:bwd])
    assert_equal(File.join(@@basedir, 'archive/test'), inst.env[:awd])

    inst2 = Server.new('test2')
    assert_equal(File.join(@@basedir, 'servers/test2'), inst2.env[:cwd])
    assert_equal(File.join(@@basedir, 'backup/test2'), inst2.env[:bwd])
    assert_equal(File.join(@@basedir, 'archive/test2'), inst2.env[:awd])
  end

  def test_create_server_paths
    inst = Server.new('test')
    assert !Dir.exist?(inst.env[:cwd])
    assert !Dir.exist?(inst.env[:bwd])
    assert !Dir.exist?(inst.env[:awd])
    inst.create_paths
    assert Dir.exist?(inst.env[:cwd])
    assert Dir.exist?(inst.env[:bwd])
    assert Dir.exist?(inst.env[:awd])
  end

  def test_create_only_missing_server_paths
    inst = Server.new('test')
    Dir.mkdir inst.env[:cwd]
    Dir.mkdir inst.env[:bwd]
    assert !Dir.exist?(inst.env[:awd])
    inst.create_paths
    assert Dir.exist?(inst.env[:cwd])
    assert Dir.exist?(inst.env[:bwd])
    assert Dir.exist?(inst.env[:awd])
  end

  def test_delete_server
    inst = Server.new('test')
    inst.create(:conventional_jar)
    inst.delete
    assert !Dir.exist?(inst.env[:cwd])
    assert !Dir.exist?(inst.env[:bwd])
    assert !Dir.exist?(inst.env[:awd])

    inst = Server.new('test2')
    inst.create(:conventional_jar)

    inst.modify_sc('jarfile', @@server_jar, 'java')
    inst.modify_sc('java_xmx', 384, 'java')
    inst.modify_sc('java_xms', 256, 'java')
    pid = inst.start

    assert(pid)

    ex = assert_raises(RuntimeError) { inst.delete }
    assert_equal('cannot delete a server that is running', ex.message)

    assert Dir.exist?(inst.env[:cwd])
    assert Dir.exist?(inst.env[:bwd])
    assert Dir.exist?(inst.env[:awd])

    nil until !inst.pid

    inst.delete
    assert !Dir.exist?(inst.env[:cwd])
    assert !Dir.exist?(inst.env[:bwd])
    assert !Dir.exist?(inst.env[:awd])
  end

  def test_create_server_config
    inst = Server.new('test')
    inst.create_paths
    assert !File.exist?(inst.env[:sc])
    inst.sc
    assert !File.exist?(inst.env[:sc])
    inst.sc!
    assert File.exist?(inst.env[:sc])
  end

  def test_modify_attr_from_sc
    inst = Server.new('test')
    inst.create_paths
    assert_empty(inst.sc)
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

  def test_modify_sc_without_creating_first
    inst = Server.new('test')
    inst.create_paths
    inst.modify_sc('java_xmx', 256, 'java')
    assert_equal(256, inst.sc['java']['java_xmx'])
  end

  def test_delete_server_paths
    inst = Server.new('test')
    inst.create_paths
    inst.delete_paths
    assert !Dir.exist?(inst.env[:cwd])
    assert !Dir.exist?(inst.env[:bwd])
    assert !Dir.exist?(inst.env[:awd])
  end

  def test_check_eula_state
    require('fileutils')

    inst = Server.new('test')
    inst.create_paths
    eula_path = File.expand_path(File.join(@@assets_path, "eula.txt"), Dir.pwd)
    FileUtils.cp(eula_path, inst.env[:cwd])
    assert_equal(false, inst.eula)
  end

  def test_change_eula_state
    require('fileutils')

    inst = Server.new('test')
    inst.create_paths
    eula_path = File.expand_path(File.join(@@assets_path, "eula.txt"), Dir.pwd)
    FileUtils.cp(eula_path, inst.env[:cwd])

    inst.accept_eula
    assert_equal(true, inst.eula)
  end

  def test_create_server_properties
    inst = Server.new('test')
    inst.create_paths
    assert !File.exist?(inst.env[:sp])
    inst.sp
    assert !File.exist?(inst.env[:sp])
    inst.sp!
    assert File.exist?(inst.env[:sp])
  end


  def test_read_server_properties
    require('fileutils')

    inst = Server.new('test')
    inst.create_paths
    sp_path = File.expand_path(File.join(@@assets_path, "server.properties"), Dir.pwd)
    FileUtils.cp(sp_path, inst.env[:cwd])

    assert_equal(25565, inst.sp['server-port'])
    assert_empty(inst.sp['server-ip'])
    assert !inst.sp['enable-rcon']
    assert !inst.sp['enable-query']
  end

  def test_modify_server_properties
    require('fileutils')

    inst = Server.new('test')
    inst.create_paths
    sp_path = File.expand_path(File.join(@@assets_path, "server.properties"), Dir.pwd)
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

  def test_overlay_properties_onto_server_properties
    inst = Server.new('test')
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

  def test_java_jar_start_args_conventional
    inst = Server.new('test')
    inst.create_paths
    #missing jarfile <-- , xmx
    ex = assert_raises(RuntimeError) { inst.get_start_args(:conventional_jar) }
    assert_equal('no runnable jarfile selected', ex.message)

    #missing xmx
    inst.modify_sc('jarfile', 'mc.jar', 'java')
    ex = assert_raises(RuntimeError) { inst.get_start_args(:conventional_jar) }
    assert_equal('missing java argument: Xmx', ex.message)

    #string as xmx
    inst.modify_sc('java_xmx', 'hello', 'java')
    ex = assert_raises(RuntimeError) { inst.get_start_args(:conventional_jar) }
    assert_equal('invalid java argument: Xmx must be an integer > 0', ex.message)

    #string as xms
    inst.modify_sc('java_xmx', 128, 'java')
    inst.modify_sc('java_xms', 'hello', 'java')
    ex = assert_raises(RuntimeError) { inst.get_start_args(:conventional_jar) }
    assert_equal('invalid java argument: Xms must be unset or an integer > 0', ex.message)

    #invalid xmx
    inst.modify_sc('java_xmx', 0, 'java')
    inst.modify_sc('java_xms', 0, 'java')
    ex = assert_raises(RuntimeError) { inst.get_start_args(:conventional_jar) }
    assert_equal('invalid java argument: Xmx must be an integer > 0', ex.message)

    inst.modify_sc('java_xmx', 1024, 'java')
    assert_equal(['/usr/bin/java', '-server', '-Xmx1024M', '-Xms1024M', '-jar', 'mc.jar', 'nogui' ],
                 inst.get_start_args(:conventional_jar))

    inst.modify_sc('java_xms', 768, 'java')
    assert_equal(['/usr/bin/java', '-server', '-Xmx1024M', '-Xms768M', '-jar', 'mc.jar', 'nogui' ],
                 inst.get_start_args(:conventional_jar))

    inst.modify_sc('java_tweaks', '-Xmn256M', 'java')
    assert_equal(['/usr/bin/java', '-server', '-Xmx1024M', '-Xms768M', '-Xmn256M', '-jar', 'mc.jar', 'nogui' ],
                 inst.get_start_args(:conventional_jar))

    inst.modify_sc('jar_args', 'dostuff', 'java')
    assert_equal(['/usr/bin/java', '-server', '-Xmx1024M', '-Xms768M', '-Xmn256M', '-jar', 'mc.jar', 'dostuff' ],
                 inst.get_start_args(:conventional_jar))

    #xmx < xms
    inst.modify_sc('java_xmx', 256, 'java')
    inst.modify_sc('java_xms', 768, 'java')
    ex = assert_raises(RuntimeError) { inst.get_start_args(:conventional_jar) }
    assert_equal('invalid java argument: Xmx must be > Xms', ex.message)

    #xms == 0
    inst.modify_sc('java_xmx', 1024, 'java')
    inst.modify_sc('java_xms', 0, 'java')
    assert_equal(['/usr/bin/java', '-server', '-Xmx1024M', '-Xms1024M', '-Xmn256M', '-jar', 'mc.jar', 'dostuff' ],
                 inst.get_start_args(:conventional_jar))
  end

  def test_java_jar_start_args_unconventional
    inst = Server.new('test')
    inst.create_paths

    #missing jarfile
    ex = assert_raises(RuntimeError) { inst.get_start_args(:unconventional_jar) }
    assert_equal('no runnable jarfile selected', ex.message)

    #invalid xmx
    inst.modify_sc('jarfile', 'mc.jar', 'java')
    inst.modify_sc('java_xmx', -1024, 'java')
    ex = assert_raises(RuntimeError) { inst.get_start_args(:unconventional_jar) }
    assert_equal('invalid java argument: Xmx must be unset or > 0', ex.message)

    #invalid xms
    inst.modify_sc('java_xmx', 1024, 'java')
    inst.modify_sc('java_xms', -1024, 'java')
    ex = assert_raises(RuntimeError) { inst.get_start_args(:unconventional_jar) }
    assert_equal('invalid java argument: Xms must be unset or > 0', ex.message)

    inst.modify_sc('java_xmx', 0, 'java')
    inst.modify_sc('java_xms', 0, 'java')
    inst.modify_sc('java_tweaks', '-Xmn256M', 'java')
    assert_equal(['/usr/bin/java', '-server', '-Xmn256M', '-jar', 'mc.jar' ],
                 inst.get_start_args(:unconventional_jar))

    inst.modify_sc('java_xmx', 256, 'java')
    assert_equal(['/usr/bin/java', '-server', '-Xmx256M', '-Xmn256M', '-jar', 'mc.jar' ],
                 inst.get_start_args(:unconventional_jar))

    inst.modify_sc('jar_args', 'dostuff', 'java')
    assert_equal(['/usr/bin/java', '-server', '-Xmx256M', '-Xmn256M', '-jar', 'mc.jar', 'dostuff' ],
                 inst.get_start_args(:unconventional_jar))

    #string as xmx
    inst.modify_sc('java_xmx', 'hello', 'java')
    ex = assert_raises(RuntimeError) { inst.get_start_args(:unconventional_jar) }
    assert_equal('invalid java argument: Xmx must be unset or an integer > 0', ex.message)

    #string as xms
    inst.modify_sc('java_xmx', 0, 'java')
    inst.modify_sc('java_xms', 'hello', 'java')
    ex = assert_raises(RuntimeError) { inst.get_start_args(:unconventional_jar) }
    assert_equal('invalid java argument: Xms must be unset or an integer > 0', ex.message)

    #set xms, unset xmx
    inst.modify_sc('java_xmx', 0, 'java')
    inst.modify_sc('java_xms', 256, 'java')
    ex = assert_raises(RuntimeError) { inst.get_start_args(:unconventional_jar) }
    assert_equal('invalid java argument: Xms may not be set without Xmx', ex.message)

    #xms > xmx
    inst.modify_sc('java_xmx', 128, 'java')
    inst.modify_sc('java_xms', 256, 'java')
    ex = assert_raises(RuntimeError) { inst.get_start_args(:unconventional_jar) }
    assert_equal('invalid java argument: Xmx may not be lower than Xms', ex.message)
  end

  def test_php_phar_start_args
    inst = Server.new('test') 
    inst.create_paths

    #missing pharfile
    ex = assert_raises(RuntimeError) { inst.get_start_args(:phar) }
    assert_equal('no runnable pharfile selected', ex.message)

    #fallback for backward compat with previous webuis
    inst.modify_sc('jarfile', 'pocket.phar', 'java')
    assert_equal(['/usr/bin/php', 'pocket.phar'], inst.get_start_args(:phar))

    #existence of [nonjava][executable] will override
    inst.modify_sc('executable', 'pocketmine.phar', 'nonjava')
    assert_equal(['/usr/bin/php', 'pocketmine.phar'], inst.get_start_args(:phar))

    #empty executable should fallback
    inst.modify_sc('executable', '', 'nonjava')
    assert_equal(['/usr/bin/php', 'pocket.phar'], inst.get_start_args(:phar))

    #empty jarfile should error out
    inst.modify_sc('jarfile', '', 'java')
    ex = assert_raises(RuntimeError) { inst.get_start_args(:phar) }
    assert_equal('no runnable pharfile selected', ex.message)
  end

  def test_unrecognized_get_start_args_request
    inst = Server.new('test') 
    ex = assert_raises(NotImplementedError) { inst.get_start_args(:bogus) }
    assert_equal('unrecognized get_start_args argument: bogus', ex.message)
    ex = assert_raises(NotImplementedError) { inst.get_start_args(:more_bogus) }
    assert_equal('unrecognized get_start_args argument: more_bogus', ex.message)
  end

  def test_server_start
    inst = Server.new('test')
    inst.create_paths

    jar_path = File.expand_path(@@server_jar_path, Dir.pwd)
    FileUtils.cp(jar_path, inst.env[:cwd])

    inst.modify_sc('jarfile', @@server_jar, 'java')
    inst.modify_sc('java_xmx', 384, 'java')
    inst.modify_sc('java_xms', 256, 'java')
    pid = inst.start
    
    assert_equal(1, Process.kill(0, pid))
    nil until !inst.pid
    assert_equal(false, inst.eula)
  end

  def test_start_server_when_already_running
    inst = Server.new('test')
    inst.create_paths

    jar_path = File.expand_path(@@server_jar_path, Dir.pwd)
    FileUtils.cp(jar_path, inst.env[:cwd])

    inst.modify_sc('jarfile', @@server_jar, 'java')
    inst.modify_sc('java_xmx', 384, 'java')
    inst.modify_sc('java_xms', 256, 'java')
    pid = inst.start

    assert(pid)

    ex = assert_raises(RuntimeError) { inst.start }
    assert_equal('server is already running', ex.message)

    nil until !inst.pid
  end

  def test_send_test_to_server_console
    inst = Server.new('test')
    inst.create_paths

    jar_path = File.expand_path(@@server_jar_path, Dir.pwd)
    FileUtils.cp(jar_path, inst.env[:cwd])

    inst.modify_sc('jarfile', @@server_jar, 'java')
    inst.modify_sc('java_xmx', 384, 'java')
    inst.modify_sc('java_xms', 256, 'java')
    inst.accept_eula
    pid = inst.start

    nil until inst.status[:done]
    inst.console('stop')
    nil until !inst.pid
  end

  def test_send_text_to_downed_server
    inst = Server.new('test')
    ex = assert_raises(IOError) { inst.console('hello') }
    assert_equal('I/O channel is down', ex.message)
  end

  def test_memory_checks
    inst = Server.new('test')
    inst.create_paths

    jar_path = File.expand_path(@@server_jar_path, Dir.pwd)
    FileUtils.cp(jar_path, inst.env[:cwd])

    assert_equal(0.0, inst.mem[:kb])
    assert_equal(0.0, inst.mem[:mb])
    assert_equal(0.0, inst.mem[:gb])

    inst.modify_sc('jarfile', @@server_jar, 'java')
    inst.modify_sc('java_xmx', 384, 'java')
    inst.modify_sc('java_xms', 256, 'java')
    pid = inst.start

    assert_instance_of(Float, inst.mem[:kb])
    assert_instance_of(Float, inst.mem[:mb])
    assert_instance_of(Float, inst.mem[:gb])

    nil until !inst.pid
  end

  def test_pid
    inst = Server.new('test')
    inst.create_paths

    jar_path = File.expand_path(@@server_jar_path, Dir.pwd)
    FileUtils.cp(jar_path, inst.env[:cwd])

    assert(inst.pid.nil?)

    inst.modify_sc('jarfile', @@server_jar, 'java')
    inst.modify_sc('java_xmx', 384, 'java')
    inst.modify_sc('java_xms', 256, 'java')
    pid = inst.start

    assert_equal(pid, inst.pid)
    assert_instance_of(Fixnum, pid)
    assert_instance_of(Fixnum, inst.pid)

    nil until !inst.pid
  end

  def test_create_server_via_convenience_method
    inst = Server.new('test')
    inst.create

    assert_equal(:conventional_jar, inst.server_type)
    assert Dir.exist?(inst.env[:cwd])
    assert Dir.exist?(inst.env[:bwd])
    assert Dir.exist?(inst.env[:awd])
    assert File.exist?(inst.env[:sp])
    assert File.exist?(inst.env[:sc])

    inst = Server.new('test')
    inst.create(:conventional_jar)

    assert_equal(:conventional_jar, inst.server_type)
    assert Dir.exist?(inst.env[:cwd])
    assert Dir.exist?(inst.env[:bwd])
    assert Dir.exist?(inst.env[:awd])
    assert File.exist?(inst.env[:sp])
    assert File.exist?(inst.env[:sc])

    inst = Server.new('test2')
    inst.create(:unconventional_jar)
    assert_equal(:unconventional_jar, inst.server_type)
    assert Dir.exist?(inst.env[:cwd])
    assert Dir.exist?(inst.env[:bwd])
    assert Dir.exist?(inst.env[:awd])
    assert !File.exist?(inst.env[:sp])
    assert File.exist?(inst.env[:sc])
    
    inst = Server.new('test3')
    inst.create(:phar)
    assert_equal(:phar, inst.server_type)
    assert Dir.exist?(inst.env[:cwd])
    assert Dir.exist?(inst.env[:bwd])
    assert Dir.exist?(inst.env[:awd])
    assert !File.exist?(inst.env[:sp])
    assert File.exist?(inst.env[:sc])

    inst = Server.new('test4')
    ex = assert_raises(RuntimeError) { inst.create(:bogus) }
    assert_equal('unrecognized server type: bogus', ex.message)
    
    inst = Server.new('test5')
    ex = assert_raises(RuntimeError) { inst.create(:bogus_again) }
    assert_equal('unrecognized server type: bogus_again', ex.message)
  end

  def test_archive
    inst = Server.new('test')
    inst.create(:conventional_jar)

    inst.modify_sc('jarfile', @@server_jar, 'java')
    inst.modify_sc('java_xmx', 384, 'java')
    inst.modify_sc('java_xms', 256, 'java')

    fn = inst.archive
    fp = File.join(inst.env[:awd], fn)
    assert(File.exist?(fp))
    assert(fn.start_with?("test_"))
    assert(fn.end_with?(".tgz"))

    require('zlib')
    require('archive/tar/minitar')

    found_files = []

    tgz = Zlib::GzipReader.new(File.open(fp, 'rb'))
    reader = Archive::Tar::Minitar::Reader.new(tgz)
    reader.each_entry do |file|
      found_files << file.full_name
    end
    reader.close
    tgz.close

    assert_equal(found_files.length, 3)
    assert_equal(found_files - ['./', './server.config', './server.properties'], [])
  end

  def test_create_from_archive
    inst = Server.new('test')
    inst.create(:conventional_jar)
    inst.modify_sc('jarfile', @@server_jar, 'java')
    inst.modify_sc('java_xmx', 384, 'java')
    inst.archive
    inst.modify_sc('java_xmx', 512, 'java')

    created = ""
    Dir.foreach(inst.env[:awd]) { |file| created = file if !file.start_with?('.') }
    second_inst = Server.new('test_copy')
    fp = File.join(inst.env[:awd], created)
    second_inst.create_from_archive(fp)

    assert_empty(Dir.entries(inst.env[:cwd]) - Dir.entries(second_inst.env[:cwd]))
    assert_equal(@@server_jar, second_inst.sc['java']['jarfile'])
    assert_equal(384, second_inst.sc['java']['java_xmx'])

    #should fail because existing server.config created and present
    ex = assert_raises(RuntimeError) { second_inst.create_from_archive(fp) }
    assert_equal('cannot extract archive over existing server', ex.message)

    third_inst = Server.new('zing')
    third_inst.create(:conventional_jar)
    ex = assert_raises(RuntimeError) { third_inst.create_from_archive(fp) }
    assert_equal('cannot extract archive over existing server', ex.message)
  end

  def test_backup
    inst = Server.new('test')
    inst.create(:conventional_jar)

    jar_path = File.expand_path(@@server_jar_path, Dir.pwd)
    FileUtils.cp(jar_path, inst.env[:cwd])

    inst.modify_sc('jarfile', @@server_jar, 'java')
    inst.backup

    assert_equal(['rdiff-backup-data'], Dir.entries(inst.env[:bwd]) - Dir.entries(inst.env[:cwd]))
  end

  def test_restore
    inst = Server.new('test')
    inst.create(:conventional_jar)

    jar_path = File.expand_path(@@server_jar_path, Dir.pwd)
    FileUtils.cp(jar_path, inst.env[:cwd])

    inst.modify_sc('java_xmx', 384, 'java')
    inst.modify_sc('jarfile', @@server_jar, 'java')
    inst.backup

    inst.modify_sc('java_xmx', 1024, 'java')
    sleep(1.2)
    inst.backup
    assert_equal(1024, inst.sc['java']['java_xmx'])

    inst.restore('1B')
    #current implementation makes outside changes to sc not recognized until re-loaded.
    #re-instantiation isn't good, and should be removed in the future
    inst = Server.new('test')
    assert_equal(384, inst.sc['java']['java_xmx'])

    inst.restore('5B')
    inst = Server.new('test')
    assert_equal(384, inst.sc['java']['java_xmx'])

    inst.restore('0B')
    inst = Server.new('test')
    assert_equal(1024, inst.sc['java']['java_xmx'])
  end

  def test_restore_while_server_running
    inst = Server.new('test')
    inst.create(:conventional_jar)

    jar_path = File.expand_path(@@server_jar_path, Dir.pwd)
    FileUtils.cp(jar_path, inst.env[:cwd])

    inst.modify_sc('java_xmx', 384, 'java')
    inst.modify_sc('java_xms', 384, 'java')
    inst.modify_sc('jarfile', @@server_jar, 'java')
    inst.backup

    pid = inst.start
    ex = assert_raises(RuntimeError) { inst.restore('1B') }
    assert_equal('cannot restore server while it is running', ex.message)

    nil until !inst.pid
  end

  def test_parse_stdout
    inst = Server.new('test')
    inst.create_paths

    jar_path = File.expand_path(@@server_jar_path, Dir.pwd)
    FileUtils.cp(jar_path, inst.env[:cwd])

    inst.modify_sc('jarfile', @@server_jar, 'java')
    inst.modify_sc('java_xmx', 384, 'java')
    inst.modify_sc('java_xms', 256, 'java')
    inst.accept_eula
    pid = inst.start

    nil until inst.status[:done]
    inst.console('stop')
    nil until !inst.pid

    assert(inst.status[:version].include?('1.8.9'))
    assert(inst.status[:type].include?('SURVIVAL'))
    assert(inst.status[:port].include?('*:25565'))
    assert(inst.status[:level].include?('"world"'))
    assert(inst.status[:done].match(/\[Server thread\/INFO\]: Done/))
    assert(inst.status[:stopping].include?('Stopping server'))
  end

  def test_stop
    inst = Server.new('test')
    inst.create_paths

    jar_path = File.expand_path(@@server_jar_path, Dir.pwd)
    FileUtils.cp(jar_path, inst.env[:cwd])

    inst.modify_sc('jarfile', @@server_jar, 'java')
    inst.modify_sc('java_xmx', 384, 'java')
    inst.modify_sc('java_xms', 256, 'java')
    inst.accept_eula

    ex = assert_raises(RuntimeError) { inst.stop }
    assert_equal('cannot stop server while it is stopped', ex.message)

    pid = inst.start

    nil until inst.status[:done]
    inst.stop
    assert(!inst.pid)
  end

  def test_catch_eula_failure
    inst = Server.new('test')
    inst.create_paths

    jar_path = File.expand_path(@@server_jar_path, Dir.pwd)
    FileUtils.cp(jar_path, inst.env[:cwd])

    inst.modify_sc('jarfile', @@server_jar, 'java')
    inst.modify_sc('java_xmx', 384, 'java')
    inst.modify_sc('java_xms', 256, 'java')

    ex = assert_raises(RuntimeError) { inst.start_catch_errors }
    assert_equal('you need to agree to the eula in order to run the server', ex.message)

    nil until !inst.pid
    assert(inst.status[:eula].include?('Failed to load eula.txt'))
  end

  def test_catch_bind_issue
    inst = Server.new('test')
    inst.create_paths

    jar_path = File.expand_path(@@server_jar_path, Dir.pwd)
    FileUtils.cp(jar_path, inst.env[:cwd])

    inst.modify_sc('jarfile', @@server_jar, 'java')
    inst.modify_sc('java_xmx', 256, 'java')
    inst.modify_sc('java_xms', 256, 'java')
    inst.accept_eula
    begin
      inst.start_catch_errors(25)
    rescue RuntimeError => ex
      assert_equal('A fatal error has been detected by the Java Runtime Environment', ex.message)
      inst.kill
      nil until !inst.pid
    end

    nil until inst.status[:done]

    second_inst = Server.new('test')
    second_inst.create_paths

    jar_path = File.expand_path(@@server_jar_path, Dir.pwd)
    FileUtils.cp(jar_path, second_inst.env[:cwd])

    second_inst.modify_sc('jarfile', @@server_jar, 'java')
    second_inst.modify_sc('java_xmx', 256, 'java')
    second_inst.modify_sc('java_xms', 256, 'java')
    second_inst.accept_eula

    ex = assert_raises(RuntimeError) { second_inst.start_catch_errors(25) }
    assert_equal('server port is already in use', ex.message)

    nil until !second_inst.pid
    assert(second_inst.status[:bind].include?('FAILED TO BIND TO PORT!'))

    inst.kill
    nil until !inst.pid
  end

  def test_catch_normal_execution
    inst = Server.new('test')
    inst.create_paths

    jar_path = File.expand_path(@@server_jar_path, Dir.pwd)
    FileUtils.cp(jar_path, inst.env[:cwd])

    inst.modify_sc('jarfile', @@server_jar, 'java')
    inst.modify_sc('java_xmx', 256, 'java')
    inst.modify_sc('java_xms', 256, 'java')
    inst.accept_eula

    last_state = inst.start_catch_errors(20)
    assert_equal(:done, last_state)
    inst.stop

    second_inst = Server.new('test_two')
    second_inst.create_paths

    jar_path = File.expand_path(@@server_jar_path, Dir.pwd)
    FileUtils.cp(jar_path, second_inst.env[:cwd])

    second_inst.modify_sc('jarfile', @@server_jar, 'java')
    second_inst.modify_sc('java_xmx', 256, 'java')
    second_inst.modify_sc('java_xms', 256, 'java')
    second_inst.accept_eula
    last_state = second_inst.start_catch_errors(8)
    assert_equal(:level, last_state)
    second_inst.kill
    nil until !inst.pid
    nil until !second_inst.pid
  end

  def test_catch_bogus_timeout
    inst = Server.new('test')
    inst.create_paths

    jar_path = File.expand_path(@@server_jar_path, Dir.pwd)
    FileUtils.cp(jar_path, inst.env[:cwd])

    inst.modify_sc('jarfile', @@server_jar, 'java')
    inst.modify_sc('java_xmx', 256, 'java')
    inst.modify_sc('java_xms', 256, 'java')
    inst.accept_eula

    ex = assert_raises(RuntimeError) { inst.start_catch_errors('x') }
    assert_equal('timeout must be a positive integer > 0', ex.message)
    ex = assert_raises(RuntimeError) { inst.start_catch_errors(:hello) }
    assert_equal('timeout must be a positive integer > 0', ex.message)
    ex = assert_raises(RuntimeError) { inst.start_catch_errors([]) }
    assert_equal('timeout must be a positive integer > 0', ex.message)
    ex = assert_raises(RuntimeError) { inst.start_catch_errors(1.0) }
    assert_equal('timeout must be a positive integer > 0', ex.message)
    ex = assert_raises(RuntimeError) { inst.start_catch_errors({}) }
    assert_equal('timeout must be a positive integer > 0', ex.message)
  end

  def test_kill
    inst = Server.new('test')
    inst.create_paths

    jar_path = File.expand_path(@@server_jar_path, Dir.pwd)
    FileUtils.cp(jar_path, inst.env[:cwd])

    inst.modify_sc('jarfile', @@server_jar, 'java')
    inst.modify_sc('java_xmx', 256, 'java')
    inst.modify_sc('java_xms', 256, 'java')
    inst.accept_eula

    ex = assert_raises(RuntimeError) { inst.kill }
    assert_equal('cannot kill server while it is stopped', ex.message)

    inst.start
    nil until inst.status[:done]
    inst.kill #sigterm
    assert(inst.pid.nil?)

    inst.start
    nil until inst.status[:done]
    inst.kill(:sigterm)
    assert(inst.pid.nil?)

    inst.start
    nil until inst.status[:done]
    inst.kill(:sigkill)
    assert(inst.pid.nil?)

    inst.start
    nil until inst.status[:done]
    inst.kill(:sigint)
    assert(inst.pid.nil?)
  end

  def test_sleep_until
    inst = Server.new('test')
    inst.create_paths

    jar_path = File.expand_path(@@server_jar_path, Dir.pwd)
    FileUtils.cp(jar_path, inst.env[:cwd])

    inst.modify_sc('jarfile', @@server_jar, 'java')
    inst.modify_sc('java_xmx', 256, 'java')
    inst.modify_sc('java_xms', 256, 'java')
    inst.accept_eula

    inst.start
    assert(!inst.status[:done])
    inst.sleep_until(:done)

    Process.kill(9, inst.pid)
    inst.sleep_until(:down)
    assert(!inst.pid)
    inst.sleep_until(:down)

    ex = assert_raises(RuntimeError) { inst.sleep_until(:down, 'x') }
    assert_equal('timeout must be a positive integer > 0', ex.message)
    ex = assert_raises(RuntimeError) { inst.sleep_until(:down, :hello) }
    assert_equal('timeout must be a positive integer > 0', ex.message)
    ex = assert_raises(RuntimeError) { inst.sleep_until(:down, []) }
    assert_equal('timeout must be a positive integer > 0', ex.message)
    ex = assert_raises(RuntimeError) { inst.sleep_until(:down, 1.0) }
    assert_equal('timeout must be a positive integer > 0', ex.message)
    ex = assert_raises(RuntimeError) { inst.sleep_until(:down, {}) }
    assert_equal('timeout must be a positive integer > 0', ex.message)

    second_inst = Server.new('test_two')
    second_inst.create_paths

    jar_path = File.expand_path(@@server_jar_path, Dir.pwd)
    FileUtils.cp(jar_path, second_inst.env[:cwd])

    second_inst.modify_sc('jarfile', @@server_jar, 'java')
    second_inst.modify_sc('java_xmx', 256, 'java')
    second_inst.modify_sc('java_xms', 256, 'java')

    second_inst.start #these should fail because of eula
    assert(!second_inst.status.key?(:done))

    ex = assert_raises(RuntimeError) { second_inst.sleep_until(:done, 2) }
    assert_equal('condition not satisfied in allowed time', ex.message)

    nil until !inst.pid
    nil until !second_inst.pid
  end
end
