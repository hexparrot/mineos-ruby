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
    assert !File.exist?(File.join(@@basedir, 'servers/test/', 'server.config'))
    inst.create_sc
    assert File.exist?(File.join(@@basedir, 'servers/test/', 'server.config'))
  end

  test "modify attr from sc" do
    inst = Server.new(name: 'test')
    inst.create_paths
    inst.create_sc
    assert_equal({}, inst.sc)
    inst.modify_sc('java_xmx', 256, 'java')
    assert_equal(256, inst.sc['java']['java_xmx'])
    inst.modify_sc('start', false, 'onreboot')
    assert_equal(false, inst.sc['onreboot']['start'])
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
    assert !inst.eula
  end

  test "change eula state" do
    require('fileutils')

    inst = Server.new(name: 'test')
    inst.create_paths
    eula_path = File.expand_path("lib/assets/eula.txt", Dir.pwd)
    FileUtils.cp(eula_path, inst.env[:cwd])

    inst.accept_eula
    assert inst.eula
  end

end
