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
            :eula => File.join(@@basedir, 'servers', 'eula.txt'),
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
  
  def delete_paths
    require('fileutils')
    [:cwd, :bwd, :awd].each do |directory|
      #begin
        FileUtils.rm_rf @env[directory]
      #rescue Errno::EEXIST
      #end
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

  def eula
    config_eula = IniFile.new( :filename => @env[:eula] )
    @eula = config_eula.to_h['global']['eula']
    @eula
  end

  def accept_eula
    File.write( @env[:eula], 'eula=true\n')
  end

end
