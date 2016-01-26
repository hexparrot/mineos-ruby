class Server < ActiveRecord::Base
  attr_reader :env

  after_initialize :check_servername, :set_paths  

  def check_servername
    raise RuntimeError if !self.name.match(/^(?!\.)[a-zA-Z0-9_\.]+$/)
  end

  def set_paths
    @@basedir = '/var/games/minecraft'

    @env = {:cwd => File.join(@@basedir, 'servers', self.name),
            :bwd => File.join(@@basedir, 'backup', self.name),
            :awd => File.join(@@basedir, 'archive', self.name)}
  end

  def create_paths
    [:cwd, :bwd, :awd].each do |directory|
      begin
        Dir.mkdir @env[directory]
      rescue Errno::EEXIST
      end
    end
  end
end
