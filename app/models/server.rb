class Server < ActiveRecord::Base
  attr_reader :env

  after_initialize :set_paths  

  def set_paths
    @@basedir = '/var/games/minecraft'

    @env = {:cwd => File.join(@@basedir, 'servers', self.name),
            :bwd => File.join(@@basedir, 'backup', self.name),
            :awd => File.join(@@basedir, 'archive', self.name)}
  end

  def create_paths
    Dir.mkdir @env[:cwd]
    Dir.mkdir @env[:bwd]
    Dir.mkdir @env[:awd]
  end
end
