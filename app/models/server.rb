class Server < ActiveRecord::Base
  attr_reader :env

  after_initialize :check_servername, :set_paths  

  def valid_servername(name)
    return name.match(/^(?!\.)[a-zA-Z0-9_\.]+$/)
  end

  def check_servername
    raise RuntimeError if !self.valid_servername(self.name)
  end

  def set_paths
    @@basedir = '/var/games/minecraft'

    @env = {:cwd => File.join(@@basedir, 'servers', self.name),
            :bwd => File.join(@@basedir, 'backup', self.name),
            :awd => File.join(@@basedir, 'archive', self.name),
            :eula => File.join(@@basedir, 'servers', self.name, 'eula.txt'),
            :sp  => File.join(@@basedir, 'servers', self.name, 'server.properties'),
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

  def sc
    if !@config_sc
      if File.exist?(@env[:sc])
        @config_sc = IniFile.load(@env[:sc])
      else
        @config_sc = IniFile.new( :filename => @env[:sc] )
      end
    end
    return @config_sc.to_h
  end

  def sc!
    self.sc
    @config_sc.write
    return @config_sc.to_h
  end

  def modify_sc(attr, value, section)
    self.sc
    @config_sc[section] = { attr => value }
    @config_sc.write
    return @config_sc.to_h
  end

  def eula
    config_eula = IniFile.load( @env[:eula] )
    return config_eula.to_h['global']['eula']
  end

  def accept_eula
    File.write( @env[:eula], "eula=true\n")
  end

  def sp
    if !@config_sp
      if File.exist?(@env[:sp])
        @config_sp = IniFile.load(@env[:sp])
      else
        @config_sp = IniFile.new( :filename => @env[:sp] )
      end
    end

    # replace all instances of nil with empty string
    @config_sp.to_h['global'].keys.each do |key|
      if @config_sp['global'][key].nil?
        @config_sp['global'][key] = ''
      end
    end
    
    return @config_sp.to_h['global']
  end

  def sp!
    self.sp
    lines = @config_sp.to_s.split("\n")
    lines.shift
    IO.write(@env[:sp], lines.join("\n"))

    return self.sp
  end

  def modify_sp(attr, value)
    self.sp
    @config_sp['global'][attr] = value
    return self.sp!
  end

  def overlay_sp(hash)
    self.sp
    hash.each do |attr, value|
      @config_sp['global'][attr] = value 
    end
    return self.sp!
  end
end
