class Pocketknife_windows
  # == Node
  #
  # A node represents a remote computer that will be managed with Pocketknife and <tt>chef-solo</tt>. It can connect to a node, execute commands on it, install the stack, and upload and apply configurations to it.
  class Node
    # String name of the node.
    attr_accessor :name

    # Instance of a {Pocketknife}.
    attr_accessor :pocketknife

    # Instance of Rye::Box connection, cached by {#connection}.
    attr_accessor :connection_cache

    # Hash with information about platform, cached by {#platform}.
    attr_accessor :platform_cache
    
    @sudo = ""

    # Initialize a new node.
    #
    # @param [String] name A node name.
    # @param [Pocketknife] pocketknife
    def initialize(name, pocketknife)
      self.name = name
      self.pocketknife = pocketknife
      self.connection_cache = nil
    end

    # Returns a Rye::Box connection.
    #
    # Caches result to {#connection_cache}.
    def connection
      return self.connection_cache ||= begin
          user = "Administrator"
          if self.pocketknife.user != nil and self.pocketknife.user != ""
             user = self.pocketknife.user
          end
          if self.pocketknife.ssh_key != nil and self.pocketknife.ssh_key != ""
             puts "Connecting to.... #{self.name} as user #{user} with ssh key"
             rye = Rye::Box.new(self.name, {:user => user, :keys => self.pocketknife.ssh_key })
          elsif self.pocketknife.password != nil and self.pocketknife.password != ""
             puts "Connecting to.... #{self.name} as user #{user} with password"
             rye = Rye::Box.new(self.name, {:user => user, :password => self.pocketknife.password })   
          else
             puts "Connecting to.... #{self.name} as user #{user}"
             rye = Rye::Box.new(self.name, {:user => user })
          end
          rye.disable_safe_mode
          rye
        end
    end

    # Displays status message.
    #
    # @param [String] message The message to display.
    # @param [Boolean] importance How important is this? +true+ means important, +nil+ means normal, +false+ means unimportant.
    def say(message, importance=nil)
      self.pocketknife.say("* #{self.name}: #{message}", importance)
    end

    # Returns path to this node's <tt>nodes/NAME.json</tt> file, used as <tt>node.json</tt> by <tt>chef-solo</tt>.
    #
    # @return [Pathname]
    def local_node_json_pathname
      return Pathname.new("nodes") + "#{self.name}.json"
    end

    # Does this node have the given executable?
    #
    # @param [String] executable A name of an executable, e.g. <tt>chef-solo</tt>.
    # @return [Boolean] Has executable?
    def has_executable?(executable)
      begin
        self.connection.execute("if exist #{executable} (  exit 0 ) else (    exit 1 )")
        return true
      rescue Rye::Err
        return false
      end
    end

    # Returns information describing the node.
    #
    # The information is formatted similar to this:
    #   {
    #     :distributor=>"Ubuntu", # String with distributor name
    #     :codename=>"maverick", # String with release codename
    #     :release=>"10.10", # String with release number
    #     :version=>10.1 # Float with release number
    #   }
    #
    # @return [Hash<String, Object] Return a hash describing the node, see above.
    # @raise [UnsupportedInstallationPlatform] Raised if there's no installation information for this platform.
    def platform
      return self.platform_cache ||= begin
          result = {}
          result[:distributor] = "windows_server"
          result[:release] = ""
          result[:codename] = ""
          result[:version] = 0
          return result
      rescue    
      end
    end

    def file_upload(from,to)
          self.say("File Upload #{from} to #{to}", false)          
          user = "Administrator"
          if self.pocketknife.user != nil and self.pocketknife.user != ""
             user = self.pocketknife.user
          end
          self.say("using user #{user} and password ",false)
          #hash = {:password => self.pocketknife.password, :verbose => :debug, :paranoid => false}
          Net::SFTP.start(self.name, user, :password =>  self.pocketknife.password) do |sftp|
             sftp.upload!(from, to)
          end
    end   
    
    # Installs Chef and its dependencies on a windows node if needed.
    #
    # @raise [NotInstalling] Raised if Chef isn't installed, but user didn't allow installation.
    # @raise [UnsupportedInstallationPlatform] Raised if there's no installation information for this platform.
    def install
      unless self.has_executable?('c:\opscode\chef\bin\chef-solo')
        case self.pocketknife.can_install
        when nil
          # Prompt for installation
          print "? #{self.name}: Chef not found. Install it and its dependencies? (Y/n) "
          STDOUT.flush
          answer = STDIN.gets.chomp
          case answer
          when /^y/i, ''
            # Continue with install
          else
            raise NotInstalling.new("Chef isn't installed on node '#{self.name}', but user doesn't want to install it.", self.name)
          end
        when true
          # User wanted us to install
        else
          # Don't install
          raise NotInstalling.new("Chef isn't installed on node '#{self.name}', but user doesn't want to install it.", self.name)
        end
        self.install_chef
      end
    end


    # Installs Chef on the remote windows server node.
    def install_chef
      self.say("Installing Chef for Windows....")
      self.file_upload("#{ENV['EC2DREAM_HOME']}\\wget\\wget.exe", 'wget.exe')
      self.execute <<HERE
cmd /C if not exist "#{self.pocketknife.directory}\\chef-client-latest.msi" "#{self.pocketknife.directory}\\wget" "#{CHEF_INSTALL_WIN}" --no-check-certificate -O  "#{self.pocketknife.directory}\\chef-client-latest.msi"
HERE
     self.execute(<<-HERE, true)
cmd /C cd "#{WIN_CHEF}" & msiexec /quiet /l chef-client-install.log /i "#{self.pocketknife.directory}\\chef-client-latest.msi" /quiet &&
cmd /C  type "#{self.pocketknife.directory}\\chef-client-install.log" &&
cmd /C  "C:\\opscode\\chef\\bin\\chef-client" -v 
HERE
      self.say("Installed Chef for Windows", false)
     #end
   end     
 

    # Prepares an upload, by creating a cache of shared files used by all nodes.
    #
    # IMPORTANT: This will create files and leave them behind. You should use the block syntax or manually call {cleanup_upload} when done.
    #
    # If an optional block is supplied, calls {cleanup_upload} automatically when done. This is typically used like:
    #
    #   Node.prepare_upload do
    #     mynode.upload
    #   end
    #
    # @yield [] Prepares the upload, executes the block, and cleans up the upload when done.
    def self.prepare_upload(&block)
      begin
        puts("prepare upload...")
        # TODO either do this in memory or scope this to the PID to allow concurrency
        TMP_SOLO_RB.open("w") {|h| h.write(SOLO_RB_CONTENT)}
        TMP_CHEF_SOLO_APPLY.open("w") {|h| h.write(CHEF_SOLO_APPLY_CONTENT)}
        # minitar gem on windows tar file corrupt so use alternative command
        if RUBY_PLATFORM.index("mswin") != nil or RUBY_PLATFORM.index("i386-mingw32") != nil
           puts "#{ENV['POCKETKNIFE_WINDOWS_HOME']}/tar/tar.exe cf #{TMP_TARBALL.to_s} #{VAR_POCKETKNIFE_COOKBOOKS.basename.to_s} #{VAR_POCKETKNIFE_SITE_COOKBOOKS.basename.to_s} #{VAR_POCKETKNIFE_ROLES.basename.to_s} #{TMP_SOLO_RB.to_s} #{TMP_CHEF_SOLO_APPLY.to_s}" 
           system "#{ENV['POCKETKNIFE_WINDOWS_HOME']}/tar/tar.exe cf #{TMP_TARBALL.to_s} #{VAR_POCKETKNIFE_COOKBOOKS.basename.to_s} #{VAR_POCKETKNIFE_SITE_COOKBOOKS.basename.to_s} #{VAR_POCKETKNIFE_ROLES.basename.to_s} #{TMP_SOLO_RB.to_s} #{TMP_CHEF_SOLO_APPLY.to_s}" 
        else
           TMP_TARBALL.open("w") do |handle|
             Archive::Tar::Minitar.pack(
              [
               VAR_POCKETKNIFE_COOKBOOKS.basename.to_s,
               VAR_POCKETKNIFE_SITE_COOKBOOKS.basename.to_s,
               VAR_POCKETKNIFE_ROLES.basename.to_s,
               TMP_SOLO_RB.to_s,
               TMP_CHEF_SOLO_APPLY.to_s
              ],
              handle
             )
           end  
        end
      rescue Exception => e
        cleanup_upload
        raise e
      end

      if block
        begin
          yield(self)
        ensure
          cleanup_upload
        end
      end
    end

    # Cleans up cache of shared files uploaded to all nodes. This cache is created by the {prepare_upload} method.
    def self.cleanup_upload
      [
        TMP_TARBALL,
        TMP_SOLO_RB,
        TMP_CHEF_SOLO_APPLY
      ].each do |path|
   #     path.unlink if path.exist?
      end
    end

   # Uploads configuration information to node.
   #
   # IMPORTANT: You must first call {prepare_upload} to create the shared files that will be uploaded.
   def upload
       self.say("Uploading configuration...")
       self.file_upload("#{ENV['EC2DREAM_HOME']}\\tar\\tar.exe", 'tar.exe')
       self.say("Removing old files...", false)
       self.execute <<HERE
if exist "#{WIN_CHEF}" rmdir /Q /S "#{WIN_CHEF}"  &&
if exist "#{WIN_POCKETKNIFE}" rmdir /Q /S "#{WIN_POCKETKNIFE}"  &&
if exist "#{WIN_POCKETKNIFE_CACHE}" rmdir /Q /S  "#{WIN_POCKETKNIFE_CACHE}"  &&
if exist "#{WIN_CHEF_SOLO_APPLY}" rmdir /Q /S  "#{WIN_CHEF_SOLO_APPLY}"  &&
if exist "#{WIN_CHEF_SOLO_APPLY_ALIAS}" rmdir /Q /S "#{WIN_CHEF_SOLO_APPLY_ALIAS}"
HERE
       self.execute <<HERE
mkdir  "#{WIN_CHEF}" "#{WIN_POCKETKNIFE}" "#{WIN_POCKETKNIFE_CACHE}" "#{WIN_CHEF_SOLO_APPLY}" 
HERE
       self.say("Uploading new files...", false)
       #repo = ENV['EC2_CHEF_REPOSITORY']
       local_node_json="#{ENV['EC2_CHEF_REPOSITORY']}/#{self.local_node_json_pathname}"
       self.file_upload(local_node_json, NODE_JSON_FILENAME.to_s)
       tmp_tarball="#{TMP_TARBALL}"
       self.file_upload(tmp_tarball, TMP_TARBALL.to_s)
       self.say("Installing new files...", false)
       self.execute <<-HERE
cmd /C move "#{self.pocketknife.directory}\\#{NODE_JSON_FILENAME}" "c:\\chef\\#{NODE_JSON_FILENAME}" &&
cmd /C move "#{self.pocketknife.directory}\\#{TMP_TARBALL}" "c:\\chef\\#{TMP_TARBALL}" &&
cmd /C move "#{self.pocketknife.directory}\\tar.exe" "c:\\chef\\tar.exe" 
HERE
       self.execute <<-HERE
cmd /C "cd #{WIN_POCKETKNIFE_CACHE} & c:\\chef\\tar xvf c:\\chef\\#{TMP_TARBALL}"
HERE
       self.execute <<-HERE
cmd /C move /Y "#{WIN_POCKETKNIFE_CACHE}\\#{TMP_SOLO_RB}" "#{WIN_CHEF}" &&
cmd /C rename "#{WIN_CHEF}\\#{TMP_SOLO_RB}" "solo.rb" 
HERE
       self.execute <<-HERE
cmd /C move /Y  "#{WIN_POCKETKNIFE_CACHE}\\#{TMP_CHEF_SOLO_APPLY}"  "#{WIN_CHEF}" 
HERE
# cmd /C rename "#{WIN_CHEF}\\#{TMP_CHEF_SOLO_APPLY}" "chef-solo-apply"
       self.execute <<-HERE 
cmd /C erase "#{WIN_POCKETKNIFE_TARBALL}"
HERE
       self.execute <<-HERE
cmd /C xcopy /E "#{WIN_POCKETKNIFE_CACHE}" "#{WIN_POCKETKNIFE}" &&
cmd /C erase /Q "#{WIN_POCKETKNIFE_CACHE}\*"
HERE
#cd "#{WIN_POCKETKNIFE_CACHE}" & copy /Y  "#{CHEF_SOLO_APPLY.basename}" "#{CHEF_SOLO_APPLY_ALIAS}" &&
      self.say("Finished uploading!", false)
    #end
 end
# this after move above  
# ln -s "#{CHEF_SOLO_APPLY.basename}" "#{CHEF_SOLO_APPLY_ALIAS}" &&
    # Applies the configuration to the node. Installs Chef, Ruby and Rubygems if needed.
    def apply
      self.install
      self.say("Applying configuration...", true)
      command = "c:\\opscode\\chef\\bin\\chef-solo -c c:\\chef\\solo.rb -j #{WIN_NODE_JSON}"
      command << " -l debug" if self.pocketknife.verbosity == true
      self.execute(command, true)
      self.say("Finished applying!")
    end

    # Deploys the configuration to the node, which calls {#upload} and {#apply}.
    def deploy
      self.upload
      self.apply
    end

    # Executes commands on the external node.
    #
    # @param [String] commands Shell commands to execute.
    # @param [Boolean] immediate Display execution information immediately to STDOUT, rather than returning it as an object when done.
    # @return [Rye::Rap] A result object describing the completed execution.
    # @raise [ExecutionError] Raised if something goes wrong with execution.
    def execute(commands, immediate=false)
      self.say("Executing:\n#{commands}", false)
      if immediate
        self.connection.stdout_hook {|line| puts line}
      end
      return self.connection.execute("(#{commands}) 2>&1")
    rescue Rye::Err => e
      raise Pocketknife_windows::ExecutionError.new(self.name, commands, e, immediate)
    ensure
      self.connection.stdout_hook = nil
    end

    # Remote path to Chef's settings
    # @private
    ETC_CHEF = Pathname.new('c:/chef')
    # Remote path to solo.rb
    # @private
    SOLO_RB = ETC_CHEF + "solo.rb"
    # Remote path to node.json
    # @private
    NODE_JSON = ETC_CHEF + "node.json"
    # Remote path to pocketknife's deployed configuration
    # @private
    VAR_POCKETKNIFE = Pathname.new("c:/chef/pocketknife")
    # Remote path to pocketknife's cache
    # @private
    VAR_POCKETKNIFE_CACHE = VAR_POCKETKNIFE + "cache"
    # Remote path to temporary tarball containing uploaded files.
    # @private
    VAR_POCKETKNIFE_TARBALL = VAR_POCKETKNIFE_CACHE + "pocketknife.tmp"
    # Remote path to pocketknife's cookbooks
    # @private
    VAR_POCKETKNIFE_COOKBOOKS = VAR_POCKETKNIFE + "cookbooks"
    # Remote path to pocketknife's site-cookbooks
    # @private
    VAR_POCKETKNIFE_SITE_COOKBOOKS = VAR_POCKETKNIFE + "site-cookbooks"
    # Remote path to pocketknife's roles
    # @private
    VAR_POCKETKNIFE_ROLES = VAR_POCKETKNIFE + "roles"
    # Content of the solo.rb file
    # @private
    SOLO_RB_CONTENT = <<-HERE
file_cache_path "#{VAR_POCKETKNIFE_CACHE}"
cookbook_path ["#{VAR_POCKETKNIFE_COOKBOOKS}", "#{VAR_POCKETKNIFE_SITE_COOKBOOKS}"]
role_path "#{VAR_POCKETKNIFE_ROLES}"
    HERE
    # Remote path to chef-solo-apply
    # @private
    CHEF_SOLO_APPLY = Pathname.new("c:/chef/chef-solo-apply")
    # Remote path to csa
    # @private
    CHEF_SOLO_APPLY_ALIAS = CHEF_SOLO_APPLY.dirname + "csa"
    # Content of the chef-solo-apply file
    # @private
    CHEF_SOLO_APPLY_CONTENT = <<-HERE
chef-solo -j #{NODE_JSON} "$@"
    HERE
    # Local path to solo.rb that will be included in the tarball
    # @private
    TMP_SOLO_RB = Pathname.new('solo.rb.tmp')
    # Local path to chef-solo-apply.rb that will be included in the tarball
    # @private
    TMP_CHEF_SOLO_APPLY = Pathname.new('chef-solo-apply.tmp')
    # Local path to the tarball to upload to the remote node containing shared files
    # @private
    TMP_TARBALL = Pathname.new('pocketknife.tmp')
    
    # Windows Remote path to Chef's settings
    # @private
    WIN_CHEF = 'c:\chef'
    # Remote path to solo.rb
    # @private
    WIN_SOLO_RB = WIN_CHEF + '\solo.rb'
    # Remote path to node.json
    # @private
    NODE_JSON_FILENAME = 'node.json'
    WIN_NODE_JSON = WIN_CHEF + '\node.json'
    # Remote path to pocketknife's deployed configuration
    # @private
    WIN_POCKETKNIFE = 'c:\chef\pocketknife'
    # Remote path to pocketknife's cache
    # @private
    WIN_POCKETKNIFE_CACHE = WIN_POCKETKNIFE + '\cache'
    # Remote path to temporary tarball containing uploaded files.
    # @private
    WIN_POCKETKNIFE_TARBALL = WIN_POCKETKNIFE_CACHE + '\pocketknife.tmp'
    # Remote path to pocketknife's cookbooks
    # @private
    WIN_POCKETKNIFE_COOKBOOKS = WIN_POCKETKNIFE + '\cookbooks'
    # Remote path to pocketknife's site-cookbooks
    # @private
    WIN_POCKETKNIFE_SITE_COOKBOOKS = WIN_POCKETKNIFE + '\site-cookbooks'
    # Remote path to pocketknife's roles
    # @private
    WIN_POCKETKNIFE_ROLES = WIN_POCKETKNIFE + '\roles'
    # tar command
    WIN_TAR ='C:\tar'
    CHEF_INSTALL_WIN2003 = 'https://s3.amazonaws.com/opscode-full-stack/windows/chef-client-0.10.8-1.msi'
    CHEF_INSTALL_WIN = 'http://www.opscode.com/chef/install.msi'
    # Remote path to chef-solo-apply
    # @private
    WIN_CHEF_SOLO_APPLY = 'c:\chef\chef-solo-apply'
    # Remote path to csa
    # @private
    WIN_CHEF_SOLO_APPLY_ALIAS = WIN_CHEF_SOLO_APPLY + '\csa'    
  end
end


