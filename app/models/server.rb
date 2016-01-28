class Server < ActiveRecord::Base
  attr_reader :env, :sc

  after_initialize :check_servername, :set_paths  

  def check_servername
    raise RuntimeError if !self.name.match(/^(?!\.)[a-zA-Z0-9_\.]+$/)
  end

  def set_paths
    @@basedir = '/var/games/minecraft'

    @env = {:cwd => File.join(@@basedir, 'servers', self.name),
            :bwd => File.join(@@basedir, 'backup', self.name),
            :awd => File.join(@@basedir, 'archive', self.name),
            :sc  => File.join(@@basedir, 'servers', self.name, 'server.config')}
  end

  def create_paths
    [:cwd, :bwd, :awd].each do |directory|
      begin
        Dir.mkdir @env[directory]
      rescue Errno::EEXIST
      end
    end
  end

  def create_sc
    require('inifile')
    @config_sc = IniFile.new( :filename => @env[:sc] )
    @config_sc.write
    @sc = @config_sc.to_h
  end

  def modify_sc(attr, value, section)
    @config_sc[section] = { attr => value }
    @config_sc.write
    @sc = @config_sc.to_h
  end

end
