require './mineos'

# Server instance with Object Store Backend
class Server_S3 < Server
  attr_writer :access_key, :secret_key, :endpoint

  # Create an archive, then upload it to somewhere (likely hq)
  def archive_then_upload
    fn = self.archive
    self.be_upload_file!(env: :awd, filename: fn)
    return fn
  end

  # Check if backend store exists (i.e., bucket)
  def be_exists?
    r = Aws::S3::Resource.new
    r.bucket(@name).exists?
  end

  def be_create_dest!
    c = Aws::S3::Client.new
    c.create_bucket(bucket: @name)
  end

  def be_destroy_dest!
    c = Aws::S3::Client.new
    objs = self.be_list_files
    objs.each do |obj|
      c.delete_objects(
        bucket: @name,
        delete: {
          objects: [
            {
              key: obj
            }
          ]
        }
    )

    end
    c.delete_bucket(bucket: @name)
  end

  def be_list_files
    require 'set'
    objs = Set.new

    r = Aws::S3::Resource.new
    if self.be_exists?
      r.bucket(@name).objects.each do |obj|
        objs << obj.key
      end
    end

    return objs
  end

  def be_upload_file!(env:, filename:)
    raise RuntimeError.new('parent path traversal not allowed') if filename.include? '..'

    case env
    when :awd, :cwd
      fp = File.join(@env[env], filename)
      raise RuntimeError.new('requested file does not exist') if !File.file?(fp)
    else
      raise RuntimeError.new('invalid path environment requested')
    end

    self.be_create_dest! if !self.be_exists?

    r = Aws::S3::Resource.new
    case env
    when :awd
      obj = r.bucket(@name).object("archive/#{filename}")
    when :cwd
      obj = r.bucket(@name).object("servers/#{filename}")
    end

    obj.upload_file(fp)
    obj.key
  end

end

