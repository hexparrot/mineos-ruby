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
            :sp  => File.join(@@basedir, 'servers', self.name, 'server.properties'),
            :sc  => File.join(@@basedir, 'servers', self.name, 'server.config'),
            :eula => File.join(@@basedir, 'servers', self.name, 'eula.txt')}
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
      FileUtils.rm_rf @env[directory]
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
    if !@config_sc.has_section?(section)
      @config_sc[section] = { attr => value }
    else
      @config_sc[section][attr] = value
    end
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
    #inifile auto [sections] files with "global", this removes it
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

  def get_jar_args(type)
    args = {}
    
    raise RuntimeError.new('no runnable jarfile selected') if self.sc['java']['jarfile'].nil?
    raise RuntimeError.new('missing java argument: Xmx') if self.sc['java']['java_xmx'].nil?
    raise RuntimeError.new('invalid java argument: Xmx must be > 0') if self.sc['java']['java_xmx'].to_i <= 0
    raise RuntimeError.new('invalid java argument: Xmx must be > Xms') if self.sc['java']['java_xms'].to_i > self.sc['java']['java_xmx'].to_i

    args[:jarfile] = self.sc['java']['jarfile'] 
    args[:java_xmx] = self.sc['java']['java_xmx'].to_i
    args[:java_tweaks] = self.sc['java']['java_tweaks']
    args[:jar_args] = self.sc['java']['jar_args']
    if self.sc['java']['java_xms'].to_i > 0
      args[:java_xms] = self.sc['java']['java_xms'].to_i
    else
      args[:java_xms] = self.sc['java']['java_xmx'].to_i
    end

    require 'mkmf'
    args[:binary] = find_executable0 'java'

    retval = []
    retval << args[:binary] << '-server' << "-Xmx%{java_xmx}M" % args << "-Xms%{java_xms}M" % args
    if args[:java_tweaks]
      retval << args[:java_tweaks]
    end
    retval << '-jar' << args[:jarfile]
    if args[:jar_args].nil?
      retval << 'nogui'
    else
      retval << args[:jar_args]
    end

    return retval
  end
end
