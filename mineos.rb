require 'bundler/setup'
Bundler.require

class Server
  attr_reader :name, :env, :server_type, :status, :console_log
  VALID_NAME_REGEX = /^(?!\.)[a-zA-Z0-9_\.]+$/

  def initialize(name)
    raise RuntimeError if !self.valid_servername(name)
    @name = name
    @status = {}
    @console_log = Queue.new
    self.set_env
  end

  # Checks a name is directory-safe and follows
  # a few other historical MineOS conventions
  def valid_servername(name)
    return name.match(VALID_NAME_REGEX)
  end

  # Establish an easy reference @env for common paths
  def set_env
    @@basedir = '/var/games/minecraft'

    @env = {:cwd => File.join(@@basedir, 'servers', self.name),
            :bwd => File.join(@@basedir, 'backup', self.name),
            :awd => File.join(@@basedir, 'archive', self.name),
            :sp  => File.join(@@basedir, 'servers', self.name, 'server.properties'),
            :sc  => File.join(@@basedir, 'servers', self.name, 'server.config'),
            :eula => File.join(@@basedir, 'servers', self.name, 'eula.txt')}
  end

  # Create directory paths and establish server.config (convenience)
  def create(server_type=:conventional_jar)
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

  # Create directory paths in filesystem
  # Includes /var/games/minecraft/{servers,backup,archive}/servername
  def create_paths
    [:cwd, :bwd, :awd].each do |directory|
      begin
        Dir.mkdir @env[directory]
      rescue Errno::EEXIST
      end
    end
  end

  # Delete server directories and files (convenience)
  def delete
    if self.pid
      raise RuntimeError.new('cannot delete a server that is running')
    else
      self.delete_paths
    end
  end
 
  # Delete directory paths from filesystem
  # Includes /var/games/minecraft/{servers,backup,archive}/servername
  def delete_paths
    require('fileutils')
    [:cwd, :bwd, :awd].each do |directory|
      FileUtils.rm_rf @env[directory]
    end
  end

  # Return hash of server.config file from in-memory
  # This will "create" one if absent, but will not commit it to disk.
  # See sc! for committing server.config to the filesystem.
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

  # Writes in-memory hash to ini-formatted server.config
  def sc!
    self.sc
    @config_sc.write
    return @config_sc.to_h
  end

  # Modify in-memory hash for server.config (convenience)
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

  # Reads eula.txt and returns boolean equivalent
  def eula
    config_eula = IniFile.load( @env[:eula] )
    return config_eula.to_h['global']['eula']
  end

  # Writes an accepted eula.txt to the filesystem
  def accept_eula
    File.write( @env[:eula], "eula=true\n")
  end

  # Return hash of server.properties file from in-memory
  # This will "create" one if absent, but will not commit it to disk.
  # See sp! for committing server.properties to the filesystem.
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

  # Writes in-memory hash to ini-like server.properties
  def sp!
    self.sp
    lines = @config_sp.to_s.split("\n")
    #inifile auto [sections] files with "global", this removes it
    lines.shift
    IO.write(@env[:sp], lines.join("\n"))

    return self.sp
  end

  # Modify in-memory hash for server.properties (convenience)
  def modify_sp(attr, value)
    self.sp
    @config_sp['global'][attr] = value
    return self.sp!
  end

  # Accepts hash and applies key:value pairs to server.properties (convenience)
  def overlay_sp(hash)
    self.sp
    hash.each do |attr, value|
      @config_sp['global'][attr] = value 
    end
    return self.sp!
  end

  # Returns tokenized arguments for starting server in array
  # Has different starting requirements based on server-type
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

  # Attempt to start the server executable based on server type
  # This will start a new thread for parsing the stdout, @stdout_parser
  # @stdout_parser will populate @status with key milestones indicating
  # the server startup progress or potential failures.
  def start
    raise RuntimeError.new('server is already running') if self.pid
    require('open3')

    @status = {}
    @start_args = self.get_start_args(:conventional_jar)
    @stdin, stdout, stderr, wait_thr = Open3.popen3(*@start_args, {:chdir => @env[:cwd], :umask => 0o002})

    @stdout_parser = Thread.new {
      while line=stdout.gets do
        @console_log << line
        case line
        when /\[Server thread\/INFO\]: Starting minecraft server version/
          @status[:version] = line
        when /\[Server thread\/INFO\]: Default game type: SURVIVAL/
          @status[:type] = line
        when /\[Server thread\/INFO\]: Starting Minecraft server on/
          @status[:port] = line
        when /\[Server thread\/INFO\]: Preparing level/
          @status[:level] = line
        when /\[Server thread\/INFO\]: Done/
          @status[:done] = line
        when /\[Server thread\/INFO\]: Stopping server/
          @status[:stopping] = line
        when /\[Server thread\/WARN\]: Failed to load eula.txt/
          @status[:eula] = line
        when /\[Server thread\/WARN\]: [^F]+FAILED TO BIND TO PORT/
          @status[:bind] = line
        when /A fatal error has been detected by the Java Runtime Environment/
          @status[:fatal_error] = line
        end
      end
    }
    @pid = wait_thr[:pid]

    return @pid
  end

  # Attempt to start the server executable based on server type
  # This does the same as self.start but with the added functionality
  # that if expected milestones aren't triggered in a given timeframe
  # or if known-failure (predictable) events occur, it can raise errors
  # which can be handled and presented more thoroughly
  def start_catch_errors(timeout = 25)
    raise RuntimeError.new('timeout must be a positive integer > 0') if !timeout.is_a?(Fixnum)
    sleep_delay = 0.2
    self.start

    while timeout > 0 do
      if @status.key?(:eula)
        self.sleep_until(:down)
        raise RuntimeError.new('you need to agree to the eula in order to run the server')
      elsif @status.key?(:bind)
        self.sleep_until(:down)
        raise RuntimeError.new('server port is already in use')
      elsif @status.key?(:done)
        sleep(sleep_delay)
        if @status.key?(:fatal_error)
          self.sleep_until(:down)
          raise RuntimeError.new('A fatal error has been detected by the Java Runtime Environment')
        end
        break
      end
      timeout -= sleep_delay
      sleep(sleep_delay)
    end

    return :done if @status.key?(:done)
    return :level if @status.key?(:level)
  end

  # Attempts to stop a server by submitting 'stop' to the process
  def stop
    if self.pid
      self.console('stop')
      self.sleep_until(:down)
      @stdout_parser.exit
      self.sleep_until(:parser_down, 2)
    else
      raise RuntimeError.new('cannot stop server while it is stopped')
    end
  end

  # Attempts to kill a server's process ID forcefully
  def kill(signal = :sigterm)
    raise RuntimeError.new('cannot kill server while it is stopped') if !self.pid
    case signal 
    when :sigterm
      Process.kill(15, self.pid)
    when :sigkill
      Process.kill(9, self.pid)
    when :sigint
      Process.kill(2, self.pid)
    end
    self.sleep_until(:down)
  end

  # Returns the PID of a server process
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

  # A non-busywait method to halt execution until a given state triggers
  # Each condition must be pre-programmed.
  def sleep_until(state, timeout = 60)
    raise RuntimeError.new('timeout must be a positive integer > 0') if !timeout.is_a?(Fixnum)
    sleep_delay = 0.2

    case state
    when :done
      until @status.key?(:done) do
        raise RuntimeError.new('condition not satisfied in allowed time') if timeout <= 0
        sleep(sleep_delay)
        timeout -= sleep_delay
      end
    when :down
      while self.pid do
        raise RuntimeError.new('condition not satisfied in allowed time') if timeout <= 0
        sleep(sleep_delay)
        timeout -= sleep_delay
      end
    when :parser_down
      while @stdout_parser.status != false do
        raise RuntimeError.new('condition not satisfied in allowed time') if timeout <= 0
        sleep(sleep_delay)
        timeout -= sleep_delay
      end
    end
  end

  # Submit a string of text to the process' stdin
  def console(text)
    if @stdin.is_a?(IO)
      @stdin << text + "\n"
    else
      raise IOError.new('I/O channel is down')
    end
  end

  # Return a hash of the server's process' memory footprint
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

  # Create a gzipped tarball containing all server files
  def archive
    require 'mkmf'

    fn = "#{self.name}_#{Time.now.strftime('%F_%R:%S')}.tgz"
    fp = File.join(@env[:awd], fn)
    system("#{find_executable0 'tar'} --force-local -czf #{fp} .", {:chdir => @env[:cwd]})
    return fn
  end
 
  # Create a new server from an existing tarball (convenience)
  def create_from_archive(filepath)
    require 'mkmf'

    self.create_paths
    raise RuntimeError.new('cannot extract archive over existing server') if Dir.entries(@env[:cwd]).include?('server.config')
    system("#{find_executable0 'tar'} --force-local -xf #{filepath}", {:chdir => @env[:cwd]})
  end

  # Create an rdiff-backup of the main server directory
  def backup
    require 'mkmf'

    system("#{find_executable0 'rdiff-backup'} #{@env[:cwd] + '/'} #{@env[:bwd]}", {:chdir => @env[:bwd]})    
  end

  # Restore the live server directory to the state of a previous backup
  def restore(steps)
    raise RuntimeError.new('cannot restore server while it is running') if self.pid
    system("rdiff-backup --restore-as-of #{steps} --force #{@env[:bwd]} #{@env[:cwd]}", {:chdir => @env[:bwd]})
  end

end
