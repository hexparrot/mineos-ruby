class Server < ActiveRecord::Base
  attr_reader :cwd, :bwd, :awd

  after_initialize :set_paths  

  def set_paths
    @basedir = '/var/games/minecraft'
    @cwd = File.join(@basedir, 'servers', self.name)
    @bwd = File.join(@basedir, 'backup', self.name)
    @awd = File.join(@basedir, 'archive', self.name)
  end

end
