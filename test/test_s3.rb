require 'minitest/autorun'
require './mineos'

ACCEPTED_NAMES = ['test', 'asdf1234', 'vanilla-1.8.9']
REJECTED_NAMES = ['.test', '#test', '?test', '!test', 'server\'s', 'test^again', 'feed me', 'hello_is_it_me', 'Vanilla-1.8.9', '1.7.10', 'UPPERCASE']

class ServerTest < Minitest::Test

  def setup
    @@basedir = '/var/games/minecraft'

    require 'fileutils'
    FileUtils.rm_rf(@@basedir)
    FileUtils.mkdir_p(File.join(@@basedir, 'servers'))
    FileUtils.mkdir_p(File.join(@@basedir, 'backup'))
    FileUtils.mkdir_p(File.join(@@basedir, 'archive'))

    require 'yaml'
    config = YAML::load_file('config/objstore.yml')

    require 'aws-sdk-s3'
    Aws.config.update(
      endpoint: config['object_store']['host'],
      access_key_id: config['object_store']['access_key'],
      secret_access_key: config['object_store']['secret_key'],
      force_path_style: true,
      region: 'us-west-1'
    )
  end

  def teardown
  end

  def test_credentials
    inst = Server.new('test')
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

  def test_exists?
    inst = Server.new('test')
    assert_equal(false, inst.s3_exists?(name: 'test'))
  end

  def test_create_rejects_bad_input
    inst = Server.new('test')
    ACCEPTED_NAMES.each do |name|
      inst.s3_create_dest!(name: name) #does not throw
      inst.s3_destroy_dest!(name: name)
    end
    REJECTED_NAMES.each do |name|
      ex = assert_raises(RuntimeError) { inst.s3_create_dest!(name: name) }
      assert_equal('servername format/characters not valid', ex.message)
    end
  end

  def test_create_and_destroy_bucket
    inst = Server.new('test')
    assert_equal(false, inst.s3_exists?(name: 'test'))
    inst.s3_create_dest!(name: 'test')
    assert_equal(true, inst.s3_exists?(name: 'test'))
    inst.s3_destroy_dest!(name: 'test')
    assert_equal(false, inst.s3_exists?(name: 'test'))
  end

  def test_s3_list_files
    require 'set'
    inst = Server.new('test')
    files = inst.s3_list_files(name: 'test')
    assert_equal(0, files.length)
    assert(files.is_a?(Set))
  end

  def test_archive_then_upload
    inst = Server.new('test')
    inst.create(:conventional_jar)
    fn = inst.archive_then_upload
    files = inst.s3_list_files(name: 'test')
    assert_equal(1, files.length)
    fp = "archive/#{fn}"
    assert_equal(fp, files.first)
    assert(files.is_a?(Set))
    inst.s3_destroy_dest!(name: 'test')
  end

  def test_destroy_bucket_with_contents
    inst = Server.new('test')
    inst.create(:conventional_jar)
    fn = inst.archive_then_upload
    inst.s3_destroy_dest!(name: 'test')
    assert_equal(false, inst.s3_exists?(name: 'test'))
    files = inst.s3_list_files(name: 'test')
    assert_equal(0, files.length)
  end

  def test_upload_sp
    inst = Server.new('test')
    inst.create(:conventional_jar)
    inst.modify_sp('value', 'transmitted!')
    inst.sp!
    retval = inst.s3_upload_file!({env: :cwd, filename: 'server.properties'})
    files = inst.s3_list_files(name: 'test')
    assert_equal(1, files.length)
    assert_equal(retval, files.first)
    inst.s3_destroy_dest!(name: 'test')
  end

  def test_bad_upload_file_doesnt_exist
    inst = Server.new('test')
    ex = assert_raises(RuntimeError) {
      inst.s3_upload_file!({env: :cwd, filename: 'nonexistent.file'})
    }
    assert_equal('requested file does not exist', ex.message)
  end

  def test_bad_upload_file_path_exploiting
    inst = Server.new('test')
    ex = assert_raises(RuntimeError) {
      inst.s3_upload_file!({env: :cwd, filename: '../../../root/.bash_history'})
    }
    assert_equal('parent path traversal not allowed', ex.message)
  end

  def test_bad_upload_file_path_env
    inst = Server.new('test')
    ex = assert_raises(RuntimeError) {
      inst.s3_upload_file!({env: :zing, filename: '.bash_history'})
    }
    assert_equal('invalid path environment requested', ex.message)
  end

  def test_download_sp
    inst = Server.new('test')
    inst.create(:conventional_jar)

    # set initial 25570 value
    inst.modify_sp('server-port', 25570)
    assert_equal(25570, inst.sp['server-port'])
    inst.sp!

    # send 25570 value remotely
    retval = inst.s3_upload_file!({env: :cwd, filename: 'server.properties'})

    # change local value to 25580
    inst.modify_sp('server-port', 25580)
    inst.sp!
    inst = Server.new('test')
    assert_equal(25580, inst.sp['server-port'])

    # retrieve 25570 remote value to overwrite (new inst to force sp reload)
    retval = inst.s3_download_file!({env: :cwd, filename: 'server.properties'})
    assert_equal(inst.env[:sp], retval)
    inst = Server.new('test')
    assert_equal(25570, inst.sp['server-port'])

    inst.s3_destroy_dest!(name: 'test')
  end

  def test_get_external_profile
    require 'open-uri'

    url = 'https://launcher.mojang.com/v1/objects/b58b2ceb36e01bcd8dbf49c8fb66c55a9f0676cd/server.jar'

    inst = Object.new #not the Server object
    inst.extend(S3)

    inst.get_external_profile(url, 'mojang', '1.2.1', 'server.jar')

    c = Aws::S3::Client.new
    src_path = "mojang/1.2.1/server.jar"
    begin
      resp = c.get_object({ bucket: 'profiles', key: src_path })
    rescue Aws::S3::Errors::NoSuchKey => e
      assert(false)
    else
      assert(resp)
    end
    inst.s3_destroy_dest!(name: 'profiles')
  end

  def test_receive_profile
    require 'open-uri'

    url = 'https://www.w3.org/TR/PNG/iso_8859-1.txt'

    inst = Object.new #not the Server object
    inst.extend(S3)

    inst.get_external_profile(url, 'mojang', '1.8.9', 'iso_8859-1.txt')

    inst2 = Server.new('test')
    inst2.create(:conventional_jar)
    
    fp = File.join(inst2.env[:cwd], 'iso_8859-1.txt')
    assert(!File.file?(fp))

    files_transferred = inst2.receive_profile('mojang', '1.8.9')
    assert_equal(1, files_transferred.length)
    assert(File.file?(fp))
    inst2.s3_destroy_dest!(name: 'profiles')
  end

  def test_s3_list_profile_objects
    require 'open-uri'

    url = 'https://www.w3.org/TR/PNG/iso_8859-1.txt'

    inst = Object.new #not the Server object
    inst.extend(S3)

    inst.get_external_profile(url, 'mojang', '1.8.9', 'iso_8859-1.txt')

    files = inst.s3_list_profile_objects(group: 'mojang', version: '1.8.9')
    assert_equal(1, files.length)
    assert_equal('iso_8859-1.txt', files.first)
    inst.s3_destroy_dest!(name: 'profiles')
  end

  def test_s3_download_profile_object
    require 'open-uri'

    url = 'https://www.w3.org/TR/PNG/iso_8859-1.txt'

    inst = Server.new('test')

    inst.get_external_profile(url, 'mojang', '1.8.9', 'iso_8859-1.txt')

    files = inst.s3_list_profile_objects(group: 'mojang', version: '1.8.9')
    files.each do |src_path|
      dest_path = File.join(inst.env[:cwd], src_path)
      #/var/games/minecraft/servers/test/iso_8859-1.txt
      prefix_added = "mojang/1.8.9/#{src_path}"
      #mojang/1.8.9/iso_8859-1.txt
      inst.s3_download_profile_object(src: prefix_added, dest: dest_path)
      assert(File.file?(dest_path))
    end
    inst.s3_destroy_dest!(name: 'profiles')
  end

  def test_nested_profile_download
    inst = Server.new('test')

    inst.s3_create_dest!(name: 'profiles') if !inst.s3_exists?(name: 'profiles')

    r = Aws::S3::Resource.new
    obj = r.bucket('profiles').object('mojang/1.8.9/top_level')
    obj.put(body: 'Hello World!')
    obj = r.bucket('profiles').object('mojang/1.8.9/dir/sec_level')
    obj.put(body: 'Hello World!!')

    inst.receive_profile('mojang', '1.8.9')

    assert(File.file?(File.join(inst.env[:cwd], 'top_level')))
    assert(File.file?(File.join(inst.env[:cwd], 'dir', 'sec_level')))
    inst.s3_destroy_dest!(name: 'profiles')
  end
end

