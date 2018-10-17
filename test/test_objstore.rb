require 'minitest/autorun'
require './mineos_objstore'

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

  def teardown
  end

  def test_credentials
    inst = Server_os.new('test')
    ex = assert_raises(NoMethodError) { inst.access_key }
    ex = assert_raises(NoMethodError) { inst.secret_key }
    ex = assert_raises(NoMethodError) { inst.endpoint }

    inst.access_key = '5'
    inst.secret_key = '6'
    inst.endpoint = 'http://127.0.0.1'

    inst.define_singleton_method :access_key do
      instance_variable_get "@#{:access_key}".to_sym
    end

    inst.define_singleton_method :secret_key do
      instance_variable_get "@#{:secret_key}".to_sym
    end

    inst.define_singleton_method :endpoint do
      instance_variable_get "@#{:endpoint}".to_sym
    end

    assert_equal('5', inst.access_key)
    assert_equal('6', inst.secret_key)
    assert_equal('http://127.0.0.1', inst.endpoint)
  end

  def test_archive_then_upload
    inst = Server_os.new('test')
    inst.create_paths

    ex = assert_raises(NotImplementedError) { inst.archive_then_upload }
    assert_equal('You must use a derived mineos class to archive_then_upload', ex.message)
  end
end
