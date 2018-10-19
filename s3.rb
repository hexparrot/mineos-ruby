# module with S3 object store backend functionality

module S3
  attr_writer :access_key, :secret_key, :endpoint

  # Check if backend store exists (i.e., bucket)
  def s3_exists?(name:)
    r = Aws::S3::Resource.new
    r.bucket(name).exists?
  end

  # Create bucket if does not exist
  def s3_create_dest!
    c = Aws::S3::Client.new
    c.create_bucket(bucket: @name)
  end

  # Destroy bucket after emptying contents
  def s3_destroy_dest!
    r = Aws::S3::Resource.new
    objs = s3_list_files
    objs.each do |obj|
      r.bucket(@name).object(obj).delete
    end
    c = Aws::S3::Client.new
    c.delete_bucket(bucket: @name)
  end

  # List all files in the bucket
  def s3_list_files
    require 'set'
    objs = Set.new

    r = Aws::S3::Resource.new
    if s3_exists?
      r.bucket(@name).objects.each do |obj|
        objs << obj.key
      end
    end

    return objs
  end

  # Upload file FROM mineos.rb Server instance to S3 obj store
  def s3_upload_file!(env:, filename:)
    raise RuntimeError.new('parent path traversal not allowed') if filename.include? '..'

    case env
    when :awd, :cwd
      fp = File.join(@env[env], filename)
      raise RuntimeError.new('requested file does not exist') if !File.file?(fp)
    else
      raise RuntimeError.new('invalid path environment requested')
    end

    s3_create_dest! if !s3_exists?

    r = Aws::S3::Resource.new
    case env
    when :awd
      obj = r.bucket(@name).object("archive/#{filename}")
    when :cwd
      obj = r.bucket(@name).object("live/#{filename}")
    end

    obj.upload_file(fp)
    obj.key #return remote objstore name
  end

  # Download file TO mineos.rb Server instance from S3 obj store
  def s3_download_file!(env:, filename:)
    c = Aws::S3::Client.new
    case env
    when :awd
      obj_path = "archive/#{filename}"
    when :cwd
      obj_path = "live/#{filename}"
    end

    dest_path = File.join(@env[env], filename)
    c.get_object({ bucket:@name, key:obj_path }, target: dest_path)
    dest_path #return local name
  end

  # Download profile from internet, save in object store
  def get_external_profile(url:, group:, version:, dest_filename:)
    require 'open-uri'

    c = Aws::S3::Client.new
    r = Aws::S3::Resource.new
    c.create_bucket(bucket: 'profiles') if !r.bucket('profiles').exists?

    uri = URI.parse(url)
    file = Tempfile.new
    file.binmode
    open(uri) { |data| file.write data.read }
    obj = r.bucket('profiles').object("#{group}/#{version}/#{dest_filename}")
    obj.upload_file(file)
  end

  # Return list of files in a profile bucket
  def s3_list_profile_objects(group:, version:)
    require 'set'
    objs = Set.new

    r = Aws::S3::Resource.new
    if s3_exists?(name: 'profiles')
      r.bucket('profiles').objects(prefix: "#{group}/#{version}").each do |obj|
        objs << obj.key
      end
    end

    return objs
  end
end

