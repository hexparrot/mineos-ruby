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

  test "live directory" do
    inst = Server.new(name: 'test')
    assert_equal(File.join(@@basedir, 'servers/test'), inst.env[:cwd])
  end

  test "backup directory" do
    inst = Server.new(name: 'test')
    assert_equal(File.join(@@basedir, 'backup/test'), inst.env[:bwd])
  end

  test "archive directory" do
    inst = Server.new(name: 'test')
    assert_equal(File.join(@@basedir, 'archive/test'), inst.env[:awd])
  end

  test "second live directory" do
    inst = Server.new(name: 'test2')
    assert_equal(File.join(@@basedir, 'servers/test2'), inst.env[:cwd])
  end

  test "second backup directory" do
    inst = Server.new(name: 'test2')
    assert_equal(File.join(@@basedir, 'backup/test2'), inst.env[:bwd])
  end

  test "second archive directory" do
    inst = Server.new(name: 'test2')
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

end
