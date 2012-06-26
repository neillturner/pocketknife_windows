# Standard libraries
require "pathname"
require "fileutils"

# Gem libraries
require "archive/tar/minitar"
require "rye"
require "net/sftp"

# Related libraries
require "pocketknife_windows/errors"
require "pocketknife_windows/node"
require "pocketknife_windows/node_manager"
require "pocketknife_windows/version"

# = Pocketknife_windows
#
# == About
#
# Pocketknife_windows is a devops tool for managing computers running <tt>chef-solo</tt>. Using Pocketknife_windows, you create a project that describes the configuration of your computers and then apply it to bring them to the intended state.
#
# For information on using the +pocketknife_windows+ tool, please see the {file:README.md README.md} file. The rest of this documentation is intended for those writing code using the Pocketknife API.
#
# == Important methods
#
# * {cli} runs the command-line interpreter, whichi in turn executes the methods below.
# * {#initialize} creates a new Pocketknife instance.
# * {#create} creates a new project.
# * {#deploy} deploys configurations to nodes, which uploads and applies.
# * {#upload} uploads configurations to nodes.
# * {#apply} applies existing configurations to nodes.
# * {#node} finds a node to upload or apply configurations.
#
# == Important classes
#
# * {Pocketknife_windows::Node} describes how to upload and apply configurations to nodes, which are remote computers.
# * {Pocketknife_windows::NodeManager} finds, checks and manages nodes.
# * {Pocketknife_windows::NodeError} describes errors encountered when using nodes.
class Pocketknife_windows
  # Runs the interpreter using arguments provided by the command-line. Run <tt>pocketknife_windows -h</tt> or review the code below to see what command-line arguments are accepted.
  #
  # Example:
  #   # Display command-line help:
  #   Pocketknife_windows.cli('-h')
  #
  # @param [Array<String>] args A list of arguments from the command-line, which may include options (e.g. <tt>-h</tt>).
  def self.cli(args)
    pocketknife_windows = Pocketknife_windows.new

    OptionParser.new do |parser|
      parser.banner = <<-HERE
USAGE: pocketknife_windows [options] [nodes]

EXAMPLES:
  # Create a new project called PROJECT
  pocketknife_windows -c PROJECT

  # Apply configuration to a node called NODE
  pocketknife_windows NODE

OPTIONS:
      HERE

      options = {}

      parser.on("-c", "--create PROJECT", "Create project") do |name|
        pocketknife_windows.create(name)
        return
      end

      parser.on("-V", "--version", "Display version number") do |name|
        puts "Pocketknife_windows #{Pocketknife_windows::Version::STRING}"
        return
      end

      parser.on("-v", "--verbose", "Display detailed status information") do |name|
        pocketknife_windows.verbosity = true
      end

      parser.on("-q", "--quiet", "Display minimal status information") do |v|
        pocketknife_windows.verbosity = false
      end
      
      parser.on("-s", "--set USER", "Run under non-root users") do |name|
        options[:sudo] = true
        pocketknife_windows.user = name
        if options[:directory] == nil or options[:directory] = ""
           options[:directory] = "c:\\users\\#{name}"
           pocketknife_windows.directory = options[:directory]
        end 
      end
      
      parser.on("-p", "--password PASSWORD", "Password of the user") do |name|
        options[:password] = name
        pocketknife_windows.password = name
      end 
      
      parser.on("-d", "--directory DIRECTORY", "Upload Directory of the user") do |name|
        options[:directory] = name
        pocketknife_windows.directory = name
      end          
      
      parser.on("-k", "--sshkey SSHKEY", "Use an ssh key") do |name|
        options[:ssh_key] = name
        pocketknife_windows.ssh_key = name
      end

      parser.on("-u", "--upload", "Upload configuration, but don't apply it") do |v|
        options[:upload] = true
      end

      parser.on("-a", "--apply", "Runs chef to apply already-uploaded configuration") do |v|
        options[:apply] = true
      end

      parser.on("-i", "--install", "Install Chef automatically") do |v|
        pocketknife_windows.can_install = true
      end

      parser.on("-I", "--noinstall", "Don't install Chef automatically") do |v|
        pocketknife_windows.can_install = false
      end

      begin
        arguments = parser.parse!
      rescue OptionParser::MissingArgument => e
        puts parser
        puts
        puts "ERROR: #{e}"
        exit -1
      end

      nodes = arguments

      if nodes.empty?
        puts parser
        puts
        puts "ERROR: No nodes specified."
        exit -1
      end

      begin
        if options[:upload]
          pocketknife_windows.upload(nodes)
        end

        if options[:apply]
          pocketknife_windows.apply(nodes)
        end

        if not options[:upload] and not options[:apply]
          pocketknife_windows.deploy(nodes)
        end
      rescue NodeError => e
        puts "! #{e.node}: #{e}"
        exit -1
      end
    end
  end

  # Returns the software's version.
  #
  # @return [String] A version string.
  def self.version
    return "0.0.1"
  end

  # Amount of detail to display? true means verbose, nil means normal, false means quiet.
  attr_accessor :verbosity
  
  # key for ssh access.
  attr_accessor :ssh_key
  
  # user when doing sudo access
  attr_accessor :user
  
  # password for ssh access instead of key
  attr_accessor :password
  
  # upload directory for user 
  attr_accessor :directory
  
  # Can chef and its dependencies be installed automatically if not found? true means perform installation without prompting, false means quit if chef isn't available, and nil means prompt the user for input.
  attr_accessor :can_install

  # {Pocketknife::NodeManager} instance.
  attr_accessor :node_manager

  # Instantiate a new Pocketknife.
  #
  # @option [Boolean] verbosity Amount of detail to display. +true+ means verbose, +nil+ means normal, +false+ means quiet.
  # @option [Boolean] install Install Chef and its dependencies if needed? +true+ means do so automatically, +false+ means don't, and +nil+ means display a prompt to ask the user what to do.
  def initialize(opts={})
    self.verbosity   = opts[:verbosity]
    self.can_install = opts[:install]

    self.node_manager = NodeManager.new(self)
  end

  # Display a message, but only if it's important enough
  #
  # @param [String] message The message to display.
  # @param [Boolean] importance How important is this? +true+ means important, +nil+ means normal, +false+ means unimportant.
  def say(message, importance=nil)
    display = \
      case self.verbosity
      when true
        true
      when nil
        importance != false
      else
        importance == true
      end

    if display
      puts message
    end
  end

  # Creates a new project directory.
  #
  # @param [String] project The name of the project directory to create.
  # @yield [path] Yields status information to the optionally supplied block.
  # @yieldparam [String] path The path of the file or directory created.
  def create(project)
    self.say("* Creating project in directory: #{project}")

    dir = Pathname.new(project)

    %w[
      nodes
      roles
      cookbooks
      site-cookbooks
    ].each do |subdir|
      target = (dir + subdir)
      unless target.exist?
        FileUtils.mkdir_p(target)
        self.say("- #{target}/")
      end
    end

    return true
  end

  # Returns a Node instance.
  #
  # @param[String] name The name of the node.
  def node(name)
    return node_manager.find(name)
  end

  # Deploys configuration to the nodes, calls {#upload} and {#apply}.
  #
  # @params[Array<String>] nodes A list of node names.
  def deploy(nodes)
    node_manager.assert_known(nodes)

    Node.prepare_upload do
      for node in nodes
        node_manager.find(node).deploy
      end
    end
  end

  # Uploads configuration information to remote nodes.
  #
  # @param [Array<String>] nodes A list of node names.
  def upload(nodes)
    node_manager.assert_known(nodes)

    Node.prepare_upload do
      for node in nodes
        node_manager.find(node).upload
      end
    end
  end

  # Applies configurations to remote nodes.
  #
  # @param [Array<String>] nodes A list of node names.
  def apply(nodes)
    node_manager.assert_known(nodes)

    for node in nodes
      node_manager.find(node).apply
    end
  end
end
