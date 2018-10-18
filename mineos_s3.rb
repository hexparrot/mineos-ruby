require './mineos'

# Server instance with Object Store Backend
class Server_S3 < Server
  attr_writer :access_key, :secret_key, :endpoint

  # Create an archive, then upload it to somewhere (likely hq)
  def archive_then_upload
    fn = self.archive
    be_upload_file!(env: :awd, filename: fn)
    return fn
  end

  # Check if backend store exists (i.e., bucket)
  private def be_exists?
    r = Aws::S3::Resource.new
    r.bucket(@name).exists?
  end

  private def be_create_dest!
    c = Aws::S3::Client.new
    c.create_bucket(bucket: @name)
  end

  private def be_destroy_dest!
    r = Aws::S3::Resource.new
    objs = be_list_files
    objs.each do |obj|
      r.bucket(@name).object(obj).delete
    end
    c = Aws::S3::Client.new
    c.delete_bucket(bucket: @name)
  end

  private def be_list_files
    require 'set'
    objs = Set.new

    r = Aws::S3::Resource.new
    if be_exists?
      r.bucket(@name).objects.each do |obj|
        objs << obj.key
      end
    end

    return objs
  end

  private def be_upload_file!(env:, filename:)
    raise RuntimeError.new('parent path traversal not allowed') if filename.include? '..'

    case env
    when :awd, :cwd
      fp = File.join(@env[env], filename)
      raise RuntimeError.new('requested file does not exist') if !File.file?(fp)
    else
      raise RuntimeError.new('invalid path environment requested')
    end

    be_create_dest! if !be_exists?

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

  private def be_download_file!(env:, filename:)
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

  def receive_profile(group:, filename:)
    c = Aws::S3::Client.new
    dest_path = File.join(@env[:cwd], filename)
    src_path = "#{group}/#{filename}"
    c.get_object({ bucket: 'profiles', key: src_path }, target: dest_path)
  end
end

