class Server
  attr_reader :name, :env, :pipes, :server_type

  def initialize(name)
    raise RuntimeError if !self.valid_servername(name)
    @name = name
    self.set_env
  end

  def valid_servername(name)
    return name.match(/^(?!\.)[a-zA-Z0-9_\.]+$/)
  end

  def set_env
    @@basedir = '/var/games/minecraft'

    @env = {:cwd => File.join(@@basedir, 'servers', self.name),
            :bwd => File.join(@@basedir, 'backup', self.name),
            :awd => File.join(@@basedir, 'archive', self.name),
            :sp  => File.join(@@basedir, 'servers', self.name, 'server.properties'),
            :sc  => File.join(@@basedir, 'servers', self.name, 'server.config'),
            :eula => File.join(@@basedir, 'servers', self.name, 'eula.txt')}

    @pipes = {:stdin => IO.pipe,
              :stdout => IO.pipe,
              :stderr => IO.pipe}
  end

  def create(server_type)
    @server_type = server_type
    case server_type
    when :conventional_jar
      self.create_paths
      self.sc!
      self.sp!
    when :unconventional_jar, :phar
      self.create_paths
      self.sc!
    else
      raise RuntimeError.new("unrecognized server type: #{server_type.to_s}")
    end
  end

  def create_paths
    [:cwd, :bwd, :awd].each do |directory|
      begin
        Dir.mkdir @env[directory]
      rescue Errno::EEXIST
      end
    end
  end

  def delete
    if self.pid
      raise RuntimeError.new('cannot delete a server that is running')
    else
      self.delete_paths
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

  def get_start_args(type)
    require 'mkmf'
    args = {}
    retval = []

    case type
      when :conventional_jar
        raise RuntimeError.new('no runnable jarfile selected') if self.sc['java']['jarfile'].nil?
        raise RuntimeError.new('missing java argument: Xmx') if self.sc['java']['java_xmx'].nil?
        raise RuntimeError.new('invalid java argument: Xmx must be an integer > 0') if !self.sc['java']['java_xmx'].is_a?(Integer)
        raise RuntimeError.new('invalid java argument: Xmx must be an integer > 0') if self.sc['java']['java_xmx'].to_i <= 0
        raise RuntimeError.new('invalid java argument: Xms must be unset or an integer > 0') if !self.sc['java']['java_xms'].is_a?(Integer)
        raise RuntimeError.new('invalid java argument: Xmx must be > Xms') if self.sc['java']['java_xms'].to_i > self.sc['java']['java_xmx'].to_i

        args[:jarfile] = self.sc['java']['jarfile'] 
        args[:java_xmx] = self.sc['java']['java_xmx'].to_i
        args[:java_tweaks] = self.sc['java']['java_tweaks']
        args[:jar_args] = self.sc['java']['jar_args']
        #use xms value if present and > 0, else fallback to xmx
        args[:java_xms] = self.sc['java']['java_xms'].to_i > 0 ? self.sc['java']['java_xms'].to_i : self.sc['java']['java_xmx'].to_i
        args[:binary] = find_executable0 'java'

        retval << args[:binary] << '-server' << "-Xmx%{java_xmx}M" % args << "-Xms%{java_xms}M" % args
        retval << args[:java_tweaks] if args[:java_tweaks]
        retval << '-jar' << args[:jarfile]
        #if no jar args specified, auto-fill in 'nogui'
        retval << (args[:jar_args].nil? ? 'nogui' : args[:jar_args])
      when :unconventional_jar
        raise RuntimeError.new('no runnable jarfile selected') if self.sc['java']['jarfile'].nil?
        raise RuntimeError.new('invalid java argument: Xmx must be unset or > 0') if self.sc['java']['java_xmx'].to_i < 0
        raise RuntimeError.new('invalid java argument: Xms must be unset or > 0') if self.sc['java']['java_xms'].to_i < 0
        raise RuntimeError.new('invalid java argument: Xms may not be set without Xmx') if self.sc['java']['java_xms'].to_i > 0 && self.sc['java']['java_xmx'].to_i <= 0
        raise RuntimeError.new('invalid java argument: Xmx may not be lower than Xms') if self.sc['java']['java_xms'].to_i > self.sc['java']['java_xmx'].to_i
        raise RuntimeError.new('invalid java argument: Xmx must be unset or an integer > 0') if !self.sc['java']['java_xmx'].is_a?(Integer)
        raise RuntimeError.new('invalid java argument: Xms must be unset or an integer > 0') if !self.sc['java']['java_xms'].is_a?(Integer)

        args[:jarfile] = self.sc['java']['jarfile'] 
        args[:java_tweaks] = self.sc['java']['java_tweaks']
        args[:jar_args] = self.sc['java']['jar_args']
        args[:java_xmx] = self.sc['java']['java_xmx'].to_i if self.sc['java']['java_xmx'].to_i > 0
        args[:java_xms] = self.sc['java']['java_xms'].to_i if self.sc['java']['java_xms'].to_i > 0
        args[:binary] = find_executable0 'java'

        retval << args[:binary] << '-server' 
        #Xmx and Xms are non-compulsory
        retval << "-Xmx%{java_xmx}M" % args if args[:java_xmx]
        retval << "-Xms%{java_xms}M" % args if args[:java_xms]
        retval << args[:java_tweaks] if args[:java_tweaks]
        retval << '-jar' << args[:jarfile]
        retval << args[:jar_args] if args[:jar_args]
      when :phar
        args[:binary] = find_executable0 'php'

        if self.sc['nonjava']['executable'].to_s.length > 0
          args[:executable] = self.sc['nonjava']['executable']
          retval << args[:binary] << args[:executable]
        elsif self.sc['java']['jarfile'].to_s.length > 0
          args[:executable] = self.sc['java']['jarfile']
          retval << args[:binary] << args[:executable]
        else
          raise RuntimeError.new('no runnable pharfile selected')
        end
      else
        raise NotImplementedError.new("unrecognized get_start_args argument: #{type.to_s}")
    end

    return retval
  end

  def start
    raise RuntimeError.new('server is already running') if self.pid
    require('open3')

    @start_args = self.get_start_args(:conventional_jar)
    stdin, stdout, stderr, wait_thr = Open3.popen3(*@start_args, {:chdir => @env[:cwd], :umask => 0o002})
    @pipes = {:stdin => stdin, :stdout => stdout, :stderr => stderr}
    @pid = wait_thr[:pid]

    return @pid
  end

  def pid
    if @pid
      begin
        Process.getpgid(@pid) #reassigns nil if pid nonexistent, otherwise retain existing value
      rescue Errno::ESRCH
        @pid = nil
      end
    end
    @pid
  end

  def console(text)
    if @pipes[:stdin].is_a?(IO)
      @pipes[:stdin] << text + "\n"
    else
      raise IOError.new('I/O channel is down')
    end
  end

  def mem
    if @pid
      require('get_process_mem')

      mem_obj = GetProcessMem.new(@pid)
      mem_obj.inspect
      return {:kb => mem_obj.kb, :mb => mem_obj.mb, :gb => mem_obj.gb}
    else
      return {:kb => 0.0, :mb => 0.0, :gb => 0.0}
    end
  end

  def archive
    require('shellwords')
    require('zlib')
    require('archive/tar/minitar')

    fn = "#{self.name}_#{Time.now.strftime('%F_%R:%S')}.tgz"
    fp = File.join(@env[:awd], fn)
    system("tar --force-local -czf #{fp} .", {:chdir => @env[:cwd]})
    return fn
  end
  
end
