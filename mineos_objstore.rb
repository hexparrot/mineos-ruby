require './mineos'

# Server instance with Object Store Backend
class Server_os < Server
  attr_writer :access_key, :secret_key, :endpoint

  # Create an archive, then upload it to somewhere (likely hq)
  def archive_then_upload
    raise NotImplementedError.new('You must use a derived mineos class to archive_then_upload')
  end

end
